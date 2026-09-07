# APEX Kernel/ROM Development Tooling — Landscape & Integration

Surveyed 2026-09-07. Purpose: map the ecosystem, record what APEX already
uses, and pick what to adopt next. Companion to `tools/device/` (our own
resilient flash/debug toolset) and `docs/FLASH_SESSION_2026-09-07.md`.

## In use by APEX already

| Tool | Repo | Role in APEX |
|---|---|---|
| AnyKernel3 | osm0sis/AnyKernel3 | Flashable-kernel packaging (`anykernel3/`); magiskboot-based unpack/repack, Magisk retention, `flash_boot` for init_boot devices |
| magiskboot | topjohnwu/Magisk (APK asset) | Boot-image surgery; we extract `lib/x86_64/libmagiskboot.so` for laptop-side work |
| KernelSU-Next | KernelSU-Next/KernelSU-Next (v3.3.0, rifsxd) | Built-in root in the APEX kernel (CONFIG_KSU); recent versions patch boot images natively (built-in bootimg crate, magiskboot dropped) |
| SUSFS | simonpunk/susfs4ksu (gitlab) | Root hiding in the APEX kernel (CONFIG_KSU_SUSFS) |
| Baseband-guard | vc-teahouse/Baseband-guard | Anti-brick LSM (CONFIG_BBG), vendored into the kernel |
| KernelPatch / APatch | bmax121/KernelPatch, bmax121/APatch | The device's CURRENT root (APatch); kptools/kpimg for KP patching |

## Verified ecosystem (2026-09-07)

### Flashing / boot images / AVB

| Tool | Repo | What it does | APEX relevance |
|---|---|---|---|
| avbroot | chenxiaolong/avbroot (v3.30.x, Rust) | Repro A/B OTA re-signing + boot/vbmeta/image pack-unpack subcommands | AVB-clean images via `fastboot flash avb_custom_key`; image tools beyond magiskboot |
| Android_boot_image_editor | cfig/Android_boot_image_editor (gradle) | unpack/repack boot, vendor_boot, vbmeta, dtbo, payload; **co-updates vbmeta hash when boot changes** | The vbmeta+boot co-update is exactly what a locked/AVB device needs |
| mkbootimg / unpack_bootimg / repack_bootimg | AOSP platform/system/tools/mkbootimg | Official boot/vendor_boot image tools, Android 16 | Reference implementation; `--format=mkbootimg` round-trip |
| payload-dumper-go | ssut/payload-dumper-go (v2.0.2) | OTA payload extraction, incremental support, machine-readable output | Future ROM OTA work |
| device-flasher | AOSPAlliance/device-flasher (Google lineage) | Cross-platform factory image flasher | Reference for flash orchestration |
| universal-flasher | PHATWalrus/universal-flasher | QC/MTK ROM flasher; A/B slot mgmt, AVB control, partition resize | Ideas: safety checks, slot handling (parallels our flash-boot.sh) |
| PixelFlasher | badabing2005/PixelFlasher | Flash GUI over adb/fastboot (works on non-Pixel) | Manual-intervention fallback |
| DroidFlasher | ZorgeR/DroidFlasher | adb/fastboot/TWRP tool + DFS scripting | Scripting ideas |
| android-unpackbootimg | anestisb/android-unpackbootimg | Standalone unpackbootimg/mkbootimg | Legacy, superseded by magiskboot/AOSP |

### Root / hiding

| Tool | Repo | What it does | APEX relevance |
|---|---|---|---|
| KernelSU-Next manager + kernel_patches | KernelSU-Next/KernelSU-Next, KernelSU-Next/kernel_patches | Manager APK + patch files | The manager app for the post-flash root migration |
| susfs4ksu-module (universal binary) | sidex15/susfs4ksu-module (v1.5.2+ R27) | ksu_susfs userspace tool + KSU module for SUSFS | The userspace half of the hiding stack for the APEX ksu-module |
| KPatch-Next / KPM | KernelSU-Next/KPatch-Next | Kernel Patch Module support for KSU | Optional KPM route |
| avbroot | (see above) | Also patches Magisk/KernelSU boot images into signed OTAs | Root-preserving OTA path |

### Recovery

