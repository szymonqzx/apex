# tools

Build, verification, packaging, and release tooling for the APEX kernel.

## Core pipeline

| Step | Tool | Purpose |
| :--- | :--- | :--- |
| 1. Patch | `apply-patches.sh` | Apply `patches/apex-new/` series to the kernel tree |
| 2. Configure | `build-kernel.sh` | Sync `defconfig/apex_defconfig` + configure + build |
| 3. Verify | `verify.sh` | Verify build output (Image, modules, features, hardening) |
| 4. Package | `package-anykernel3.sh` | Create flashable AnyKernel3 zip + depmod metadata |
| 5. Release | `release.sh` | Tests + tag + checksums + manifest |

## Usage

```bash
# 1. Apply patches (idempotent)
./tools/apply-patches.sh

# 2. Build (incremental; --clean for full rebuild)
./tools/build-kernel.sh
./tools/build-kernel.sh --clean

# 3. Verify the build (--strict turns warnings into failures)
./tools/verify.sh
./tools/verify.sh --strict

# 4. Validate the tracked defconfig
python3 tools/check-configs.py

# 5. Package the flashable zip
./tools/package-anykernel3.sh

# 6. Cut a release (tests, build, tag v<ver>-zepharo, manifest)
./tools/release.sh 0.2.1 --build
```

## Build requirements

- Clang 22+ (kernel was built and tested with clang 22.1.8) — `clang`, `ld.lld`
- LLVM binutils — `llvm-ar`, `llvm-nm`, `llvm-objcopy`, `llvm-objdump`, `llvm-strip`
- `aarch64-linux-gnu-gcc` (for module builds / compat)
- `zip`, `unzip`, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`
- `python3` + `pytest` (for certification tests)

## Other tools

| Tool | Purpose |
| :--- | :--- |
| `build-preflight.sh` | Fast structural checks of the kernel tree before the long build |
| `apex-dirty-modify.sh` | Apply ROM overlays to a running install (idempotent, backs up) |
| `apex-wakelock-audit.sh` | Diagnose standby drain (wakelock audit) |
| `apex_cert/` | Certification platform (evidence bundles, trust manifests, gates) |
| `autofdo-build.sh` | AutoFDO profile-guided build pipeline (experimental) |
| `compile-selinux.sh` | Compile SELinux policy fragments for the chroot domain |
| `irq-balance-check.sh` | Review IRQ distribution on-device |
| `zram-benchmark.sh` | A/B benchmark zRAM compression algorithms |
| `investigate-sm6225-repos.sh` | Diff xiaomi SM6225-AD repos for backport candidates |
