# Build tools

Helper scripts. **Nothing is written yet.**

## Plan

- `build-kernel.sh`     — `make` invocation with the right clang flags
- `apply-overlays.sh`   — Dirty-apply build.prop/init rc/selinux via apex-bridge
- `package-anykernel3.sh` — Zip the kernel + modules into AnyKernel3 format
- `setup-chroot.sh`     — Download + extract Arch rootfs, install pkglist
- `verify.sh`           — The 8-point verification checklist
- `doctor.sh`           — `apex doctor` style diagnostic
