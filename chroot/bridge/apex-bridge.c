// SPDX-License-Identifier: GPL-2.0-only
/*
 * apex-bridge: userspace daemon that bridges the Android framework to the
 * kernel apex state machine via /proc/apex/policy.
 *
 * Listens on a Unix domain socket at /dev/socket/apex-bridge for simple
 * text-based commands from the Apex Control app or other privileged clients.
 * Socket is restricted to root-only (0600) and client UID is verified via
 * SO_PEERCRED.
 *
 * Also monitors:
 *   - Display state (via sysfs backlight brightness)
 *   - Charging state (via sysfs power_supply)
 *   - Battery level (via sysfs power_supply capacity)
 *   - Thermal zones (via sysfs thermal_zone)
 *
 * And writes the corresponding commands to /proc/apex/policy.
 *
 * Protocol: newline-terminated text commands:
 *   "screen_on"     -> write screen_on to /proc/apex/policy
 *   "screen_off"    -> write screen_off to /proc/apex/policy
 *   "game 0|1"      -> write game N to /proc/apex/policy
 *   "charge 0|1"    -> write charge N to /proc/apex/policy
 *   "audio 0|1"     -> write audio N to /proc/apex/policy
 *   "status"        -> read /proc/apex/state and return it
 *   "version"       -> read /proc/apex/version and return it
 *   "governor"      -> read /proc/apex/governor and return it
 *   "watchdog"      -> read /proc/apex/watchdog and return it
 *   "health"        -> read /proc/apex/health and return it
 *
 * Build: cc -o apex-bridge apex-bridge.c -lpthread
 * Run:   apex-bridge (as root via init.rc)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <pthread.h>
#include <sys/wait.h>
#include <android/log.h>

#define SOCKET_PATH "/dev/socket/apex-bridge"
#define PROC_POLICY "/proc/apex/policy"
#define PROC_GAMING "/proc/apex/gaming"
#define PROC_STATUS "/proc/apex/state"
#define PROC_VERSION "/proc/apex/version"
#define PROC_GOVERNOR "/proc/apex/governor"
#define PROC_WATCHDOG "/proc/apex/watchdog"
#define PROC_HEALTH "/proc/apex/health"
#define PROC_THERMAL_PROFILE "/proc/apex/thermal_profile"
#define PROC_POLICY_ACTIVE "/proc/apex/policy_active"
#define PROC_BT_STATUS "/proc/apex/bt_status"
#define PROC_SENSOR_STATUS "/proc/apex/sensor_status"
#define PROC_MODULES "/proc/apex/modules"
#define PROC_NH_CTL "/dev/nh_ctl"
#define MAX_CLIENTS 16
#define BUF_SIZE 8192
#define SOCK_BUF_SIZE 16384
/* Battery monitoring thresholds */
#define BATTERY_LOW_PCT 15
#define BATTERY_HIGH_PCT 80

/* Thermal monitoring thresholds (millidegrees) */
#define THERMAL_WARN_MC 55000
#define THERMAL_CRIT_MC 65000

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "apex-bridge", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "apex-bridge", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  "apex-bridge", __VA_ARGS__)

static volatile sig_atomic_t running = 1;
static int server_fd = -1;

