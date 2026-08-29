# APEX Kernel — Under-Developed Parts Audit

Systematic sweep for stubs, placeholders, dead code, unimplemented design
features, stale documentation, and hardcoded values that need real
implementations.

## Summary

| # | Component | Severity | Category |
|---|-----------|----------|----------|
| 1 | WALT load integration — `cpu_util_val = 0` | High | Placeholder |
| 2 | Watchdog boot self-check — polynomial hash, not SHA256 | High | Placeholder |
| 3 | Decision table outputs never consumed (sensor_rate, bt_scan, wifi) | High | Dead code |
| 4 | Sensor status proc — hardcoded rate caps, no real IIO enumeration | Medium | Stub |
| 5 | NFC raw frame write — opens device, logs, never writes data | Medium | Stub |
| 6 | IR raw frame write — opens device, logs, never writes data | Medium | Stub |
| 7 | AlarmKeeper — uses popen("dumpsys alarm") (command injection risk) | Medium | Security |
| 8 | apex-memfreq — placeholder bandwidth values, icc_get(0,0) dummy IDs | Medium | Skeleton |
| 9 | apex-lmk — sysinfo.filepage field doesn't exist in kernel 5.15 | Medium | Bug |
| 10 | defconfig/README.md — stale (HZ=200, Clang 19+LTO, missing new fragments) | Low | Stale doc |
| 11 | package-anykernel3.sh — version still 1.0.0 | Low | Stale version |
| 12 | Watchdog self-check string — still says v1.1.0 | Low | Stale version |
| 13 | Touch processing pipeline — not implemented (research only) | Low | Future |
| 14 | AutoFDO — pipeline script only, no profile data | Low | Future |
| 15 | Apex Control app — single activity, no settings/governor tuning UI | Low | Incomplete |

---

## Detailed Findings

### 1. WALT load integration — placeholder zero [HIGH]

**File:** `patches/apex-governor/src/cpufreq_apex.c:107`
**Code:**
```c
cpu_util_val = 0;  /* placeholder — real impl uses
                    * walt_util_cpu(cpu, CPU_UTIL_MAX) */
```
**Impact:** The governor's WALT-aware load sampling always returns 0 from
this path. The governor falls back entirely to dbs sampling, which is less
accurate for bursty phone workloads. This is the single most impactful
placeholder — WALT integration was a key design goal and the config enables
`CONFIG_SCHED_WALT=y` but the governor never reads the WALT signal.
**Fix:** Use `walt_util_cpu(cpu, SCHED_CAPACITY_SCALE)` or the equivalent
kernel API available in the CAF bengal-5.15 tree. Needs kernel-tree
verification of the exact function signature.

### 2. Watchdog boot self-check — polynomial hash, not crypto [HIGH]

**File:** `patches/apex-watchdog/src/apex_watchdog.c:720-734`
**Code:**
```c
/* In a real implementation, this would use crypto_shash.
 * For now, we do a simple checksum of the module name and
 * version as a basic sanity check. */
const char *check_str = "apex_watchdog_v1.1.0";
unsigned int hash = 0;
for (i = 0; check_str[i]; i++)
    hash = hash * 31 + check_str[i];
```
**Impact:** The "SHA256 self-check" is a 32-bit polynomial hash of a static
string. It provides zero integrity verification — any attacker can compute
it. The comment admits this. The function always returns 0 (success).
**Fix:** Use `crypto_alloc_shash("sha256")` + `crypto_shash_update()` on
the module's `.text` section (via `this_module->core_layout.base` and
`.size`). This requires `CONFIG_CRYPTO_SHA256` which is likely already
enabled for module signing.

### 3. Decision table outputs never consumed [HIGH]

**File:** `patches/apex-state/src/apex.c`
**Issue:** The 16-entry decision table has three output fields:
- `sensor_rate_hz` (10 or 200)
- `bt_scan_enabled` (true/false)
- `wifi_multicast` (true/false)

