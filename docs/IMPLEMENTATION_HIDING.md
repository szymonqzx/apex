# Implementation — ROM + Root Hiding (2026-09-07)

Runbook for the hiding stack implemented against the detections reported by
Native Detector (Reveny, v7.x) on LineageOS 23.2 + Zepharo R9 (tapas).

## What was implemented

| # | Artifact | What it does | Verified |
|---|----------|--------------|----------|
| 1 | SUSFS **SPOOF_CMDLINE** port (`patches/apex-new/apex-root/`) | `/proc/cmdline` reports `androidboot.verifiedbootstate=green` to apps (uid ≥ 2000) | `patch -p1 --dry-run` passes on the 5.15 tree |
| 2 | `defconfig/apex_defconfig` | `CONFIG_KSU_SUSFS_SPOOF_CMDLINE=y` | — |
| 3 | `hiding/configure_susfs.sh` | Generates `/data/adb/susfs4ksu/{config.sh,sus_path.txt,kernelversion.txt}` + `/data/adb/VerifiedBootHash/VerifiedBootHash.txt` | — |
| 4 | `apps/lineage-hider/` (+ `hiding/prebuilt/lineage_hider.apk`) | LSPosed (libxposed 100+, registered via `META-INF/xposed/{module.prop,java_init.list}` per the libxposed API): ServiceManager filter, `AssetManager.LINEAGE_APK_PATH` wipe, SystemProperties boot-prop spoof | `./gradlew :app:assembleDebug` green; APK contains `META-INF/xposed/*` |
| 5 | `hiding/install_modules.sh`, `hiding/configure_hiding.sh`, `hiding/denylist.conf` | Stack reworked: Shamiko/ReZygisk removed (ND v7.7 detects them); susfs4ksu + TrickyStoreOSS + LSPosed-Next in | — |

## Detection → fix map (what each implemented piece closes)

| Detection | Closed by |
|-----------|-----------|
| Bootloader Unlocked (`ro.boot.verifiedbootstate: orange`) | SPOOF_CMDLINE (kernel, /proc/cmdline) + susfs4ksu service.sh resetprop (property) + lineage-hider (Java SystemProperties) + TrickyStore/BootloaderSpoofer (attestation) |
| Abnormal Boot State (empty vbmeta props) | VerifiedBootHash (ro.boot.vbmeta.digest = real TEE hash) + susfs4ksu resetprop (device_state/avb fields) |
| LineageOS (6)/(8)/(14), Custom ROM (3) — platform-res.apk family | susfs4ksu `hide_cusrom` + explicit sus_path entries + HMA (packages) + lineage-hider (LINEAGE_APK_PATH field) |
| LineageOS (10)/(11)/(12) — binder services | lineage-hider (ServiceManager Java path); native listing → residual (ROM-level only) |
| Custom ROM (1) — addon.d / install-recovery.sh / adb_root | sus_path entries; disable LineageOS root in developer settings (kills `init.svc.adb_root`) |
| Custom ROM (2) — sepolicy/vintf 'lineage' strings | susfs4ksu Hide Vendor SEPolicy + Hide Compat Matrix (+ manual system_ext_sepolicy.cil/vendor_file_contexts treatment) |
| Abnormal Environment 214.x | Mount hygiene (susfs4ksu auto-hide + per-app Umount modules); if hook-latency based → manual hooks (ReSukiSU) |
| Abnormal PackageManager | HMA package hiding; verify signature-spoofing not triggered (LineageOS gates it to microG-signed GMS) |

## Device apply steps

1. **Kernel**: rebuild APEX with the SPOOF_CMDLINE port (or use R9 which already
   has SUSFS 2.2.0 — the module's `set_proc_cmdline` works on both).
2. **Modules** (place zips in `/system/apex/modules/`): `zygisk_next`,
   `lsposed_next` (F1xGOD — NOT JingMatrix), `hma_oss`, `susfs4ksu`,
   `tricky_store_oss`, `yurikey`. Run `hiding/install_modules.sh`.
3. **lineage-hider**: `adb install hiding/prebuilt/lineage_hider.apk`; enable +
   scope in LSPosed manager to the target app(s) ONLY.
4. **Config**: push `hiding/configure_susfs.sh` + `hiding/denylist.conf` to
   `/data/adb/apex/`, run `sh /data/adb/apex/configure_susfs.sh` (edit BOOT_HASH
   first if your device's boot hash differs), then `configure_hiding.sh`
   (writes the susfs config, seeds HMA's hide.list from the `[hidden-apps]`
   section of denylist.conf, verifies the keybox).
5. **Settings**: LineageOS → Developer options → Root access → **Disabled**
   (KSU provides root; this kills `init.svc.adb_root`).
6. **KSU manager**: for every package in the `[denylist]` section of
   denylist.conf enable per-app "Umount modules"; use "hide manager" so the
   manager's /data/app dir gets a random name.
7. **Reboot**, then verify.

## Verification protocol

- Pin the Native Detector version during testing (Reveny ships updates fast;
  results only compare within one version).
- Record a baseline BEFORE any hiding, then re-run after each layer:
  1. baseline (raw) → 2. susfs config + umount → 3. susfs4ksu full (hide_cusrom,
     sepolicy, cmdline) → 4. HMA + lineage-hider → 5. attestation (TrickyStore
     keybox, BootloaderSpoofer).
- **Comparative device**: topaz (AOSP 16 + Ecstasy kernel + APatch) runs the
  same NT version as a control. If "Abnormal Environment" reproduces there, it
  is hook-latency (kprobes) → manual hooks required; if only on tapas, it is
  mount/namespace leakage → susfs hygiene.
- Cross-check Play Integrity (Integrity Checker) after each layer — hooking
  Google apps or system framework breaks PI; scope discipline is load-bearing.

## Known residuals (not closable at runtime)

- **Native binder service enumeration** (`servicemanager` listing via libbinder
  inside the target): no kernel/userspace hook in the current stack. Fix =
  ROM-level rename/removal of lineage services (de-lineage build).
- **Server-side attestation validation**: BootloaderSpoofer only affects local
  checks; STRONG integrity requires an unrevoked hardware keybox
  (TrickyStore + keybox.xml).
- **LSPosed self-traces in hooked processes** (`[anon:dalvik-main space]`
  leak): only avoidable by not hooking the target — the trade-off behind
  end-state (B) in `guides/apex-native-detector-hiding-plan` (GBrain).
- **`LINEAGE_APK_PATH` constant-folding**: the wipe patches the String backing
  array, which works while the field is a folded constant; a ROM build that
  de-constantizes the field (`Build.VERSION... ? literal : null`) makes the
  wipe permanent instead of per-process.

## Kernel port notes (SPOOF_CMDLINE)

- New prctl command `CMD_SUSFS_SET_CMDLINE (0x55563)`; userspace
  `ksu_susfs set_proc_cmdline <file>` (module's boot-completed.sh already calls
  it when `spoof_cmdline=1`).
- Hook lives in `fs/proc/cmdline.c` `cmdline_proc_show` (uid ≥ 2000 readers see
  the spoofed string; root/system see the real one).
- While porting, fixed a latent bug in `fsmods.patch`: the Makefile hunk
  declared `@@ -1299,7 +1299,7 @@` but contained 6 lines — tolerated at EOF by
  GNU patch, but it broke once content followed. Now `7/7` with the trailing
  blank context line, and the whole patch dry-runs clean.
