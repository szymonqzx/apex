# Detection → Countermeasure Matrix (Native Detector, 2026-09-07)

Every detection from the user's Native Detector report, its countermeasure(s),
implementation status, and where it is configured. Status legend:

- **IMPLEMENTED** — code/config landed in the APEX repo this session
  (kernel patch, lineage-hider, configure scripts).
- **DEVICE-STEP** — applies via module install / config run / settings on the
  device (zips + scripts are in the flash set).
- **ROM-SIDE** — requires the LineageOS source tree (de-lineage / rename).
- **RESIDUAL** — not closable at runtime (documented, with the planned path).

| # | Detection | Vector | Countermeasure(s) | Status |
|---|-----------|--------|-------------------|--------|
| 1 | **Abnormal Environment `214.100000`** | Mount-table/namespace inconsistency + hook artifacts (measured value, %f float) | Mount hygiene: susfs4ksu Auto Hide mounts, Auto Try Umount (userspace), Try Umount Zygote Isolation, per-app "Umount modules" in KSU manager. Hook latency: ReSukiSU manual hooks (no kprobes). Discriminator: run ND on topaz control device (APatch kprobes). | IMPLEMENTED (config) + DEVICE-STEP |
| 2 | **Bootloader Unlocked** (`ro.boot.verifiedbootstate: orange`) | `/proc/cmdline` + `ro.boot.*` property | SPOOF_CMDLINE kernel port → `green` to apps; susfs4ksu service.sh resetprop → `green`; lineage-hider SystemProperties hook (Java) | IMPLEMENTED (all three layers) |
| 3 | **Bootloader Unlocked** (`Device locked: false`, `KM_VERIFIED_BOOT_UNVERIFIED`) | TEE key attestation | TrickyStore(OSS) keybox → locked/green attestation; BootloaderSpoofer (takattowo) for local-only checks | DEVICE-STEP (keybox via Yurikey); RESIDUAL: server-side validation |
| 4 | **Abnormal Boot State** (empty `ro.boot.vbmeta.*` + boot hash) | Empty vbmeta properties; TEE boot hash | VerifiedBootHash → `ro.boot.vbmeta.digest` = **real** hash `102ae65d…` (consistency with attestation); resetprop device_state=locked, hash_alg, size; lineage-hider Java prop spoofs | IMPLEMENTED (config) + DEVICE-STEP |
| 5 | **Abnormal PackageManager** (no detail) | PM-level anomaly; suspect: signature-spoofing code path / lineage-signed system packages | HMA hides lineage packages; **lineage-hider in-process PackageManager filtering** (getInstalledPackages/getInstalledApplications/getPackageInfo); don't run microG-signed GMS (avoids the gated signature-spoof path); re-test per layer | IMPLEMENTED (lineage-hider) + DEVICE-STEP (HMA); empirical |
| 6 | **LineageOS (6)** — smaps contains `lineage` | `/proc/*/maps`/`smaps` paths | `hide_cusrom` (find→sus_path, kernel uid≥2000) + explicit sus_path for platform-res.apk + vdex | IMPLEMENTED (config) + DEVICE-STEP |
| 7 | **LineageOS (8)** — platform-res.apk exists | Direct file stat/open | sus_path → ENOENT for apps; OPEN_REDIRECT (deferred port) as second layer | IMPLEMENTED (config); OPEN_REDIRECT documented follow-up |
| 8 | **LineageOS (10)/(11)/(12)** — binder services listed | servicemanager enumeration: Java `ServiceManager`, native libbinder, `service list` exec | **Java**: lineage-hider listServices/getService/checkService/waitForService/getDeclaredInstances filters. **Native**: see `docs/NATIVE_BINDER_HIDING.md` — rename-at-build (recommended, kills Java+native+exec vectors) or Zygisk Dobby module | IMPLEMENTED (Java) + ROM-SIDE (rename) / planned (native module) |
| 9 | **LineageOS (14)** — package list + `AssetManager.LINEAGE_APK_PATH` | PackageManager queries; reflected static field | HMA + lineage-hider PackageManager filtering; LINEAGE_APK_PATH in-place String wipe (handles constant-folding); de-lineage build as endgame | IMPLEMENTED (lineage-hider) + DEVICE-STEP (HMA) + ROM-SIDE (endgame) |
| 10 | **Custom ROM (1)** — addon.d / install-recovery.sh + `init.svc.adb_root` | File existence; running adb-root service | sus_path: `/system/addon.d`, install-recovery.sh paths; **disable LineageOS root access** in developer settings (kills the service → prop absent; KSU provides root) | IMPLEMENTED (config) + DEVICE-STEP (settings) |
| 11 | **Custom ROM (2)** — vdex + 'lineage' strings in sepolicy/vintf | File paths; file *content* strings | sus_path for vdex; susfs4ksu Hide Vendor SEPolicy + Hide Compat Matrix (grep-strip + bind + sus_mount + sus_kstat); **manual**: system_ext_sepolicy.cil + vendor_file_contexts (same technique, scripted in configure_susfs.sh notes) | IMPLEMENTED (config) + DEVICE-STEP (manual sepolicy extras) |
| 12 | **Custom ROM (3)** — platform-res.apk mmap in smaps | `/proc/*/smaps` mapping entries | Same sus_path/hide_cusrom layer as (6) — SUS_MAPS/SUS_PATH filter show_map_vma for uid≥2000 | IMPLEMENTED (config) + DEVICE-STEP |
| 13 | **Boot hash `102ae65d…`** (in Abnormal Boot State) | TEE attestation boot hash (immutable) | Cannot change the TEE value; ensure *consistency*: `ro.boot.vbmeta.digest` property = same hash (VerifiedBootHash) so cross-checks pass | IMPLEMENTED (config) + DEVICE-STEP |
| 14 | **Signing keys** (new vector from strategy review) | System packages signed with known LineageOS release keys | HMA/lineage-hider hiding (runtime); own key set at rebrand time (endgame) | DEVICE-STEP + ROM-SIDE |
| 15 | **`ro.build.fingerprint` / build identity** (implicit) | Build props showing lineage/userdebug | PIF overlay in ksu-module (MIUI `V816.0.7.0.UMGMIXM`); resetprop at boot; **user build** (not userdebug) for cleanest narrative | IMPLEMENTED (overlay) + ROM-SIDE (user build) |

## Coverage summary

- Fully closed at runtime: #1 (config), #2, #4, #5 (Java), #6, #7, #9 (Java),
  #10 (with settings), #11 (module config), #12, #13, #15 (overlay).
- Closed with device steps only: #3 (keybox), #14 (HMA scope).
- Single documented residual: **#8 native binder enumeration** — Java path
  closed; native path spec at `docs/NATIVE_BINDER_HIDING.md` (rename-at-build
  recommended; Zygisk Dobby module as the runtime alternative).
- #5 remains partially empirical: the check gives no detail; if it persists
  after HMA + lineage-hider, the remaining suspect is the signature-spoofing
  code path (avoid microG-signed GMS) or a native PM check (rebranding closes).

## Verification protocol

Pin the ND version. Baseline → layer by layer (susfs config → hide_cusrom/
sepolicy/cmdline → HMA + lineage-hider → attestation) → record which rows
clear. Run the same ND version on topaz (AOSP 16 + APatch) as the control
for row #1. Re-verify on every ND release.
