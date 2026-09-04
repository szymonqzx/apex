#!/usr/bin/env bash
# apply.sh — install the APEX charge control module
#
# Idempotent: re-running appends nothing and copies identical sources.
# The APEX_CHARGE config block is appended to drivers/apex/Kconfig (no
# separate Kconfig.charge / source line needed).
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
DST_DIR="$KERNEL/drivers/apex"

mkdir -p "$DST_DIR"
cp "$SRC_DIR/apex_charge.c" "$DST_DIR/"

# Append the config block to the apex Kconfig (idempotent)
if [ -f "$DST_DIR/Kconfig" ]; then
  if ! grep -q "config APEX_CHARGE" "$DST_DIR/Kconfig"; then
    { printf '\n'; grep -v '^#' "$SRC_DIR/Kconfig"; } >> "$DST_DIR/Kconfig"
    echo "  apex-charge: Kconfig block appended"
  fi
else
  grep -v '^#' "$SRC_DIR/Kconfig" > "$DST_DIR/Kconfig"
fi

# Append to the apex Makefile (idempotent)
if [ -f "$DST_DIR/Makefile" ]; then
  if ! grep -q "apex_charge" "$DST_DIR/Makefile"; then
    echo 'obj-$(CONFIG_APEX_CHARGE) += apex_charge.o' >> "$DST_DIR/Makefile"
  fi
else
  cp "$SRC_DIR/Makefile" "$DST_DIR/Makefile"
fi

echo "  apex-charge: installed"
