#!/usr/bin/env bash
# patches/apex-watchdog/apply.sh — install the apex watchdog into the kernel tree.
# Idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

SRC="$HERE/src/apex_watchdog.c"
DST_DIR="$KERNEL/drivers/apex"
DST="$DST_DIR/apex_watchdog.c"

[ -d "$KERNEL" ] || {
  echo "kernel tree not found: $KERNEL" >&2
  exit 1
}
mkdir -p "$DST_DIR"

# 1. Source file
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "apex_watchdog.c already installed"
else
  cp "$SRC" "$DST"
  echo "installed $DST"
fi

# 2. Kconfig: append to drivers/apex/Kconfig
if [ -f "$DST_DIR/Kconfig" ] && ! grep -q "config APEX_WATCHDOG" "$DST_DIR/Kconfig"; then
  printf '\n%s\n' "$(cat "$HERE/Kconfig.append")" >>"$DST_DIR/Kconfig"
  echo "appended APEX_WATCHDOG to drivers/apex/Kconfig"
else
  echo "APEX_WATCHDOG Kconfig already present"
fi

# 3. Makefile: append to drivers/apex/Makefile
if ! grep -q "apex_watchdog" "$DST_DIR/Makefile"; then
  printf '\n%s' "$(cat "$HERE/Makefile.append")" >>"$DST_DIR/Makefile"
  echo "appended apex_watchdog.o to drivers/apex/Makefile"
else
  echo "apex_watchdog Makefile already present"
fi