/* Hex character to integer value. Returns -1 for invalid hex chars. */
static int hexval(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* Log an incident to the Android log and optionally to the kernel
 * incident ring buffer via /proc/apex/policy (if writable).
 * This is the userspace equivalent of the kernel's apex_incident_log().
 * The kernel's /proc/apex/incidents is read-only (0444), so we can't
 * write directly to it. Instead, we log to Android logbuf which is
 * captured in logcat and bug reports. */
static void apex_incident_log(const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	LOGI("incident: %s", buf);
}

static void signal_handler(int sig)
{
	(void)sig;
	running = 0;
	/* Close the server socket to interrupt accept() — guarantees
	 * prompt shutdown instead of relying on EINTR (signal() with
	 * SA_RESTART may not interrupt accept()). */
	if (server_fd >= 0) {
		close(server_fd);
		server_fd = -1;
	}
}

/* Write a command to /proc/apex/policy.
 * Returns 0 on success, -1 on error. Checks write() return value. */
static int apex_write_policy(const char *cmd)
{
	int fd = open(PROC_POLICY, O_WRONLY);
	if (fd < 0) {
		LOGE("open %s: %s", PROC_POLICY, strerror(errno));
		return -1;
	}
	ssize_t written = write(fd, cmd, strlen(cmd));
	close(fd);
	if (written < 0) {
		LOGE("write %s: %s", PROC_POLICY, strerror(errno));
		return -1;
	}
	if ((size_t)written != strlen(cmd)) {
		LOGW("short write to %s: %zd/%zu", PROC_POLICY, written, strlen(cmd));
		return -1;
	}
	return 0;
}

/* Read a proc file into a buffer. Returns 0 on success, -1 on error. */
static int apex_read_proc(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	ssize_t n = read(fd, buf, len - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = '\0';
	return 0;
}

/* Trim trailing whitespace/newlines in-place */
static void trim(char *s)
{
	size_t len = strlen(s);
	while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' ||
	       s[len - 1] == ' ' || s[len - 1] == '\t'))
		s[--len] = '\0';
}

/* Validate that a numeric argument is 0 or 1.
 * Returns 0 on valid, -1 on invalid. */
static int validate_binary_arg(const char *arg)
{
	if (!arg || *arg == '\0')
		return -1;
	if (strcmp(arg, "0") != 0 && strcmp(arg, "1") != 0)
		return -1;
	return 0;
}

/* Handle a text command from a client.
 * Uses a smaller stack buffer to reduce per-thread memory. */
