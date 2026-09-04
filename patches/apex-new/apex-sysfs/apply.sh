#!/usr/bin/env bash
# apply.sh — install the APEX sysfs class
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
DST_DIR="$KERNEL/drivers/apex"

mkdir -p "$DST_DIR"
cp "$SRC_DIR/apex_sysfs.c" "$DST_DIR/"
cp "$SRC_DIR/Kconfig" "$DST_DIR/"
cp "$SRC_DIR/Makefile" "$DST_DIR/"

# Add to drivers/Kconfig if not already there
if ! grep -q "source \"drivers/apex/Kconfig\"" "$KERNEL/drivers/Kconfig"; then
  sed -i '/source "drivers\/firmware\/Kconfig"/i source "drivers/apex/Kconfig"' "$KERNEL/drivers/Kconfig"
fi

# Add to drivers/Makefile if not already there
if ! grep -q "obj-y += apex/" "$KERNEL/drivers/Makefile"; then
  echo 'obj-y += apex/' >> "$KERNEL/drivers/Makefile"
fi

echo "  apex-sysfs: installed"
