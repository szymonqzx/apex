# APEX ROM — Boil-the-Sea Implementation Plan

**Generated**: 2026-09-05
**Branch**: feat/zepharo-rebase (HEAD: 310d1d4)
**Device**: Redmi Note 12 4G (topaz/tapas), SM6225-AD, 8GB RAM, 128GB UFS 2.2
**Base**: LineageOS 23.2 (Android 16 QPR2)
**Kernel**: APEX v0.4.2 (Linux 5.15.211, KernelSU-Next + SuSFS)

---

## Current State Assessment

### Built and Verified (T1-T8, commit 310d1d4)
- Agent spine: 14 Java classes (2,769 lines), 3 AIDL interfaces, JNI bridges (llama.cpp + whisper.cpp)
- Apex Control app: 19 Kotlin files (2,942 lines) — agent chat, power user, model router, audit log
- ROM overlays: 16 init.d scripts, 2 SELinux policies, device.mk, build.prop appends
- Update system: Virtual A/B verification, OTA fallback, update engine
- Chroot bridge: apex-bridge.c daemon, apex-term.sh wrapper, apex-bridge.rc
- Tests: 276/278 pass, verify.sh 31/31 PASS
- Kernel: v0.4.2 built and packaged (AnyKernel3 zips in releases/)

### Not Yet Built (the sea)
1. **Kernel audit fixes** — 15 issues (3 HIGH, 6 MEDIUM, 6 LOW)
2. **LOS source tree** — not synced, ROM cannot be built
3. **ROM build** — build-rom.sh exists but preflight fails (no ~/los)
4. **NFCForge** — no code exists
5. **PTK TUI** — no code exists
6. **APEX WM** — no code exists (P3)
7. **Desktop Mode** — no code exists (P3, depends on WM)
8. **Lindroid** — no code exists (P4, depends on WM + Desktop)
9. **Remote Model** — placeholder only, no HTTP client
10. **E3 charge control** — agent read-only, no write tools
11. **Pentest driver matrix** — defconfig has configs, no out-of-tree driver builds
12. **Hiding stack** — no Shamiko/HMA/TrickyStore/Yurikey integration
13. **Migration script** — apex-migrate.sh exists but untested
14. **Daily-driver fixes** — defconfig entries exist, unverified against real tree
15. **7-day thermal learner** — not implemented
16. **PMIC WDT + safe-mode** — not implemented
17. **Touch processing pipeline** — research only
18. **AutoFDO** — script only, no profile data

---

## Phase 1: Kernel Audit Fixes (15 items)

**Goal**: Fix every stub, placeholder, dead code, and bug identified in UNDERDEVELOPED_AUDIT.md.
**Success criterion**: All 15 audit items resolved, kernel compiles against bengal-5.15 tree, no new warnings.

### 1.1 HIGH Priority Fixes

| # | Issue | File | Fix |
|---|-------|------|-----|
| 1 | WALT load placeholder (cpu_util_val=0) | `patches/apex-governor/src/cpufreq_apex.c:107` | Replace with `walt_util_cpu(cpu, SCHED_CAPACITY_SCALE)` — verify exact API signature in CAF bengal-5.15 tree |
| 2 | Watchdog polynomial hash (not SHA256) | `patches/apex-watchdog/src/apex_watchdog.c:720-734` | Use `crypto_alloc_shash("sha256")` + `crypto_shash_update()` on module `.text` section. Requires `CONFIG_CRYPTO_SHA256=y` (likely already set for module signing) |
| 3 | Dead decision table outputs | `patches/apex-state/src/apex.c` | Wire `sensor_rate_hz` → IIO rate cap via `apex_apply_policy()`, `bt_scan_enabled` → `cmd sensorservice set_rate`, `wifi_multicast` → `cmd wifi set-wifi-watchdog-params`. Or remove the three fields from the decision table if they're not needed (honest code > dead code) |

### 1.2 MEDIUM Priority Fixes

