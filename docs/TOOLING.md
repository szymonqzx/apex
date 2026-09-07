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
