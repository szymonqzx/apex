# 19 — Build Pipeline

## Overview

APEX ROM has a comprehensive build pipeline covering kernel compilation, APK building, KSU module packaging, flashable zip creation, and multi-level verification. The pipeline is designed to be reproducible and safe — every artifact is verified before release.

## Build Tools

### tools/build-kernel.sh
Builds the APEX kernel from source:
1. Sources: CAF/CLO bengal-5.15 (vendored or gitignored)
2. Defconfig: `defconfig/apex_defconfig`
3. Toolchain: Clang 22.1.8 + LLD (CachyOS LLVM)
4. Output: `out/arch/arm64/boot/Image` (36MB, ARM64 kernel)
5. Modules: 239 `.ko` files in `out/`
6. Depmod: generates `modules.dep`, `modules.alias`, `modules.symbols`, `modules.builtin`

### tools/build-rom.sh
Builds the full ROM from LineageOS source:
1. Prerequisites: `~/los` directory with LOS 23.2 source synced
2. Applies APEX overlays to the source tree
3. Runs `m apex_topaz` (or equivalent)
4. Output: `out/target/product/topaz/` with system.img, vendor.img, boot.img
5. Currently **not functional** — LOS source not synced

### tools/package-anykernel3.sh
Packages the kernel as an AnyKernel3 flashable zip:
1. Copies AnyKernel3 template
2. Copies kernel Image as `zImage`
3. Copies 239 modules + depmod metadata
4. Copies `apex-load-modules.sh`
5. Output: `releases/apex-kernel-0.4.0-zepharo-anykernel3.zip` (70MB)

### tools/package-ksu-module.sh
Packages the KSU module:
1. Copies all files from `ksu-module/`
2. Ensures scripts are executable
3. Output: `releases/apex-rom-ksu-module-v1.0.0.zip` (22MB)

### tools/package-flashable.sh
Combines kernel + KSU module into a single flashable zip:
1. Copies AnyKernel3 template
2. Copies kernel Image, modules, depmod metadata
3. Copies KSU module zip
4. Output: `releases/apex-rom-flashable-v1.0.0-topaz.zip` (92MB)

### tools/build-pentest-drivers.sh
Builds out-of-tree pentest drivers (rtl8812au, rtl88x2bu, etc.):
1. Clones each driver repo into `drivers/net/wireless/external/`
2. Builds each as module against APEX kernel headers
3. Packages into `pentest-modules.zip`
4. Currently **not run** — no out-of-tree drivers built yet

### tools/release.sh
Creates a release:
1. Runs all build tools in order
2. Runs all verification scripts
3. Generates SHA256 checksums
4. Creates release manifest
5. Output: `releases/apex-release-*.manifest`

## Verification Tools

### tools/verify.sh (479 lines)
Comprehensive verification covering:
- Kernel image validity (ARM64 magic, size, version)
- Module count and depmod metadata
- AnyKernel3 script correctness
- KSU module completeness
- APK presence and sizes
- SELinux policy validity
- Brick-safety checks
- Build.prop overlay correctness

### tools/verify-rom.sh (310 lines)
ROM-specific verification:
- 28 checks covering flashable zip contents
- AnyKernel3 execution order (ak3-core → split_boot → write_boot)
- Boot backup before flash
- Only writes to `/dev/block/by-name/boot`
- KSU module structure
- APK presence in module
- Init RC file count
- SELinux policy enforcement

**Current status**: 28 PASS, 0 WARN, 0 FAIL

### tools/verify-brick-safety.sh (106 lines)
Dedicated brick-safety verification:
- Scans all scripts for forbidden path references
- Checks no script writes to bootloader/aboot/TZ/modem/XBL
- Verifies AnyKernel3 only targets boot partition
- Verifies backup function exists in anykernel.sh

**Current status**: failing (1 test failure — script returns non-zero)

### tools/verify-daily-driver.sh (145 lines)
Daily-driver feature verification:
- 33 checks covering init.d scripts, feature flags, app screens
- Checks all RC files exist and have correct content
- Verifies feature flag properties
- Checks Apex Control screens exist
- Verifies Lindroid completion

**Current status**: 33 PASS, 7 WARN, 0 FAIL

### tools/verify-stealth.sh (163 lines)
Hiding stack verification:
- 22 checks covering SuSFS, Shamiko, HMA, TrickyStore
- Verifies denylist contents
- Verifies hidden packages list
- Checks SELinux enforcement
- Verifies PIF fingerprint in build.prop

**Current status**: 22 PASS, 8 WARN, 0 FAIL

## CI

### .github/workflows/ci.yml
- **shellcheck**: `--severity=error -e SC1091 -e SC2030 -e SC2031`
- **shfmt**: formatting check
- **chezmoi apply dry-run**: on Linux + macOS
- **rom-build-verification**: runs `verify-rom.sh`

## Release Artifacts

| Artifact | Size | Contents |
|----------|------|----------|
| `apex-kernel-0.4.0-zepharo-anykernel3.zip` | 70MB | Kernel Image (36M), 239 modules, depmod metadata, apex-load-modules.sh |
| `apex-rom-ksu-module-v1.0.0.zip` | 22MB | 4 APKs, 17 init RC files, 8 shell scripts, SELinux policy, build.prop overlays |
| `apex-rom-flashable-v1.0.0-topaz.zip` | 92MB | Kernel + modules + KSU module combined |

## Build Environment

- **OS**: CachyOS Linux (Arch-based)
- **Java**: 21 (via mise)
- **Android SDK**: `~/.local/share/android-sdk` (platforms;android-36, build-tools;36.0.0)
- **Gradle**: 9.7
- **Kotlin**: 2.0.21
- **Compose**: 1.7
- **Clang**: 22.1.8 (CachyOS LLVM)
- **LLD**: 22.1.8

## Disk Requirements

- Kernel build output: ~15GB
- LOS source tree: ~100GB (not yet synced)
- APK build artifacts: ~2GB
- Release zips: ~200MB
- Total for kernel-only build: ~20GB
- Total for full ROM build: ~120GB