| # | Issue | File | Fix |
|---|-------|------|-----|
| 4 | Sensor status stub (hardcoded rates) | `patches/apex-state/src/apex_sensor.c` | Enumerate IIO devices via `iio_device_list()` or `/sys/bus/iio/devices/`, report real per-sensor rates |
| 5 | NFC raw frame write stub | `chroot/bridge/apex-bridge.c` | Implement actual write path: open `/dev/st21nfc`, send NCI raw frame, read response. Add timeout + error handling |
| 6 | IR raw frame write stub | `chroot/bridge/apex-bridge.c` | Implement actual write path: open `/dev/lirc0`, send raw IR frame via LIRC ioctl (`LIRC_SET_SEND_MODE` + write) |
| 7 | AlarmKeeper popen injection | `rom-overlays/bin/apex-alarmkeeper.c` | Replace `popen("dumpsys alarm")` with Binder IPC to `IAlarmManager` via `ServiceManager.getService("alarm")`. Parse `AlarmManager` parcel directly |
| 8 | memfreq placeholder values | `patches/apex-memfreq/src/apex_memfreq.c` | Needs SM6225 device tree analysis: interconnect path names/IDs from `arch/arm64/boot/dts/qcom/sm6225.dtsi`, actual bandwidth OPP levels, proper `platform_device` registration |
| 9 | apex-lmk sysinfo.filepage bug | `patches/apex-lmk/src/apex_simple_lmk.c:78` | Replace `si.filepage` with `global_node_page_state(NR_FILE_PAGES)` |

### 1.3 LOW Priority Fixes

| # | Issue | File | Fix |
|---|-------|------|-----|
| 10 | defconfig/README.md stale | `defconfig/README.md` | Update HZ=250, Clang 22+ThinLTO, add missing config fragments, fix STRICT_DEVMEM description |
| 11 | package-anykernel3.sh version 1.0.0 | `tools/package-anykernel3.sh:10` | Bump to match build-kernel.sh version (1.2.0) |
| 12 | Watchdog self-check string v1.1.0 | `patches/apex-watchdog/src/apex_watchdog.c:726` | Update to v1.2.0 |
| 13 | Touch processing pipeline | `docs/TOUCH_PIPELINE_RESEARCH.md` | Keep as research doc. Implementation deferred to post-ROM-build |
| 14 | AutoFDO profile data | `tools/autofdo-build.sh` | Keep script. Profile collection requires on-device perf recording after ROM is running |
| 15 | Apex Control app incomplete | `apps/apex-control/` | Already expanded to 19 files in T1-T8. Remaining: governor tuning UI, thermal profile display, incident log viewer |

### 1.4 Verification
- `tools/build-kernel.sh` compiles clean against bengal-5.15 tree
- `tools/verify.sh` all PASS
- `tools/check-configs.py` no regressions
- New test: `tests/kernel/test_audit_fixes.py` — verify each fix is present and functional

---

## Phase 2: LOS Source Tree Sync + ROM Build

**Goal**: Get a real LineageOS 23.2 source tree and produce a flashable APEX ROM zip.
**Success criterion**: `build-rom.sh` completes, produces `apex-rom-1.0.0-topaz.zip`, zip passes brick-safety verification.

### 2.1 Source Tree Sync

```
mkdir -p ~/los
cd ~/los
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs
repo sync -c -j$(nproc) --no-tags --no-clone-bundle
```

Device-specific repos:
- `device/xiaomi/topaz` — https://github.com/LineageOS/android_device_xiaomi_topaz.git
- `kernel/xiaomi/topaz` — CAF bengal-5.15 (or use APEX kernel prebuilt)
- `vendor/xiaomi/topaz` — proprietary blobs (from TheMuppets or extract)

### 2.2 APEX ROM Integration

1. **Copy APEX overlays** into LOS tree:
   - `rom-overlays/device/apex_device.mk` → include in `device/xiaomi/topaz/lineage_topaz.mk`
   - `rom-overlays/init.d/*.rc` → `device/xiaomi/topaz/prebuilt/etc/init/`
   - `rom-overlays/init.d/*.sh` → `device/xiaomi/topaz/prebuilt/bin/`
   - `rom-overlays/build.prop/*.append` → merged via `PRODUCT_PRODUCT_PROPERTIES +=`
   - `rom-overlays/selinux/*.te` → `device/xiaomi/topaz/sepolicy/`
   - `rom-overlays/hidden_packages.list` → `PRODUCT_PACKAGES +=` hide list

2. **APEX kernel as prebuilt**:
   - Build APEX kernel separately (`tools/build-kernel.sh`)
   - Place Image.gz + dtbs in `device/xiaomi/topaz/prebuilt/kernel/`
   - `apex_device.mk` references prebuilt, not source kernel build

3. **Agent packages**:
   - `agent/` → AOSP system app (signed with platform key)
   - `apps/apex-control/` → priv-app
   - `agent/sepolicy/apex_agent.te` → merged into ROM sepolicy

4. **Virtual A/B + OTA**:
   - `rom-overlays/device/apex_ab_ota_config.txt` → AB OTA config
   - `rom-overlays/update/*.sh` → update_engine scripts

### 2.3 Build