These are set in every entry but **never read** in `apex_apply_policy()`.
The function only reads `dec->row`, `dec->gov_screen_off`, `dec->gov_gaming`,
`dec->gpu_performance`, and `dec->gpu_powersave`. The sensor/BT/WiFi outputs
are dead data — they exist in the table but have no effect on system behavior.
**Impact:** The decision table claims to control sensor rates, BT scanning,
and WiFi multicast, but doesn't. The `/proc/apex/sensor_status` proc entry
reports hardcoded values ("10 Hz screen off", "200 Hz screen on") instead of
reading from the decision table.
**Fix:** In `apex_apply_policy()`, add code to:
1. Write `dec->sensor_rate_hz` to the IIO sysfs rate control
2. Enable/disable BT scan based on `dec->bt_scan_enabled`
3. Enable/disable WiFi multicast filter based on `dec->wifi_multicast`
Or, if these are intentionally userspace-controlled, remove the fields from
the decision table and the proc entry to avoid false claims.

### 4. Sensor status proc — hardcoded, no IIO enumeration [MEDIUM]

**File:** `patches/apex-state/src/apex.c:1031-1041`
**Code:**
```c
if (kern_path("/sys/bus/iio/devices", LOOKUP_FOLLOW, &p) == 0) {
    /* Simplified: just report path exists */
    path_put(&p);
    seq_printf(m, "iio_bus: available\n");
} else {
    seq_printf(m, "iio_bus: unavailable\n");
}
seq_printf(m, "background_rate_cap: 10 Hz (screen off)\n");
seq_printf(m, "foreground_rate_cap: 200 Hz (screen on)\n");
```
**Impact:** The sensor status proc entry only checks if the IIO bus path
exists. It doesn't enumerate IIO devices, report actual sensor rates, or
read the decision table's `sensor_rate_hz`. The rate caps are hardcoded
strings.
**Fix:** Enumerate `/sys/bus/iio/devices/iio:device*` and report device
names + current sampling rates. Read the current decision table's
`sensor_rate_hz` for the rate cap.

### 5. NFC raw frame write — opens device but never writes [MEDIUM]

**File:** `chroot/bridge/apex-bridge.c:506-511`
**Code:**
```c
int fd = open("/dev/st21nfc", O_WRONLY);
if (fd >= 0) {
    /* Convert hex string to bytes (simplified — real impl
     * would use a proper hex decoder) */
    apex_incident_log("nfc: raw frame write (%zu bytes)", strlen(frame) / 2);
    close(fd);
    snprintf(response, resp_len, "{\"ok\":true}");
```
**Impact:** The bridge opens the NFC device, logs that it's writing, but
never actually writes the frame data. The response says `ok:true` even
though nothing was sent. The hex-to-bytes conversion is commented as
"simplified" but is actually missing entirely.
**Fix:** Implement a proper hex decoder (`hex2bin()` equivalent) and
`write(fd, binary_frame, frame_len)` before `close(fd)`.

### 6. IR raw frame write — same pattern as NFC [MEDIUM]

**File:** `chroot/bridge/apex-bridge.c:523-526`
**Code:**
```c
int fd = open("/dev/lirc0", O_WRONLY);
if (fd >= 0) {
    apex_incident_log("ir: raw frame transmit");
    close(fd);
    snprintf(response, resp_len, "{\"ok\":true}");
```
**Impact:** Same as NFC — opens device, logs, never writes. Returns success
without transmitting anything.
**Fix:** Implement LIRC frame encoding and `write()` the encoded frame.

### 7. AlarmKeeper — popen("dumpsys alarm") [MEDIUM]

**File:** `rom-overlays/bin/apex-alarmkeeper.c:60`
**Code:**
```c
FILE *dump = popen("dumpsys alarm", "r");
```
**Impact:** Uses `popen()` which spawns a shell. While the command is
hardcoded (not user-controlled, so no direct injection), it's inconsistent
with the bridge daemon's `exec_safe` (fork+execvp) pattern. The comment
acknowledges this is intentional ("only stable way to read AlarmManager"),
but it means a compromised PATH or shell binary could intercept the call.
**Fix:** Replace with `fork()` + `execvp("dumpsys", ...)` + `pipe()` for
output capture, matching the bridge daemon's `exec_safe` pattern.

