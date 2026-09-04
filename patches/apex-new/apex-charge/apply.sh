#!/usr/bin/env bash
# apply.sh — install the APEX charge control module
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
DST_DIR="$KERNEL/drivers/apex"

mkdir -p "$DST_DIR"
cp "$SRC_DIR/apex_charge.c" "$DST_DIR/"
cp "$SRC_DIR/Kconfig" "$DST_DIR/Kconfig.charge"
cp "$SRC_DIR/Makefile" "$DST_DIR/Makefile.charge"

# Source the Kconfig if not already present
if ! grep -q "drivers/apex/Kconfig.charge" "$KERNEL/drivers/apex/Kconfig"; then
  echo 'source "drivers/apex/Kconfig.charge"' >> "$KERNEL/drivers/apex/Kconfig"
fi

# Append to the apex Makefile
if ! grep -q "apex_charge" "$DST_DIR/Makefile"; then
  echo 'obj-$(CONFIG_APEX_CHARGE) += apex_charge.o' >> "$DST_DIR/Makefile"
fi

echo "  apex-charge: installed"