static void handle_command(const char *cmd_in, char *response, size_t resp_len)
{
	char cmd[256];
	char *arg;

	strncpy(cmd, cmd_in, sizeof(cmd) - 1);
	cmd[sizeof(cmd) - 1] = '\0';
	trim(cmd);

	if (strcmp(cmd, "screen_on") == 0) {
		apex_write_policy("screen_on");
		snprintf(response, resp_len, "OK");
	} else if (strcmp(cmd, "screen_off") == 0) {
		apex_write_policy("screen_off");
		snprintf(response, resp_len, "OK");
	} else if (strncmp(cmd, "game ", 5) == 0) {
		arg = cmd + 5;
		trim(arg);
		if (validate_binary_arg(arg) < 0) {
			snprintf(response, resp_len, "ERROR: invalid argument (must be 0 or 1)");
			return;
		}
		char policy_cmd[16];
		snprintf(policy_cmd, sizeof(policy_cmd), "game %s", arg);
		apex_write_policy(policy_cmd);
		snprintf(response, resp_len, "OK gaming=%s", arg);
	} else if (strncmp(cmd, "charge ", 7) == 0) {
		arg = cmd + 7;
		trim(arg);
		if (validate_binary_arg(arg) < 0) {
			snprintf(response, resp_len, "ERROR: invalid argument (must be 0 or 1)");
			return;
		}
		char policy_cmd[16];
		snprintf(policy_cmd, sizeof(policy_cmd), "charge %s", arg);
		apex_write_policy(policy_cmd);
		snprintf(response, resp_len, "OK");
	} else if (strncmp(cmd, "audio ", 6) == 0) {
		arg = cmd + 6;
		trim(arg);
		if (validate_binary_arg(arg) < 0) {
			snprintf(response, resp_len, "ERROR: invalid argument (must be 0 or 1)");
			return;
		}
		char policy_cmd[16];
		snprintf(policy_cmd, sizeof(policy_cmd), "audio %s", arg);
		apex_write_policy(policy_cmd);
		snprintf(response, resp_len, "OK");
	} else if (strcmp(cmd, "status") == 0) {
		char status[1024];
		if (apex_read_proc(PROC_STATUS, status, sizeof(status)) == 0) {
			snprintf(response, resp_len, "%s", status);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read status");
		}
	} else if (strcmp(cmd, "version") == 0) {
		char version[512];
		if (apex_read_proc(PROC_VERSION, version, sizeof(version)) == 0) {
			snprintf(response, resp_len, "%s", version);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read version");
		}
	} else if (strcmp(cmd, "governor") == 0) {
		char gov[512];
		if (apex_read_proc(PROC_GOVERNOR, gov, sizeof(gov)) == 0) {
			snprintf(response, resp_len, "%s", gov);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read governor");
		}
	} else if (strcmp(cmd, "watchdog") == 0) {
		char wd[1024];
		if (apex_read_proc(PROC_WATCHDOG, wd, sizeof(wd)) == 0) {
			snprintf(response, resp_len, "%s", wd);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read watchdog");
		}
	} else if (strcmp(cmd, "health") == 0) {
		char health[512];
		if (apex_read_proc(PROC_HEALTH, health, sizeof(health)) == 0) {
			snprintf(response, resp_len, "%s", health);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read health");
		}
	} else if (strcmp(cmd, "thermal_profile") == 0) {
		char tp[2048];
		if (apex_read_proc(PROC_THERMAL_PROFILE, tp, sizeof(tp)) == 0) {
			snprintf(response, resp_len, "%s", tp);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read thermal_profile");
		}
	} else if (strcmp(cmd, "policy_active") == 0) {
		char pa[512];
		if (apex_read_proc(PROC_POLICY_ACTIVE, pa, sizeof(pa)) == 0) {
			snprintf(response, resp_len, "%s", pa);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read policy_active");
		}
	} else if (strcmp(cmd, "bt_status") == 0) {
		char bt[512];
		if (apex_read_proc(PROC_BT_STATUS, bt, sizeof(bt)) == 0) {
			snprintf(response, resp_len, "%s", bt);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read bt_status");
		}
	} else if (strcmp(cmd, "sensor_status") == 0) {
		char ss[512];
		if (apex_read_proc(PROC_SENSOR_STATUS, ss, sizeof(ss)) == 0) {
			snprintf(response, resp_len, "%s", ss);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read sensor_status");
		}
	} else if (strcmp(cmd, "modules") == 0) {
		char mods[2048];
		if (apex_read_proc(PROC_MODULES, mods, sizeof(mods)) == 0) {
			snprintf(response, resp_len, "%s", mods);
		} else {
			snprintf(response, resp_len, "ERROR: cannot read modules");
		}
	} else if (strncmp(cmd, "nh ", 3) == 0) {
		/* Forward pentest control command to /dev/nh_ctl */
		arg = cmd + 3;
		trim(arg);
		int nh_fd = open(PROC_NH_CTL, O_WRONLY);
		if (nh_fd >= 0) {
			ssize_t w = write(nh_fd, arg, strlen(arg));
			close(nh_fd);
			if (w >= 0)
				snprintf(response, resp_len, "OK nh_ctl: %s", arg);
			else
				snprintf(response, resp_len, "ERROR: nh_ctl write failed");
		} else {
			snprintf(response, resp_len, "ERROR: cannot open %s", PROC_NH_CTL);
		}
	} else if (strcmp(cmd, "help") == 0) {
		snprintf(response, resp_len,
			 "Commands: screen_on screen_off game<0|1> charge<0|1> "
			 "audio<0|1> status version governor watchdog health "
			 "thermal_profile policy_active bt_status sensor_status "
			 "modules nh<cmd> help");
	} else {
		snprintf(response, resp_len, "ERROR: unknown command");
	}
}