### 8. apex-memfreq — placeholder bandwidth, dummy interconnect IDs [MEDIUM]

**File:** `patches/apex-memfreq/src/apex_memfreq.c`
**Issues:**
- Bandwidth values (100000, 1000000, 3000000, 6000000 kbps) are placeholder
  guesses, not from the SM6225 interconnect OPP table
- `icc_get(&apex_memfreq_dev, 0, 0)` uses dummy src/dst IDs (0, 0) — will
  not resolve to a real interconnect path
- The `apex_memfreq_dev` is a stack-allocated `struct device` with only
  `init_name` set — not a real registered device
**Status:** Explicitly marked as skeleton in comments and README. This is
expected — the driver needs device-tree-specific values to function.
**Fix:** Needs SM6225 device tree analysis to identify:
1. Correct interconnect path names and IDs
2. Actual bandwidth OPP levels
3. Proper device registration

### 9. apex-lmk — sysinfo.filepage doesn't exist [MEDIUM]

**File:** `patches/apex-lmk/src/apex_simple_lmk.c:78`
**Code:**
```c
cache_pages = min(si.filepage, (unsigned long)atomic_read(...));
```
**Issue:** `struct sysinfo` in Linux 5.15 does not have a `filepage` field.
The correct field is `si.freeswap` for swap pages, but for file cache you
need `global_node_page_state(NR_FILE_PAGES)` or similar. This will cause
a compile error when built against the actual kernel tree.
**Fix:** Use `global_node_page_state(NR_FILE_PAGES)` for file cache pages,
or `si.freeram + si.bufferram` as a simpler approximation.

### 10. defconfig/README.md — stale [LOW]

**File:** `defconfig/README.md`
**Issues:**
- Says "HZ=200" but scheduler.config uses HZ=250
- Says "Clang 19 + LLD + LTO + CFI" but toolchain.config uses Clang 22 + ThinLTO
- Missing entries for: `performance.config`, `filesystems.config`, `display.config`
- Says "STRICT_DEVMEM" but hardening.config doesn't set it (DEVMEM disabled in base defconfig)
- Key optimizations list says "HZ: 200 (vs stock 250)" — backwards and stale

### 11. package-anykernel3.sh — version 1.0.0 [LOW]

**File:** `tools/package-anykernel3.sh:10`
**Code:** `VERSION="1.0.0"`
**Issue:** Still says 1.0.0 while build-kernel.sh and apex.c are at 1.2.0.
The flashable zip will be named `apex-kernel-1.0.0-anykernel3.zip` despite
being a 1.2.0 build.

### 12. Watchdog self-check string — v1.1.0 [LOW]

**File:** `patches/apex-watchdog/src/apex_watchdog.c:726`
**Code:** `const char *check_str = "apex_watchdog_v1.1.0";`
**Issue:** Version string in the self-check is stale (should be v1.2.0).

### 13-15. Future work items [LOW]

- **Touch processing pipeline:** Research document only, no code. Expected.
- **AutoFDO:** Pipeline script only, no profile data collected. Expected.
- **Apex Control app:** Single `MainActivity.kt` (328 lines) with basic
  status display and gaming toggle. No settings screen, no governor tuning
  UI, no incident log viewer (claimed in README but not in code), no
  thermal profile display. The app is a minimal proof-of-concept.

---

## Priority Fix Order

1. **#1 WALT load** — highest impact, governor's key feature is neutered
2. **#9 apex-lmk compile bug** — will fail to compile against real kernel
3. **#3 Dead decision outputs** — false claims of sensor/BT/WiFi control
4. **#2 Watchdog self-check** — security feature is fake
5. **#5+#6 NFC/IR write** — bridge claims success without doing anything
6. **#7 AlarmKeeper popen** — security consistency
7. **#4 Sensor status** — stub reporting
8. **#10-12 Stale docs/versions** — cosmetic but misleading
