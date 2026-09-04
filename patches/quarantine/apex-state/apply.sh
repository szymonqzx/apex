#!/usr/bin/env bash
# patches/apex-state/apply.sh — install the apex control plane driver.
# Creates drivers/apex/, wires Kconfig + Makefile. Idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

SRC="$HERE/src/apex.c"
DST_DIR="$KERNEL/drivers/apex"
DST="$DST_DIR/apex.c"

[ -d "$KERNEL" ] || { echo "kernel tree not found: $KERNEL" >&2; exit 1; }
mkdir -p "$DST_DIR"

# 1. Source file
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
    echo "apex.c already installed"
else
    cp "$SRC" "$DST"
    echo "installed $DST"
fi

# 2. drivers/apex/Kconfig
if [ ! -f "$DST_DIR/Kconfig" ] ||
   ! grep -q "config APEX" "$DST_DIR/Kconfig"; then
    printf '%s\n' "$(cat "$HERE/Kconfig.append")" > "$DST_DIR/Kconfig"
    echo "wrote drivers/apex/Kconfig"
else
    echo "drivers/apex/Kconfig already present"
fi

# 3. drivers/apex/Makefile
if [ ! -f "$DST_DIR/Makefile" ] ||
   ! grep -q "obj-\$(CONFIG_APEX)" "$DST_DIR/Makefile"; then
    printf '%s\n' "$(cat "$HERE/Makefile.append")" > "$DST_DIR/Makefile"
    echo "wrote drivers/apex/Makefile"
else
    echo "drivers/apex/Makefile already present"
fi

# 4. Wire into drivers/Kconfig (source line) + drivers/Makefile (obj line)
if ! grep -q 'source "drivers/apex/Kconfig"' "$KERNEL/drivers/Kconfig"; then
    printf '\nsource "drivers/apex/Kconfig"\n' >> "$KERNEL/drivers/Kconfig"
    echo "wired drivers/Kconfig"
else
    echo "drivers/Kconfig already wired"
fi

if ! grep -q "obj-\$(CONFIG_APEX) += apex/" "$KERNEL/drivers/Makefile"; then
    printf '\nobj-$(CONFIG_APEX) += apex/\n' >> "$KERNEL/drivers/Makefile"
    echo "wired drivers/Makefile"
else
    echo "drivers/Makefile already wired"
fi