/* ---- JSON protocol v2 ----
 * Detects JSON by first byte '{' and routes to appropriate handler.
 * Supports: am, dumpsys, sensor, clipboard, nfc, ir, usb operations
 * as specified in DESIGN.md §8.3.
 * Falls back to text protocol for non-JSON commands.
 */

/* Simple JSON field extractor: finds "field":"value" or "field":value
 * Scans past string values to avoid matching field names inside values.
 * Returns 0 on success, -1 if field not found. */
static int json_extract_string(const char *json, const char *field,
			       char *out, size_t out_len)
{
	char pattern[64];
	const char *p = json;

	snprintf(pattern, sizeof(pattern), "\"%s\"", field);

	/* Scan through the JSON, skipping string values to avoid
	 * matching field names that appear inside string values. */
	while (*p) {
		if (*p == '"') {
			/* Check if this is our target field */
			if (strncmp(p, pattern, strlen(pattern)) == 0) {
				p += strlen(pattern);
				/* Skip whitespace and colon */
				while (*p && (*p == ' ' || *p == ':' || *p == '\t'))
					p++;

				if (*p == '"') {
					/* String value */
					p++;
					size_t i = 0;
					while (*p && *p != '"' && i < out_len - 1)
						out[i++] = *p++;
					out[i] = '\0';
					return 0;
				} else {
					/* Numeric or boolean value */
					size_t i = 0;
					while (*p && *p != ',' && *p != '}' &&
					       *p != ' ' && i < out_len - 1)
						out[i++] = *p++;
					out[i] = '\0';
					return 0;
				}
			}
			/* Not our field — skip this entire string value */
			p++;
			while (*p && *p != '"') {
				if (*p == '\\')
					p++;
				if (*p)
					p++;
			}
			if (*p)
				p++;
		} else {
			p++;
		}
	}
	return -1;
}

/* Execute a command safely using fork+execvp (no shell injection).
 * argv is a NULL-terminated array of arguments.
 * Returns 0 on success, -1 on error. */
static int exec_safe(char *const argv[], char *output, size_t out_len)
{
	int pipefd[2];
	pid_t pid;

	if (pipe(pipefd) < 0) {
		snprintf(output, out_len, "ERROR: pipe failed");
		return -1;
	}

	pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		snprintf(output, out_len, "ERROR: fork failed");
		return -1;
	}

	if (pid == 0) {
		/* Child: redirect stdout to pipe, exec the command */
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[1]);
		execvp(argv[0], argv);
		/* If execvp returns, it failed */
		_exit(127);
	}

	/* Parent: read output */
	close(pipefd[1]);
	size_t total = 0;
	char buf[512];
	ssize_t n;
	while ((n = read(pipefd[0], buf, sizeof(buf))) > 0 &&
	       total < out_len - 1) {
		size_t len = (size_t)n;
		if (total + len >= out_len)
			len = out_len - 1 - total;
		memcpy(output + total, buf, len);
		total += len;
	}
	output[total] = '\0';
	close(pipefd[0]);

	int status;
	waitpid(pid, &status, 0);
	return 0;
}

/* Write a string directly to a sysfs/configfs path (no shell). */
static int write_to_path(const char *path, const char *value)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	ssize_t w = write(fd, value, strlen(value));
	close(fd);
	return (w >= 0) ? 0 : -1;
}

/* Handle a JSON protocol v2 command.
 * Returns a JSON response string. */
