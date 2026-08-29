# tools

Build, verification, and packaging tools for the APEX kernel.

## Files

| File | Purpose |
| :--- | :--- |
| `build-kernel.sh` | Apply patches, merge defconfig fragments, build kernel |
| `check-configs.py` | Verify defconfig fragment consistency (no conflicts, deps met) |
| `verify.sh` | Verify build output (Image, modules, dtb, version string) |
| `package-anykernel3.sh` | Package kernel + modules + overlays into flashable zip |

## Usage

```bash
# 1. Check config fragments for conflicts
python3 tools/check-configs.py

# 2. Build the kernel (applies patches, merges fragments, builds)
./tools/build-kernel.sh chickernel_defconfig [ksun|ksun.susfs]

# 3. Verify the build
./tools/verify.sh

# 4. Package for flashing
./tools/package-anykernel3.sh
```

## Build requirements

- Clang 19+ (Android LLVM toolchain)
- LLD (LLVM linker)
- aarch64-linux-gnu- cross-compiler (for modules)
- `scripts/kconfig/merge_config.sh` (in kernel tree)
- `zip` (for AnyKernel3 packaging)