| Tool | Repo | What it does | APEX relevance |
|---|---|---|---|
| OrangeFox (official) | orangefox.download/device/topaz | Official recovery for topaz/tapas | The recovery flashing path once bootloader unlocked |
| Recovery device trees | chickendrop89/device_xiaomi_sm6225ad-recovery (fox-12.1/twrp-12.1/pbrp-12.1, maintained), TeamWin/android_device_xiaomi_tapas | OFRP/TWRP/PBRP trees for topaz | Building our own recovery if needed |

### CI / build automation

| Tool | Repo | What it does | APEX relevance |
|---|---|---|---|
| GKI_KernelSU_SUSFS | WildKernels/ + NerestKernels/ | Full GKI CI: repo sync, KSUN/SUSFS/BBG integration, **feature-set matrix** (KSUN / KSUN+SUSFS / +BBG / NONE / FULL), AnyKernel3 packaging | The feature matrix IS our bisection stages applied to CI — model for APEX CI |
| kernel_builder | axshhayy/kernel_builder | Matrix CI (vanilla/ksu/ksus), workflow_dispatch config, 20GB swap for LTO, clang r547379 | Model for APEX kernel CI matrix |
| android-gki-patched-kernel-builder | im-yuuki/ | GKI patched kernel builder workflow | Reference |

## Second survey (2026-09-07, verified via GitHub API)

Follow-up sweep for the completion push. All repos verified to exist on
2026-09-07 via `gh api`; stale = no commits in the last ~12 months.

### Device ROM reference trees — topaz/tapas (stale but reference-quality)

The only complete device+vendor+kernel sets for this exact device. All were
maintained until the ROM projects dropped the device (2024); use them as the
blob/config/bring-up reference for the real LOS build (Phase 2).

| Tree | Repo | Notes |
|---|---|---|
| crDroid device | crdroidandroid/android_device_xiaomi_topaz | Official crDroid 10/11 tree (Android 14/15 era), pushed 2024-12 |
| crDroid kernel | crdroidandroid/android_kernel_xiaomi_topaz | Device kernel for the crDroid tree, pushed 2024-11 |
| crDroid vendor | crdroidandroid/proprietary_vendor_xiaomi_topaz | Proprietary blobs (what our overlay design currently hand-writes) |
| SD685 org (full bring-up) | Xiaomi-SD685-Devs/{device_xiaomi_topaz, vendor_xiaomi_topaz, device_xiaomi_topaz-kernel, rom-build, vendor_lineage, hardware_qcom_*, vendor_qcom_opensource_*} | Complete org for the Redmi 12 4G family; pushed 2024 |
| tapas tree | AliHasan7671/android_device_xiaomi_tapas | tapas variant reference |
| tapas recovery | PitchBlackRecoveryProject/android_device_xiaomi_tapas-pbrp | PBRP recovery tree for tapas |

### SM6225 kernel references (SoC family)

| Repo | Notes |
|---|---|
| muralivijay/android_kernel_xiaomi_sm6225-5.15 | **5.15** bringup for the SM6225 family (spes), LA.VENDOR 13.2.1 tags; WIP, pushed 2025-10 — best diff reference for 5.15 porting |
| PixelExperience-Devices/{device,kernel}_xiaomi_sm6225-common | PE common trees |
| AOSPA/android_{device,kernel}_xiaomi_sm6225-common | Paranoid Android common trees |
| CHRISL7/kernel_xiaomi_sm6225 | stale (2024) |

### Kernel build CI / actions (active)

| Repo | What it is | APEX relevance |
|---|---|---|
| xiaoleGun/KernelSU_Action (719★, 2026-07) | The de-facto KSU/SUSFS kernel build GitHub Action (kernel + AnyKernel3 zip) | Reference for our matrix workflow; drop-in alternative to hand-rolled steps |
| dabao1955/kernel_build_action (180★) | Similar KSU build action | Reference |
| PhamtomK12/Android-Kernel-Builder (97★) | Android kernel builder action | Reference |
| hendrikmuhs/ccache-action (186★, active) | Standard ccache caching action for GitHub Actions | Our CI now caches ccache directly (ci.yml, ci-kernel-matrix.yml); switch to this action if the hand-rolled cache misbehaves |
| kernelci/kernelci-core + kernelci-pipeline (active) | KernelCI core + pipeline | Heavyweight; reference only — overkill for a single-device personal kernel |