```bash
cd ~/los
source build/envsetup.sh
lunch lineage_topaz-userdebug
mka apex-rom -j$(nproc)
```

### 2.4 Brick-Safety Verification
- `tools/verify-brick-safety.sh` scans ROM zip for dangerous flash commands
- No `dd if=` targeting: aboot, sbl1-3, tz, rpm, hyp, modem, bootloader, devinfo, partition
- No `fastboot flash bootloader` or similar

### 2.5 Dirty-Flash Upgrade Path
- ROM zip installable over current `23.2-20260328-UNOFFICIAL-tapas`
- Data preserved (no wipe)
- `apex_ab_verify.sh` runs on first boot of new slot
- `docs/DIRTY_FLASH_UPGRADE_SPEC.md` documents the path

---

## Phase 3: Hiding Stack Integration

**Goal**: Integrate the 4-piece userspace hiding stack into the ROM.
**Success criterion**: Shamiko + HMA-OSS + TrickyStore + Yurikey installed, Play Integrity passes (DEVICE + STRONG), 76-vector audit passes.

### 3.1 KernelSU-Next + Zygisk-Next
- KSU-Next already in APEX kernel (compiled in, not module)
- Zygisk-Next: include as KSU module in ROM zip `/data/adb/modules/zygisk_next/`
- Configures Zygisk runtime for Shamiko + TrickyStore

### 3.2 Shamiko (denylist)
- Include as KSU module: `/data/adb/modules/shamiko/`
- Denylist configured via `hidden_packages.list`
- Hides root from target apps (banking, Google Play Services)

### 3.3 HMA-OSS (denylist2)
- Include as KSU module: `/data/adb/modules/hma_oss/`
- PM/path blacklist: `pm list packages`, `dumpsys package`, `pm path` filtered
- Consumes `rom-overlays/hidden_packages.list`

