#!/usr/bin/env bash
# device-state.sh — one-shot device state snapshot (the "brain-first" check).
#
# Captures everything a session needs to start from ground truth:
# kernel, slot, ROM, root, bootloader facts, battery, APEX sysfs, USB IDs.
# Output is human-readable by default; --json for machines (Hermes).
#
# Usage: device-state.sh [--json] [--fastboot]
#   --fastboot  also query the bootloader (requires entering fastboot)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JSON=0
FB=0
[ "${1:-}" = "--json" ] && JSON=1
[ "${1:-}" = "--fastboot" ] && FB=1

get() { "$HERE/adb-retry.sh" --max-tries 3 -- "$1" 2>/dev/null | head -1 | tr -d '\r'; }

UNAME=$(get "uname -r" || true)
SLOT=$(get "getprop ro.boot.slot_suffix" || true)
BUILD=$(get "getprop ro.build.display.id" || true)
SDK=$(get "getprop ro.build.version.sdk" || true)
LOCKED=$(get "getprop ro.boot.flash.locked" || true)
VBSTATE=$(get "getprop ro.boot.vbmeta.device_state" || true)
VBSTATE2=$(get "getprop ro.boot.verifiedbootstate" || true)
BATT=$(get "dumpsys battery | grep -E 'level|status' | tr '\n' ' '" || true)
APEX=$(get "ls /sys/class/apex/ 2>/dev/null | tr '\n' ' '" || true)
ROOT=$(get "su -c 'id -u' 2>/dev/null" || true)
KSU=$(get "ls /data/adb/ksu/bin/ 2>/dev/null | head -2 | tr '\n' ' '" || true)
USB=$(lsusb 2>/dev/null | grep 18d1 | awk '{print $7, $8}' | head -1 || true)

if [ "$JSON" -eq 1 ]; then
  echo "{\"uname\":\"$UNAME\",\"slot\":\"$SLOT\",\"build\":\"$BUILD\",\"sdk\":\"$SDK\",\"flash_locked\":\"$LOCKED\",\"vbmeta_state\":\"$VBSTATE\",\"verifiedboot\":\"$VBSTATE2\",\"battery\":\"$BATT\",\"apex_sysfs\":\"$APEX\",\"root_uid\":\"$ROOT\",\"ksu_bin\":\"$KSU\",\"usb\":\"$USB\"}"
  exit 0
fi

echo "=== device state ==="
echo "  kernel     : $UNAME"
echo "  slot       : $SLOT"
echo "  build      : $BUILD (sdk $SDK)"
echo "  bootloader : flash.locked=$LOCKED vbmeta=$VBSTATE verifiedboot=$VBSTATE2"
echo "  battery    : $BATT"
echo "  apex sysfs : ${APEX:-<absent>}"
echo "  root       : ${ROOT:+uid $ROOT}${ROOT:-<none>}"
echo "  ksu bin    : ${KSU:-<absent>}"
echo "  usb        : ${USB:-<no device>}"

if [ "$FB" -eq 1 ]; then
  echo "=== fastboot facts (requires bootloader) ==="
  "$HERE/slot.sh" list 2>/dev/null || echo "  (device not in fastboot)"
fi