static void handle_json_command(const char *json, char *response, size_t resp_len)
{
	char op[32];

	if (json_extract_string(json, "op", op, sizeof(op)) < 0) {
		snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing op\"}");
		return;
	}

	if (strcmp(op, "am") == 0) {
		/* Activity manager: exec am with args (no shell, no injection) */
		char args[512];

		if (json_extract_string(json, "args", args, sizeof(args)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing args\"}");
			return;
		}
		/* Tokenize args into argv for execvp. Simple space-split. */
		char *argv[32];
		int argc = 0;
		char *tok = strtok(args, " ");
		argv[argc++] = "am";
		while (tok && argc < 31) {
			argv[argc++] = tok;
			tok = strtok(NULL, " ");
		}
		argv[argc] = NULL;
		char out[2048];
		exec_safe(argv, out, sizeof(out));
		snprintf(response, resp_len, "{\"ok\":true,\"out\":\"%.1024s\"}", out);
	} else if (strcmp(op, "dumpsys") == 0) {
		char args[256];

		if (json_extract_string(json, "args", args, sizeof(args)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing args\"}");
			return;
		}
		char *argv[32];
		int argc = 0;
		char *tok = strtok(args, " ");
		argv[argc++] = "dumpsys";
		while (tok && argc < 31) {
			argv[argc++] = tok;
			tok = strtok(NULL, " ");
		}
		argv[argc] = NULL;
		char out[4096];
		exec_safe(argv, out, sizeof(out));
		snprintf(response, resp_len, "{\"ok\":true,\"out\":\"%.2048s\"}", out);
	} else if (strcmp(op, "sensor") == 0) {
		/* Read sensor status from proc */
		char ss[512];
		if (apex_read_proc(PROC_SENSOR_STATUS, ss, sizeof(ss)) == 0) {
			snprintf(response, resp_len, "{\"ok\":true,\"out\":\"%.256s\"}", ss);
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"sensor unavailable\"}");
		}
	} else if (strcmp(op, "clipboard") == 0) {
		char action[16];
		if (json_extract_string(json, "action", action, sizeof(action)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing action\"}");
			return;
		}
		if (strcmp(action, "get") == 0) {
			char *argv[] = { "cmd", "clipboard", "get-text", NULL };
			char out[1024];
			exec_safe(argv, out, sizeof(out));
			snprintf(response, resp_len, "{\"ok\":true,\"out\":\"%.256s\"}", out);
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"unknown clipboard action\"}");
		}
	} else if (strcmp(op, "nfc") == 0) {
		/* NFC raw APDU — write hex-encoded frame to /dev/st21nfc */
		char frame[512];
		if (json_extract_string(json, "frame", frame, sizeof(frame)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing frame\"}");
			return;
		}
		/* Decode hex string to binary */
		size_t hex_len = strlen(frame);
		if (hex_len % 2 != 0 || hex_len == 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"invalid hex frame\"}");
			return;
		}
		size_t bin_len = hex_len / 2;
		unsigned char bin[256];
		for (size_t i = 0; i < bin_len; i++) {
			int hi = hexval(frame[i * 2]);
			int lo = hexval(frame[i * 2 + 1]);
			if (hi < 0 || lo < 0) {
				snprintf(response, resp_len, "{\"ok\":false,\"error\":\"invalid hex char\"}");
				return;
			}
			bin[i] = (unsigned char)((hi << 4) | lo);
		}
		/* Open NFC device and write binary frame */
		int fd = open("/dev/st21nfc", O_WRONLY);
		if (fd >= 0) {
			ssize_t written = write(fd, bin, bin_len);
			close(fd);
			if (written == (ssize_t)bin_len) {
				apex_incident_log("nfc: raw frame write (%zu bytes)", bin_len);
				snprintf(response, resp_len, "{\"ok\":true}");
			} else {
				apex_incident_log("nfc: write failed (wrote %zd of %zu)", written, bin_len);
				snprintf(response, resp_len, "{\"ok\":false,\"error\":\"write incomplete\"}");
			}
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"cannot open /dev/st21nfc\"}");
		}
	} else if (strcmp(op, "ir") == 0) {
		/* IR raw frame — write hex-encoded data to /dev/lirc0 */
		char raw[512];
		if (json_extract_string(json, "raw", raw, sizeof(raw)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing raw\"}");
			return;
		}
		/* Decode hex string to binary */
		size_t hex_len = strlen(raw);
		if (hex_len % 2 != 0 || hex_len == 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"invalid hex raw\"}");
			return;
		}
		size_t bin_len = hex_len / 2;
		unsigned char bin[256];
		for (size_t i = 0; i < bin_len; i++) {
			int hi = hexval(raw[i * 2]);
			int lo = hexval(raw[i * 2 + 1]);
			if (hi < 0 || lo < 0) {
				snprintf(response, resp_len, "{\"ok\":false,\"error\":\"invalid hex char\"}");
				return;
			}
			bin[i] = (unsigned char)((hi << 4) | lo);
		}
		int fd = open("/dev/lirc0", O_WRONLY);
		if (fd >= 0) {
			ssize_t written = write(fd, bin, bin_len);
			close(fd);
			if (written == (ssize_t)bin_len) {
				apex_incident_log("ir: raw frame transmit (%zu bytes)", bin_len);
				snprintf(response, resp_len, "{\"ok\":true}");
			} else {
				apex_incident_log("ir: write failed (wrote %zd of %zu)", written, bin_len);
				snprintf(response, resp_len, "{\"ok\":false,\"error\":\"write incomplete\"}");
			}
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"cannot open /dev/lirc0\"}");
		}
	} else if (strcmp(op, "usb") == 0) {
		/* USB gadget mode switch via ConfigFS — direct write, no shell */
		char mode[32];
		if (json_extract_string(json, "mode", mode, sizeof(mode)) < 0) {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"missing mode\"}");
			return;
		}
		/* Validate mode: only allow known UDC names (alphanumeric + dash) */
		for (size_t i = 0; i < strlen(mode); i++) {
			if (!isalnum((unsigned char)mode[i]) && mode[i] != '-' && mode[i] != '.') {
				snprintf(response, resp_len, "{\"ok\":false,\"error\":\"invalid mode\"}");
				return;
			}
		}
		if (write_to_path("/sys/kernel/config/usb_gadget/apex/UDC", mode) == 0) {
			apex_incident_log("usb: gadget mode -> %s", mode);
			snprintf(response, resp_len, "{\"ok\":true,\"mode\":\"%s\"}", mode);
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"cannot write UDC\"}");
		}
	} else if (strcmp(op, "status") == 0) {
		/* Return full status as JSON */
		char status[1024];
		if (apex_read_proc(PROC_STATUS, status, sizeof(status)) == 0) {
			snprintf(response, resp_len, "{\"ok\":true,\"out\":\"%.512s\"}", status);
		} else {
			snprintf(response, resp_len, "{\"ok\":false,\"error\":\"cannot read status\"}");
		}
	} else {
		snprintf(response, resp_len, "{\"ok\":false,\"error\":\"unknown op: %s\"}", op);
	}
}