### 3.4 TrickyStore + Yurikey
- TrickyStore: KSU module, injects keybox into hardware-backed KeyStore HAL
- Yurikey: one-time keybox manager (user's existing proven setup)
- Keybox stored at `/data/adb/tricky_store/keybox.xml`
- Play Integrity STRONG tier passes

### 3.5 PIF (Play Integrity Fingerprint)
- No PIF module — dirty build.prop overlay only
- `rom-overlays/build.prop/system.build.prop.append` contains stock Xiaomi fingerprint
- `ro.build.fingerprint`, `ro.build.type=user`, `ro.debuggable=0`, `ro.secure=1`

### 3.6 Verification
- `adb shell am start -n com.google.android.gms/.integrity.IntegrityRequestActivity` — DEVICE pass
- Play Integrity API check via third-party app — STRONG pass
- 76-vector audit: `tools/verify-stealth.sh` (new tool to write)
- SELinux stays Enforcing throughout

---

## Phase 4: Pentest Driver Matrix

**Goal**: Build and package all out-of-tree pentest drivers as loadable kernel modules.
**Success criterion**: All drivers compile as `.ko`, VID:PID autoload works, zero idle drain when no adapter plugged.

### 4.1 Out-of-Tree Wi-Fi Drivers

| Driver | Source | Adapter | Chipset |
|--------|--------|---------|---------|
| `rtl8812au` | aircrack-ng v5.6.4.2 | AWUS036ACH, AWUS1900 | RTL8812AU/14AU |
| `rtl88x2bu` | Morrown fork 5.13+ | AWUS036ACU | RTL88x2BU |
| `rtl8188eus` | monitor-mode patched | AWUS036NEH | RTL8188EUS |
| `mt7610u` | MediaTek open source | AWUS036ACM | MT7610U |
| `mt7612u` | MediaTek open source | AWUS036CAH | MT7612U |

Build approach:
- Clone each driver repo into `drivers/net/wireless/external/`
- Add `external.mk` that builds each as `m` against APEX kernel headers
- Package as separate flashable module zip (not in base ROM — too large)
- `tools/build-pentest-drivers.sh` — builds all, packages into `pentest-modules.zip`

### 4.2 In-Tree Drivers (already in defconfig)
- `ath9k_htc`, `carl9170`, `rtl8187` — built as modules from kernel source
- `rtl28xxu` (SDR), `hackrf`, `airspy` — built as modules
- `gs_usb`, `peak_usb`, `slcan` (CAN) — built as modules
- `ch341`, `ftdi_sio`, `cp210x`, `pl2303` (UART) — built as modules
- `lirc`, `ir_toy`, IR decoders — built as modules

### 4.3 VID:PID Autoloader
- `drivers/usb/core/apex_autoload.c` — already designed in DESIGN.md
- Matches plugged adapter VID:PID, calls `request_module()` for the right `.ko`
- Implement as kernel patch (not module — needs core USB hook)

### 4.4 NFCForge App
- **Purpose**: Card cloning, key recovery, magic-card detect/write, UID emulation, raw APDU terminal
- **Architecture**: Kotlin app, communicates via apex-bridge socket to chroot
- **Dependencies**: crapto1, mfoc, mfcuk (in Arch chroot)
- **UI**: Guided operations with preview-confirm, availability-aware scoping
- **Files to create**:
  - `apps/nfcforge/app/src/main/java/com/apex/nfcforge/` — Kotlin sources
  - `apps/nfcforge/app/src/main/AndroidManifest.xml`
  - `apps/nfcforge/app/build.gradle.kts`
  - Bridge protocol extensions in `chroot/bridge/apex-bridge.c` for NFC ops

### 4.5 PTK TUI
- **Purpose**: Pentest terminal fallback, launched from Apex Control
- **Architecture**: Terminal emulator app (or Termux integration) running in chroot
- **Shares**: Same SQLite store as Apex Control
- **Implementation**: Either custom terminal app or launch `apex-term.sh` via Termux:Tasker intent
- **Files to create**:
  - `apps/ptk-tui/` — minimal launcher app
  - Integration with `chroot/apex-term.sh`

---

## Phase 5: Zero-Maintenance + Self-Recovery

**Goal**: Implement the full zero-maintenance subsystem from DESIGN.md §10.
**Success criterion**: 4-input state machine drives policy, watchdog runs every 5 min, PMIC WDT active, 7-day thermal learner collects data.

### 5.1 4-Input State Machine (kernel)
- Already partially in `patches/apex-state/src/apex.c`
- **Fix needed**: Wire dead decision table outputs (audit #3)
- Inputs: screen_on, charging, audio_active, foreground_uid
- 16-entry decision table → policy outputs
- `/proc/apex/*` procfs entries (0444, read-only)

### 5.2 5-Min Watchdog (kernel)
- `patches/apex-watchdog/src/apex_watchdog.c` — exists but has fake hash (audit #2)
- **Fix**: Real SHA256 self-check, BT stuck detection, IIO pending request check, ath9k crash recovery
- Schedule via `delayed_work` every 5 minutes

### 5.3 PMIC WDT
- 60-second hardware watchdog via `/dev/watchdog`
- Pre-timeout handler writes minidump to `/persist/apex/incidents.log`
- Boot-time SHA256 self-check (fix audit #2)
- Auto safe-mode on recent panic (boot_count tracking)

### 5.4 7-Day Thermal Learner
- **New kernel module**: `patches/apex-thermal/src/apex_thermal_learn.c`
- Collects: CPU temp × clock × foreground UID, 7-day heatmap
- After 7 days, shifts 45/55/65°C trip points to match routine
- Safe defaults from day one
- `/proc/apex/thermal_profile` — read current learned profile
- `rom-overlays/thermald/thermald.conf` — thermald reads learned thresholds

### 5.5 Three Alarm Paths
1. `deskclock` + `poweroffalarm` pinned to `oom_score_adj = -1000` in `mm/oom_kill.c`
2. `apex-alarmkeeper` mirrors RTC_WAKEUP to `/proc/apex/wakealarm` (fix audit #7 — replace popen with Binder)
3. Kernel writes to `/sys/class/rtc/rtc0/wakealarm` — PMIC fires even if SoC off

### 5.6 Apex Control Incident Log Viewer
- New screen in Apex Control app: reads `/persist/apex/incidents.log`
- Shows crash history, watchdog events, safe-mode triggers
- Part of audit #15 fix

---

## Phase 6: Agent Enhancements

**Goal**: Complete all deferred agent capabilities.
**Success criterion**: Remote model works with consent, E3 charge control with dual-confirmation, agent memory vector store operational.

### 6.1 Remote Model (OmniRoute-compatible)

**Requirements**:
1. HTTP client in apexagentd — use `java.net.HttpURLConnection` (no external deps in system app)
2. Per-request consent: new `ConsentGate.ConsentType.REMOTE_INFERENCE` — warns "data leaves device", requires explicit approval, 60s timeout → auto-deny
3. OmniRoute endpoint: configurable via `persist.sys.apex.remote_endpoint` system property
4. Fallback: on network failure/timeout, fall back to local model tier

**SELinux change**: Current `apex_agent.te` has `neverallow tcp/udp sockets`. Need:
```
# Allow REMOTE tier network access only when apex.remote_enabled property is set
allow apex_agent port_type:tcp_socket name_connect;
# Or: create separate domain apex_agent_remote for remote inference process
```
**Safer approach**: Spawn a separate `apex_remote_proxy` process in its own SELinux domain that handles HTTP. apexagentd talks to it via local socket. The proxy has network access, apexagentd does not.

**Files to create/modify**:
- `agent/java/com/apex/agent/RemoteModelClient.java` — HTTP client
- `agent/java/com/apex/agent/RemoteProxyDaemon.java` — separate process
- `agent/sepolicy/apex_remote_proxy.te` — new domain with network access
- `rom-overlays/init.d/apex_remote_proxy.rc` — init service
- Modify `ModelManager.java` — add REMOTE tier dispatch
- Modify `ConsentGate.java` — add REMOTE_INFERENCE consent type

### 6.2 E3 Agent-Driven Charge Control

**Requirements**:
1. New MCP tool `apex-charge-write` — writes to `/sys/class/power_supply/battery/charge_control_limit_max`
2. Dual-confirmation consent: on-screen approve + physical button (volume key press within 5s)
3. Rate-limited: max 1 charge control change per 10 minutes
4. Audit logged with before/after values

**Files to create**:
- `agent/java/com/apex/agent/ChargeControlTool.java` — MCP tool implementation
- Modify `McpRegistry.java` — register charge-write tool
- Modify `ConsentGate.java` — add `DUAL_CONFIRM` consent type
- Modify `SecurityPolicy.java` — allow charge sysfs writes with dual-confirm
- Modify `agent/sepolicy/apex_agent.te` — allow write to `sysfs_power_supply`
- `apps/apex-control/` — new charge control UI screen

### 6.3 Persistent Agent Memory (Vector Store)

**Requirements**:
1. On-device vector store — SQLite + FTS5 for text search, simple cosine similarity
2. No external embedding model — use TF-IDF or BM25 for retrieval (CPU-only, no GPU)
3. Agent stores: user preferences, routines, battery habits, conversation summaries
4. Privacy-first: all data stays on device, encrypted with file-based encryption

**Files to create**:
- `agent/java/com/apex/agent/AgentVectorStore.java` — SQLite + BM25 vector store
- Modify `AgentMemoryStore.java` — integrate vector store for long-term memory
- Modify `ApexAgentDaemon.java` — inject relevant memories into prompt context
- `agent/java/com/apex/agent/MemoryManager.java` — memory CRUD + retrieval
- Tests: `tests/agent/test_vector_store.py`

### 6.4 Voice Input (whisper.cpp)

**Status**: JNI bridge exists (`agent/voice/libwhisper_jni/whisper_jni.c`), build script exists (`agent/llm/build-whisper.sh`)

**Remaining**:
1. Cross-compile whisper.cpp for arm64 (run `build-whisper.sh`)
2. Download small model (whisper-tiny.en or whisper-base.en GGUF)
3. Integrate `VoiceManager.java` with audio recording from microphone
4. Wake-word detection: simple energy-based or keyword-spotting model
5. Apex Control: push-to-talk button in AgentChatSurface

---

## Phase 7: APEX WM — Freeform Window Manager (P3)

**Goal**: VXWM-style freeform window manager for Android on phone form factor.
**Success criterion**: Freeform windows work on phone display, agent can launch/manage windows via MCP tools.

### 7.1 Research (Android Freeform Window APIs)

Android supports freeform windows natively via:
- `ActivityOptions.setLaunchWindowingMode(WINDOWING_MODE_FREEFORM)`
- `TaskOrganizer` + `TaskDisplayArea` for window management
- `SurfaceControl.Transaction` for window positioning
- Requires `config_freeformWindowManagement=true` in framework overlay
- Hidden API access may be needed (some APIs are `@SystemApi` or hidden)

**Approach**: No SurfaceFlinger changes. Use framework-level freeform window APIs:
1. Enable freeform mode via framework overlay (`config_freeformWindowManagement=true`)
2. Create `ApexWindowManager` system service that manages freeform windows
3. Tiling mode: optional, built on top of freeform windows

### 7.2 Implementation

**Files to create**:
- `wm/java/com/apex/wm/ApexWindowManager.java` — window management service
- `wm/java/com/apex/wm/WindowLayoutStrategy.java` — layout algorithms (freeform, tiling, split)
- `wm/java/com/apex/wm/WindowContainer.java` — window container abstraction
- `wm/aidl/com/apex/wm/IApexWindowManager.aidl` — Binder interface
- `wm/aidl/com/apex/wm/IApexWindowListener.aidl` — window event callbacks
- `wm/sepolicy/apex_wm.te` — SELinux policy
- `wm/Android.bp` — build config
- `rom-overlays/init.d/apex_wm.rc` — init service
- `rom-overlays/frameworks/apex_wm_overlay.xml` — framework config overlay

**MCP tools exposed to agent**:
- `apex-wm.list-windows` — list all freeform windows
- `apex-wm.open-app` — launch app in freeform window
- `apex-wm.move-window` — move window to position
- `apex-wm.resize-window` — resize window
- `apex-wm.close-window` — close window
- `apex-wm.set-layout` — set layout mode (freeform/tiling/split)

### 7.3 Apex Control Integration
- New "Windows" screen in Apex Control
- Visual window manager: see all windows, drag to reposition, pinch to resize
- Layout mode selector

---

## Phase 8: Desktop Mode (P3, depends on WM)

**Goal**: Desktop experience via scrcpy over USB or TCP.
**Success criterion**: Phone connected to PC → desktop mode launches → freeform windows appear on PC screen.

### 8.1 scrcpy Integration

**scrcpy v4.1** (https://github.com/Genymobile/scrcpy):
- USB/TCP mirroring, no root required for basic mirroring
- Virtual display support (`--new-display=1920x1080`)
- Audio forwarding (API >= 30)
- HID keyboard/mouse/gamepad
- 30-120fps, 35-70ms latency
- Xiaomi caveat: enable "USB debugging (Security Settings)" for input injection

**Approach**:
1. Pre-install scrcpy server in ROM (`/system/bin/scrcpy-server.jar`)
2. Desktop Mode MCP tool: `apex-desktop.start` — launches scrcpy server + freeform windows on virtual display
3. Apex Control: "Desktop Mode" button — starts scrcpy, switches WM to desktop layout
4. Auto-detect USB connection to PC → offer desktop mode notification

### 8.2 Implementation

**Files to create**:
- `desktop/java/com/apex/desktop/DesktopModeService.java` — manages scrcpy + WM desktop layout
- `desktop/aidl/com/apex/desktop/IDesktopMode.aidl` — Binder interface
- `desktop/sepolicy/apex_desktop.te` — SELinux policy (needs network for TCP scrcpy)
- `desktop/scrcpy-server/` — pre-built scrcpy server jar
- `rom-overlays/init.d/apex_desktop.rc` — init service
- `tools/build-scrcpy-server.sh` — build scrcpy server from source

**MCP tools**:
- `apex-desktop.start` — start desktop mode (scrcpy + WM desktop layout)
- `apex-desktop.stop` — stop desktop mode
- `apex-desktop.status` — check if running, connection info

### 8.3 Desktop Layout
- WM switches to "desktop" layout: windows with title bars, draggable, resizable
- Taskbar at bottom: running apps, home button, back button
- Keyboard/mouse input via scrcpy HID
- Multi-monitor: phone display + virtual display for scrcpy

---

## Phase 9: Lindroid — Full Linux Desktop (P4, depends on WM + Desktop)

**Goal**: Replace chroot+bridge with a proper Linux desktop environment running alongside Android.
**Success criterion**: Full Linux desktop (Arch Linux ARM) running concurrently with Android, shared display, agent can launch Linux apps.

### 9.1 Architecture

**Upgrade path from chroot**:
1. Current: Arch Linux ARM chroot + apex-bridge (socket-based, separate)
2. Lindroid: Arch Linux ARM as a proper container with shared display

**Approach**: Container-based, not VM (no KVM on SM6225):
- Use Linux namespaces (pid, net, mount, user) — like Waydroid but opposite direction
- Android is host, Arch Linux ARM is container
- Shared display via Wayland proxy or X11 forwarding to Termux:X11
- Shared filesystem: `/data/adb/apex/arch` mounted in both Android and container
- Network: `veth` pair, container gets its own IP

### 9.2 Implementation

**Files to create**:
- `lindroid/java/com/apex/lindroid/LindroidManager.java` — container lifecycle
- `lindroid/java/com/apex/lindroid/ContainerConfig.java` — namespace setup
- `lindroid/java/com/apex/lindroid/DisplayBridge.java` — display forwarding
- `lindroid/aidl/com/apex/lindroid/ILindroid.aidl` — Binder interface
- `lindroid/sepolicy/apex_lindroid.te` — SELinux policy for container
- `lindroid/scripts/lindroid-init.sh` — container init script
- `lindroid/scripts/lindroid-start.sh` — start container with namespace isolation
- `lindroid/scripts/lindroid-stop.sh` — stop container
- `rom-overlays/init.d/apex_lindroid.rc` — init service
- `tools/build-lindroid.sh` — build Lindroid container image

**MCP tools**:
- `apex-lindroid.start` — start Linux container
- `apex-lindroid.stop` — stop container
- `apex-lindroid.exec` — execute command in container
- `apex-lindroid.install` — install package in container
- `apex-lindroid.launch-app` — launch Linux GUI app (via display bridge)

### 9.3 Display Bridge
- Wayland proxy: Android SurfaceFlinger → Wayland → Linux apps
- Or: X11 forwarding to Termux:X11 server (existing approach, proven)
- Window integration: Linux app windows appear as freeform windows in APEX WM

### 9.4 Migration from chroot
- `lindroid/scripts/lindroid-migrate.sh` — migrates existing chroot to container
- Preserves installed packages, home directory, configs
- apex-bridge deprecated, replaced by LindroidManager Binder interface

---

## Phase 10: Daily-Driver Polish

**Goal**: Implement all 17+ daily-driver pain-point fixes from DESIGN.md §11.
**Success criterion**: Each pain point verified on-device, no regressions.

### 10.1 Kernel Config Verification
All fixes are defconfig entries — verify they compile and take effect:

| Pain Point | Config | Verification |
|------------|--------|-------------|
| Stuttery scrolling | PSI + ENERGY_MODEL + PREEMPT_DYNAMIC + apex governor | `cat /proc/pressure/cpu` shows pressure data |
| Broken battery stats | `CONFIG_BATTERY_STATS=y` | `dumpsys battery` shows correct stats |
| SMS/MMS delay | `CONFIG_QMI_RMNET_QMUX=y` + `CONFIG_RMNET=m` | SMS sends < 3s |
| Dropped calls | `CONFIG_QCOM_RX_WAKELOCK_GUARD=y` | No dropped calls in 24h test |
| Fast-charge reboot | `CONFIG_USB_PD_PE_FW_DELAY=15ms` | No reboot during fast charge |
| BT audio dropout | `CONFIG_BT_MSFTEXT=y` + `CONFIG_SND_A2DP_LDAC=m` | No BT audio drops in 1h test |
| Wi-Fi calling drop | `CONFIG_QCOM_QMI_WDAUTH=m` + MOBIKE keepalive | No Wi-Fi calling drops |

### 10.2 ROM Overlay Verification
| Pain Point | Overlay | Verification |
|------------|---------|-------------|
| Battery drain — BT scan | `apex_power.rc` cgroup freezer | BT scan stops after 30s idle |
| Battery drain — sensors | `apex_power.rc` sensor cap | Background sensor rate ≤ 10Hz |
| Battery drain — Wi-Fi multicast | `apex_power.rc` watchdog params | No multicast when screen off |
| Auto-brightness flicker | sensor cap min 50Hz | No flicker in auto-brightness |
| Random shutdown | `thermald.conf` fixed | No random shutdowns in 48h |

### 10.3 Apex Control App Completion (audit #15)
- Governor tuning screen: pick governor, set min/max freq per cluster
- Thermal profile display: show current thresholds, learned profile
- Incident log viewer: read `/persist/apex/incidents.log`
- Module status: show loaded pentest drivers
- Bridge status: show chroot/container status

---

## Phase 11: Build Pipeline + CI

**Goal**: Automated build pipeline for kernel + ROM + pentest modules.
**Success criterion**: Single command produces all flashable artifacts.

### 11.1 Build Tools
- `tools/build-kernel.sh` — already exists, verify against real tree
- `tools/build-rom.sh` — already exists, fix preflight (LOS source check)
- `tools/build-pentest-drivers.sh` — new, builds out-of-tree Wi-Fi drivers
- `tools/build-scrcpy-server.sh` — new, builds scrcpy server
- `tools/build-lindroid.sh` — new, builds Lindroid container image
- `tools/package-rom.sh` — new, assembles final flashable zip with all components

### 11.2 Release Artifacts
1. `apex-kernel-1.2.0-topaz-anykernel3.zip` — kernel only (flashable via recovery)
2. `apex-rom-1.0.0-topaz.zip` — full ROM (flashable via recovery, dirty-flash)
3. `apex-pentest-modules-1.0.0.zip` — pentest driver modules (flashable via KSU)
4. `apex-hiding-stack-1.0.0.zip` — Shamiko + HMA + TrickyStore + Yurikey (KSU modules)
5. `apex-agent-models-1.0.0.zip` — pre-built GGUF models (qwen2.5-1.5b, qwen2.5-3b, whisper-tiny.en)

### 11.3 CI Pipeline
- `.github/workflows/ci.yml` — already exists, extend with:
  - Kernel build against bengal-5.15 tree
  - ROM build (if LOS source available)
  - Brick-safety verification on all artifacts
  - Test suite (276+ tests)
  - verify.sh 31/31

---

## Execution Order

Phases are ordered by dependency and risk:

```
Phase 1 (Kernel Audit)     ──────────────────────┐
                                                  ▼
Phase 2 (LOS Sync + ROM)   ──────────────────────►│
                                                  │
Phase 3 (Hiding Stack)     ──────────────────────►│
                                                  │
Phase 4 (Pentest Drivers)  ──────────────────────►│── Phase 11 (Build Pipeline)
                                                  │
Phase 5 (Zero-Maintenance) ──────────────────────►│
                                                  │
Phase 6 (Agent Enhancements) ────────────────────►│
                                                  │
Phase 7 (APEX WM)          ──────────────────────►│
        ▼                                         │
Phase 8 (Desktop Mode)     ──────────────────────►│
        ▼                                         │
Phase 9 (Lindroid)         ──────────────────────►│
                                                  │
Phase 10 (Daily-Driver)    ──────────────────────►│
```

**Critical path**: Phase 1 → Phase 2 → Phase 3 (kernel fixes → ROM build → hiding stack)
**Parallel tracks**: Phases 4, 5, 6 can run in parallel after Phase 1
**Sequential chain**: 7 → 8 → 9 (WM → Desktop → Lindroid)

---

## Risk Register (Updated)

| Risk | Severity | Mitigation |
|------|----------|------------|
| LOS source tree sync fails (network/disk) | HIGH | Pre-download device repos, use shallow sync |
| Kernel compile fails against real tree | MEDIUM | Fix audit #9 (apex-lmk) first — known compile bug |
| APEX governor WALT API mismatch | MEDIUM | Check bengal-5.15 tree for exact `walt_util_cpu` signature before implementing |
| SELinux policy conflicts with LOS | MEDIUM | Build sepolicy merge test before full ROM build |
| scrcpy server incompatible with Android 16 | LOW | scrcpy v4.1 supports API 21+, Android 16 is API 36 |
| Freeform window APIs hidden/unavailable | MEDIUM | May need `@SystemApi` access via hidden API stubs or framework overlay |
| Lindroid container namespace issues | MEDIUM | Start with chroot upgrade, test namespace isolation incrementally |
| Remote model SELinux neverallow conflict | MEDIUM | Use separate proxy process domain (apex_remote_proxy) |
| ROM build takes 2+ hours | LOW | Expected for full AOSP build. Use ccache + incremental builds |
| Disk space for LOS tree (~100GB) | MEDIUM | Check available disk, use shallow sync if needed |

---

## Effort Estimates

| Phase | Effort | Notes |
|-------|--------|-------|
| 1 — Kernel Audit | 2-3 days | 15 fixes, most are small code changes |
| 2 — LOS Sync + ROM | 1-2 days | Sync is I/O bound, build is CPU bound (2-4h) |
| 3 — Hiding Stack | 1 day | Package existing modules, configure denylists |
| 4 — Pentest Drivers | 2-3 days | Build out-of-tree drivers, NFCForge app, PTK TUI |
| 5 — Zero-Maintenance | 2-3 days | Thermal learner, watchdog fixes, alarm paths |
| 6 — Agent Enhancements | 3-4 days | Remote model, E3 charge, vector store, voice |
| 7 — APEX WM | 3-5 days | Framework research, window manager service, UI |
| 8 — Desktop Mode | 2-3 days | scrcpy integration, desktop layout |
| 9 — Lindroid | 3-5 days | Container setup, display bridge, migration |
| 10 — Daily-Driver | 1-2 days | Mostly verification + config tweaks |
| 11 — Build Pipeline | 1-2 days | Script assembly, CI extension |
| **Total** | **20-33 days** | Sequential with parallel tracks |

---

## Next Actions (Immediate)

1. **Fix audit #9** (apex-lmk compile bug) — blocks kernel build
2. **Fix audit #1** (WALT load placeholder) — highest impact kernel fix
3. **Fix audit #3** (dead decision outputs) — clean up dead code
4. **Fix audit #2** (watchdog hash) — security feature
5. **Sync LOS source tree** — longest I/O operation, start early
6. **Verify kernel compiles** against real bengal-5.15 tree
