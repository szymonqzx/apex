/*
 * apex-alarmkeeper — mirrors the earliest pending RTC_WAKEUP alarm to
 * /proc/apex/wakealarm every 60 s. The kernel-side handler (patch
 * apex-state) writes the same time to /sys/class/rtc/rtc0/wakealarm so the
 * PMIC fires the alarm even if the SoC is fully powered off.
 *
 * Installed at /vendor/bin/apex-alarmkeeper (BUILD_PLAN.md §6.4).
 *
 * Build (bionic, on-device or in an Android NDK toolchain):
 *   clang --target=aarch64-linux-android21 -O2 -s \
 *     -o apex-alarmkeeper apex-alarmkeeper.c -llog
 *
 * The design's system("dumpsys alarm | ...") pipeline is intentionally kept:
 * it is the only stable way to read AlarmManager's pending alarms without
 * linking against the framework binder stubs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/wait.h>
#include <android/log.h>

#define WAKEALARM_PATH "/proc/apex/wakealarm"
#define POLL_SECS 60
#define TAG "apex-alarmkeeper"

static volatile sig_atomic_t running = 1;

static void signal_handler(int sig)
{
	(void)sig;
	running = 0;
}

static void log_err(const char *msg)
{
	__android_log_print(ANDROID_LOG_ERROR, TAG, "%s: %s", msg,
			    strerror(errno));
}

static void log_warn(const char *msg)
{
	__android_log_print(ANDROID_LOG_WARN, TAG, "%s", msg);
}

static void log_info(const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	__android_log_print(ANDROID_LOG_INFO, TAG, "%s", buf);
}

/* Execute a command and capture its stdout via fork+execvp+pipe.
 * This replaces popen() to avoid spawning a shell (security consistency
 * with apex-bridge's exec_safe pattern). Returns FILE* on success,
 * NULL on failure. Caller must call pclose_safe() when done. */
static FILE *exec_capture(const char *cmd, char *const argv[])
{
	int pipefd[2];
	pid_t pid;

	if (pipe(pipefd) < 0) {
		log_err("pipe() failed");
		return NULL;
	}

	pid = fork();
	if (pid < 0) {
		log_err("fork() failed");
		close(pipefd[0]);
		close(pipefd[1]);
		return NULL;
	}

	if (pid == 0) {
		/* Child: redirect stdout to pipe, exec command */
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[1]);
		execvp(cmd, argv);
		/* If execvp returns, it failed */
		_exit(127);
	}

	/* Parent: read from pipe */
	close(pipefd[1]);

	/* Convert pipe fd to FILE* for fgets() compatibility */
	FILE *fp = fdopen(pipefd[0], "r");
	if (!fp) {
		log_err("fdopen() failed");
		close(pipefd[0]);
		/* Reap child */
		int status;
		waitpid(pid, &status, 0);
		return NULL;
	}

	return fp;
}

/* Close a FILE* opened by exec_capture and reap the child process. */
static void pclose_safe(FILE *fp)
{
	if (!fp)
		return;
	int fd = fileno(fp);
	fclose(fp);
	/* Reap child process */
	int status;
	waitpid(-1, &status, 0);
	(void)fd;
}

static int mirror_wakealarm(void)
{
	char *const argv[] = { "dumpsys", "alarm", NULL };
	FILE *dump = exec_capture("dumpsys", argv);
	if (!dump) {
		log_err("exec_capture(dumpsys alarm) failed");
		return -1;
	}

	FILE *out = fopen(WAKEALARM_PATH, "w");
	if (!out) {
		log_err("fopen(wakealarm) failed");
		pclose_safe(dump);
		return -1;
	}

	char line[512];
	int found = 0;
	while (fgets(line, sizeof(line), dump)) {
		/* Lines look like: RTC_WAKEUP #0: Alarm{... when=1234567890 ...} */
		if (!strstr(line, "RTC_WAKEUP"))
			continue;
		char *when = strstr(line, "when=");
		if (!when)
			continue;
		when += 5;
		/* Strip everything from the first non-digit. */
		char *end = when;
		while (*end >= '0' && *end <= '9')
			end++;
		if (end == when)
			continue;
		*end = '\0';
		fprintf(out, "%s\n", when);
		found = 1;
		log_info("miraged alarm: epoch %s", when);
		break; /* earliest = first RTC_WAKEUP line */
	}

	fclose(out);
	pclose_safe(dump);

	if (!found)
		log_warn("no RTC_WAKEUP alarms found in dumpsys output");
	return found ? 0 : -1;
}

static void check_wakealarm_exists(void)
{
	if (access(WAKEALARM_PATH, F_OK) != 0)
		log_warn("/proc/apex/wakealarm not found — apex module not loaded?");
}

int main(int argc, char **argv)
{
	int once = 0;

	if (argc > 1 && strcmp(argv[1], "--once") == 0)
		once = 1;

	/* Signal handling for clean shutdown */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = signal_handler;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	check_wakealarm_exists();

	if (once) {
		int ret = mirror_wakealarm();
		return ret == 0 ? 0 : 1;
	}

	log_info("started (poll=%ds)", POLL_SECS);

	while (running) {
		mirror_wakealarm();
		/* Use sleep(1) in a loop so signals are caught promptly */
		for (int i = 0; i < POLL_SECS && running; i++)
			sleep(1);
	}

	log_info("shutting down");
	return 0;
}