/* Per-client thread: read command, detect protocol, send response, close */
static void *client_thread(void *arg)
{
	int fd = *(int *)arg;
	free(arg);

	char buf[BUF_SIZE];
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = '\0';
		char response[BUF_SIZE];

		/* Protocol detection: JSON if first non-whitespace byte is '{'
		 * Text protocol for everything else (backward compatible) */
		char *start = buf;
		while (*start == ' ' || *start == '\t' || *start == '\n')
			start++;

		if (*start == '{') {
			/* JSON protocol v2 */
			handle_json_command(start, response, sizeof(response));
		} else {
			/* Text protocol (legacy) */
			handle_command(buf, response, sizeof(response));
		}

		ssize_t written = write(fd, response, strlen(response));
		if (written < 0 || (size_t)written != strlen(response))
			LOGW("short write to client: %zd/%zu", written, strlen(response));
	}
	close(fd);
	return NULL;
}

/* Monitor display state via sysfs backlight brightness */
static void *display_monitor(void *arg)
{
	(void)arg;
	int last_state = -1;
	const char *brightness_path = "/sys/class/backlight/panel0-backlight/brightness";

	if (access(brightness_path, R_OK) != 0) {
		LOGW("display monitor: %s not available", brightness_path);
		return NULL;
	}

	while (running) {
		int fd = open(brightness_path, O_RDONLY);
		int brightness = 0;

		if (fd >= 0) {
			char buf[16];
			ssize_t n = read(fd, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				brightness = atoi(buf);
			}
			close(fd);
		}

		int new_state = (brightness > 0) ? 1 : 0;
		if (new_state != last_state) {
			apex_write_policy(new_state ? "screen_on" : "screen_off");
			last_state = new_state;
		}

		for (int i = 0; i < 2 && running; i++)
			sleep(1);
	}
	return NULL;
}