### Debugging / verification (post-boot, once the kernel runs on hardware)

| Repo | What it is | APEX relevance |
|---|---|---|
| osandov/drgn (2086★, active) | Programmable Python debugger for the Linux kernel (live + vmcore) | pstore/vmcore analysis after device boots; pairs with tools/device/collect-boot-log.sh |
| google/syzkaller (6320★, active) | Coverage-guided kernel fuzzer | Aspirational; not practical on-device for this project |

### ROM / OTA tooling (Phase 2+)

| Repo | What it is | APEX relevance |
|---|---|---|
| lineageos4microg/docker-lineage-cicd (558★, active) | Containerized LineageOS CI/CD builds (docker run + build + OTA output) | The cleanest way to run the ~80GB LOS sync/build without polluting the dev disk; adopt for Phase 2 |
| LineageOS/android_packages_apps_Updater (76★, active) | Official LineageOS OTA updater app | OTA delivery once we have a ROM to update |
| Evolution-X/OTA (46★, active) | OTA server for EvoX-style builds (PHP, JSON feeds) | Simple OTA feed option alongside payload-dumper-go |

### Hiding stack — verified (matches what we already package)

| Repo | What it is | In our hiding stack? |
|---|---|---|
| Dr-TSNG/ZygiskNext (10.5k★, active) | Standalone Zygisk implementation | Yes (v1.5.0) |
| Dr-TSNG/Hide-My-Applist (5.5k★, active) | Xposed applist-detection interceptor | Yes (hma_oss) |
| 5ec1cff/TrickyStore (6.3k★, active) | Attestation keybox injection (TEE/KeyStore) | Yes (tricky_store_oss v3.1.0) |
| Yurii0307/yurikey (1.9k★) | Keybox installer app (one-time setup) | Yes (v3.0.6) |

### Dead references (do not use — verified 404 on 2026-09-07)

- chiteroman/PlayIntegrityFix — account gone (the PIF approach is superseded
  by TrickyStore + keybox anyway)
- dakkshesh07/kernel_build_action — account gone; use
  xiaoleGun/KernelSU_Action instead

### Adoption updates since the first survey

1. **CI caching — DONE.** ccache (auto-detected in `tools/build-kernel.sh`,
   `CCACHE_DIR` default `.ccache/`) + AOSP clang + ccache caching in both
   workflows.
2. **Kernel CI matrix** — keep ours (already mirrors the WildKernels stages);
   xiaoleGun/KernelSU_Action is the fallback if we want a maintained action.
3. **Phase 2 LOS build** — prefer docker-lineage-cicd over a manual sync;
   use the crDroid/Xiaomi-SD685-Devs trees as the blob/bring-up reference.
4. **drgn** — add to the device toolchain for pstore/vmcore analysis once the
   kernel boots.

## Kernel ecosystem on XDA — build recipe & device quirks (2026-09-07)

Deep research via the xda-scraper tool (threads, RSS, GitHub cross-checks);
full detail in GBrain `apex-xda-research-2026-09-07`.

### Who builds what for this device, and how

| Kernel | Base | Config | Toolchain | Modules | Status |
|---|---|---|---|---|---|
| **Ecstasy** (ROM default: LOS 23.2 + PixelOS 17) | ACK android13-5.15-lts fork (5.15.202) | GKI + `vendor/bengal_GKI.config` fragment | AOSP prebuilt | GKI dlkm partitions (system/vendor) | Boots, de-facto standard |
| **YASK / YASK-NEXT** (HyperOS 3 EU port) | ACK android13-5.15-lts OR CLO `kernel.lnx.5.15.r1-rel` | `gki_defconfig` | AOSP clang r547379 | none shipped | Boots (TNF builder, weekly CI) |
| **Helios** (new, Sep 2026, KSU-Next + SusFS) | ACK android13-5.15 | `helios_defconfig` (chickernel-derived) | AOSP clang r522817 | **CONFIG_MODULES off** | Seeking testers |
| **ChicKernel** (reference, thread closed) | ACK android13-5.15-lts fork | chickernel/ksun/ksun_susfs | latest clang, -O3+polly / thinLTO | — | GitHub active |
| **APEX** | TNF zepharo branch (CLO, 5.15.211) | `apex_defconfig` (custom) | distro clang → **AOSP r547379 (now auto)** | 491 .ko in zip (flag-gated) | **logo hang — bisecting** |

