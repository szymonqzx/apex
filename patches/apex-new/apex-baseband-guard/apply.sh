#!/usr/bin/env bash
# apply.sh — install Baseband Guard (BBG), an LSM that blocks writes to
# critical partitions (boot, dtbo, vbmeta, ...) to prevent hard-bricks.
#
# Vendored from vc-teahouse/Baseband-guard @ a54e0dc (GPL-2.0), with a
# simplified 5.15-pinned Makefile. The OPPO-only "efisp exploit" allowlist
# extension is intentionally NOT included (no efisp partition on topaz).
#
# Idempotent: re-running copies identical sources and appends nothing.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src/Baseband-guard"
DST_DIR="$KERNEL/drivers/Baseband-guard"

mkdir -p "$DST_DIR/tracing"
cp "$SRC_DIR"/baseband_guard.c "$SRC_DIR"/baseband_guard.h \
   "$SRC_DIR"/blkdev_helper.c "$SRC_DIR"/blkdev_helper.h \
   "$SRC_DIR"/kernel_compat.h "$SRC_DIR"/Kconfig "$SRC_DIR"/Makefile \
   "$SRC_DIR"/LICENSE "$DST_DIR/"
cp "$SRC_DIR"/tracing/tracing.c "$SRC_DIR"/tracing/tracing.h \
   "$SRC_DIR"/tracing/kernel_compat.h "$DST_DIR/tracing/"

# Wire into drivers/Kconfig (idempotent)
if ! grep -q "drivers/Baseband-guard/Kconfig" "$KERNEL/drivers/Kconfig"; then
  sed -i '/source "drivers\/firmware\/Kconfig"/i source "drivers/Baseband-guard/Kconfig"' "$KERNEL/drivers/Kconfig"
fi

# Wire into drivers/Makefile (idempotent)
if ! grep -q "Baseband-guard" "$KERNEL/drivers/Makefile"; then
  echo 'obj-$(CONFIG_BBG) += Baseband-guard/' >> "$KERNEL/drivers/Makefile"
fi

echo "  apex-baseband-guard: installed"