/* Monitor charging state via sysfs power_supply */
static void *charge_monitor(void *arg)
{
	(void)arg;
	int last_charging = -1;
	const char *charging_path = "/sys/class/power_supply/battery/charging";
	const char *online_path = "/sys/class/power_supply/usb/online";

	const char *use_path = NULL;
	if (access(charging_path, R_OK) == 0)
		use_path = charging_path;
	else if (access(online_path, R_OK) == 0)
		use_path = online_path;
	else {
		LOGW("charge monitor: no power_supply sysfs path available");
		return NULL;
	}

	while (running) {
		int fd = open(use_path, O_RDONLY);
		int charging = 0;

		if (fd >= 0) {
			char buf[16];
			ssize_t n = read(fd, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				charging = (atoi(buf) > 0);
			}
			close(fd);
		}

		if (charging != last_charging) {
			char cmd[16];
			snprintf(cmd, sizeof(cmd), "charge %d", charging);
			apex_write_policy(cmd);
			last_charging = charging;
		}

		for (int i = 0; i < 5 && running; i++)
			sleep(1);
	}
	return NULL;
}

/* Monitor battery level and implement 80% charging hold */
static void *battery_monitor(void *arg)
{
	(void)arg;
	const char *cap_path = "/sys/class/power_supply/battery/capacity";
	const char *status_path = "/sys/class/power_supply/battery/status";

	if (access(cap_path, R_OK) != 0) {
		LOGW("battery monitor: %s not available", cap_path);
		return NULL;
	}

	while (running) {
		char buf[16];
		int capacity = -1;
		int charging = 0;

		int fd = open(cap_path, O_RDONLY);
		if (fd >= 0) {
			ssize_t n = read(fd, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				capacity = atoi(buf);
			}
			close(fd);
		}

		/* Check charging status */
		fd = open(status_path, O_RDONLY);
		if (fd >= 0) {
			ssize_t n = read(fd, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				charging = (strstr(buf, "Charging") != NULL);
			}
			close(fd);
		}

		if (capacity >= 0) {
			/* Low battery: enable charging */
			if (capacity < BATTERY_LOW_PCT && !charging) {
				apex_write_policy("charge 1");
				LOGI("battery low (%d%%) — enabling charge", capacity);
			}
			/* High battery: stop charging (80% hold) */
			else if (capacity >= BATTERY_HIGH_PCT && charging) {
				apex_write_policy("charge 0");
				LOGI("battery high (%d%%) — charge hold", capacity);
			}
		}

		for (int i = 0; i < 30 && running; i++)
			sleep(1);
	}
	return NULL;
}

/* Monitor thermal zones and warn on high temperatures */
static void *thermal_monitor(void *arg)
{
	(void)arg;
	const char *tz_path = "/sys/class/thermal/thermal_zone0/temp";

	if (access(tz_path, R_OK) != 0) {
		LOGW("thermal monitor: %s not available", tz_path);
		return NULL;
	}

	while (running) {
		int fd = open(tz_path, O_RDONLY);
		int temp_mc = 0;

		if (fd >= 0) {
			char buf[16];
			ssize_t n = read(fd, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				temp_mc = atoi(buf);
			}
			close(fd);
		}

		if (temp_mc > 0) {
			if (temp_mc >= THERMAL_CRIT_MC) {
				LOGW("thermal critical: %d.%d C",
				     temp_mc / 1000, (temp_mc % 1000) / 100);
				/* Reduce non-essential activity */
				apex_write_policy("audio 0");
			} else if (temp_mc >= THERMAL_WARN_MC) {
				LOGW("thermal warning: %d.%d C",
				     temp_mc / 1000, (temp_mc % 1000) / 100);
			}
		}

		for (int i = 0; i < 10 && running; i++)
			sleep(1);
	}
	return NULL;
}