Key finding: every kernel that boots on this device uses the **AOSP GKI build
system + gki_defconfig (or GKI base + vendor fragment) + AOSP prebuilt clang**.
TNF's proven YASK releases do NOT build from the `zepharo` branch (experimental:
ACK+CLO merges + BBRv3/Schedhorizon/f2fs DIO; last commit 2026-08-08).

### Device P0 quirks (ChicKernel README, reused by Helios)

1. sm5602 fuel gauge + dwc3 USB break after **5.15.149** — root cause is the
   upstream `of: property` typo-fix (`io-channels` vs `io-channel`): the
   vendor DTB uses the singular form. **Already native in the Zepharo CLO
   base** (`io-channel` in `drivers/of/property.c`) — verified.
2. USB tethering panic — upstream dwc3 gadget soft-reset regression.
   **Already native in the Zepharo base** (`dwc3_gadget_soft_connect` has no
   soft reset; `dwc3_core_soft_reset` is static) — verified.
3. mi_thermald low-battery hotplug targets the E-cores → **ported as
   `apex-thermald-cores`** (redirects to P-cores, ChicKernel 3e85c42).
4. Vendor module kmsg spam → **ported as `apex-vendor-kmsg`**
   (CONFIG_SUPPRESS_VENDOR_MODULE_DEBUGGING, ChicKernel 06af5ac8).

### Module strategy

Proven kernels ship **no modules** (ROM provides vendor dlkm; GKI 2.0 keeps
vendor modules in system_dlkm/vendor_dlkm/vendor_ramdisk). APEX's 491-module
236MB zip is the outlier. `APEX_NO_MODULES=1` produces the lean ~45MB zip;
default unchanged until on-device module compatibility is proven. Module
signature policy already matches gki_defconfig (MODULES=y, SIG=y,
SIG_PROTECT=y); CONFIG_MODVERSIONS=y preserves the GKI KMI for vendor modules.

### DTB strategy (Ecstasy reference)

Ecstasy carries **device-dumped DTBs** (6 Khaje/SM6225 dtbdump variants) and
patches them with `fixup-dtbs.sh`: adds `qcom,force-warm-reboot` and
relocates ramoops 5D000000 → 9ff00000. When repacking a boot image, keep the
device's own DTB (flash-boot.sh path does this by construction); the failed
APEX boots had empty pstore at 5D000000 — verify ramoops placement in the
DTB of every flash image.

## Gap analysis — what our toolset adds

Nothing in the ecosystem provides the **flash → boot-verify → rollback loop**
for A/B devices with a flaky link, or kernel **feature bisection against a
physical device**. `tools/device/` fills that:

- retry/stuck-transfer-kill wrappers (adb-retry, fastboot-retry)
- safety-first slot flashing with post-write hash verify (flash-boot, slot)
- boot verification with machine-readable results (boot-test)
- feature bisection driver (bisect-kernel + stages-apex.txt)
- boot-log/pstore collection and config comparison (collect-boot-log,
  config-compare)
- one-shot state snapshot (device-state)

## Adoption roadmap (priority order)

1. **Recovery for the device** — OrangeFox official for topaz (gives a
   recovery-based flash path + backups; complements fastboot).
2. **Kernel CI feature matrix** — add a WildKernels-style matrix workflow
   (plain / ksu / susfs / bbg / thermal / full) so every variant compiles
   on every commit (see `.github/workflows/ci-kernel-matrix.yml`).
3. **avbroot** — once the kernel boots, consider AVB-clean images
   (`avb_custom_key` + re-sign) so locked-bootloader users can flash too.
4. **cfig/Android_boot_image_editor** — boot+vbmeta co-update when we need
   vbmeta-hash-correct flashes (locked devices).
5. **payload-dumper-go** — for the LOS/OTA build path later.
6. **susfs4ksu-module universal binary** — package into the APEX ksu-module
   (the userspace `ksu_susfs` companion to the kernel SUSFS).
7. **KernelSU-Next manager** — for the root migration once the kernel boots.
