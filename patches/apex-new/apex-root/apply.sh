#!/usr/bin/env bash
# apply.sh — install native root (KernelSU-Next) + SUSFS root hiding.
#
# Vendored from:
#   - KernelSU-Next (KernelSU-Next/KernelSU-Next, kernel/ dir)
#   - SUSFS (simonpunk/susfs4ksu, fs/susfs.c + include/linux/susfs.h)
#
# KernelSU-Next has no prctl channel, so SUSFS commands are dispatched via a
# new prctl syscall hook (kernelsu/feature/susfs_glue.c) registered with the
# KSU-Next dispatcher (ksu_register_syscall_hook).
#
# Idempotent: if the markers are present, sources are re-copied (identical)
# and the fs wiring patch is skipped.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"
SRC="$(cd "$(dirname "$0")" && pwd)/src"

# 1. KernelSU-Next module
rm -rf "$KERNEL/kernelsu"
cp -r "$SRC/kernelsu" "$KERNEL/kernelsu"

# 2. SUSFS core files
cp "$SRC/susfs.c" "$KERNEL/fs/"
cp "$SRC/susfs.h" "$KERNEL/include/linux/"

# 3. fs/kernel wiring (namei, open, proc, sys, memfd, Kconfig, Makefile)
#    Skip if already applied (markers present).
if [ -f "$KERNEL/fs/susfs.c" ] && \
   [ -d "$KERNEL/kernelsu" ] && \
   grep -q "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" "$KERNEL/fs/Makefile" 2>/dev/null; then
  echo "  apex-root: already applied"
  exit 0
fi

cd "$KERNEL"
if ! patch -p1 --forward < "$SRC/fsmods.patch" > /dev/null 2>&1; then
  echo "  ERROR: fsmods.patch did not apply cleanly" >&2
  exit 1
fi

echo "  apex-root: KernelSU-Next + SUSFS installed"