/* Verify client UID is root (0) only via SO_PEERCRED.
 * system_server (uid 1000) is NOT allowed — it has too many
 * permissions and a compromised system_server could abuse the
 * bridge to execute arbitrary commands or load kernel modules. */
static int check_client_cred(int fd)
{
	struct ucred cred;
	socklen_t len = sizeof(cred);

	if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0) {
		LOGE("getsockopt SO_PEERCRED: %s", strerror(errno));
		return -1;
	}

	if (cred.uid != 0) {
		LOGW("rejected client uid=%u pid=%u (root only)", cred.uid, cred.pid);
		return -1;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	struct sockaddr_un addr;
	pthread_t display_tid, charge_tid, battery_tid, thermal_tid;

	(void)argc;
	(void)argv;

	/* Use sigaction without SA_RESTART so accept() is interrupted */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = signal_handler;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	/* Create Unix domain socket */
	server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (server_fd < 0) {
		LOGE("socket: %s", strerror(errno));
		return 1;
	}

	/* Set larger socket buffers for reliability */
	int sock_buf = SOCK_BUF_SIZE;
	setsockopt(server_fd, SOL_SOCKET, SO_RCVBUF, &sock_buf, sizeof(sock_buf));
	setsockopt(server_fd, SOL_SOCKET, SO_SNDBUF, &sock_buf, sizeof(sock_buf));

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

	unlink(SOCKET_PATH);
	if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		LOGE("bind: %s", strerror(errno));
		close(server_fd);
		return 1;
	}

	/* Restrict socket to root-only (0600). Only root (apex-bridge runs
	 * as root via init.rc) can connect. Client UID is verified via
	 * SO_PEERCRED in check_client_cred() — uid 0 only. */
	chmod(SOCKET_PATH, 0600);
	listen(server_fd, MAX_CLIENTS);

	/* Start monitor threads */
	pthread_create(&display_tid, NULL, display_monitor, NULL);
	pthread_create(&charge_tid, NULL, charge_monitor, NULL);
	pthread_create(&battery_tid, NULL, battery_monitor, NULL);
	pthread_create(&thermal_tid, NULL, thermal_monitor, NULL);

	LOGI("listening on %s", SOCKET_PATH);

	/* Accept loop */
	while (running) {
		int *client_fd = malloc(sizeof(int));
		pthread_t tid;

		if (!client_fd)
			break;

		*client_fd = accept(server_fd, NULL, NULL);
		if (*client_fd < 0) {
			free(client_fd);
			if (!running)
				break; /* shutdown */
			if (errno == EINTR)
				continue;
			LOGE("accept: %s", strerror(errno));
			continue;
		}

		/* Verify client credentials before processing commands */
		if (check_client_cred(*client_fd) < 0) {
			close(*client_fd);
			free(client_fd);
			continue;
		}

		pthread_create(&tid, NULL, client_thread, client_fd);
		pthread_detach(tid);
	}

	/* Join monitor threads for clean shutdown */
	pthread_join(display_tid, NULL);
	pthread_join(charge_tid, NULL);
	pthread_join(battery_tid, NULL);
	pthread_join(thermal_tid, NULL);

	if (server_fd >= 0)
		close(server_fd);
	unlink(SOCKET_PATH);
	LOGI("apex-bridge shutting down");
	return 0;
}
