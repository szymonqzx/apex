#!/usr/bin/env bash
# slot.sh — A/B slot state and control (fastboot-first, bootctl fallback).
#
# Usage:
#   slot.sh current          — print the active slot (a|b)
#   slot.sh list             — full slot state (fastboot getvar all, filtered)
#   slot.sh set <a|b>        — set the active slot
#   slot.sh other            — print the inactive slot
#
# Reads FASTBOOT_BIN/ADB_BIN env. Exits 0 on success, 1 on failure.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

dev_present() {
  timeout 10 "${FASTBOOT_BIN:-fastboot}" devices 2>/dev/null | grep -q "fastboot"
}

case "${1:-}" in
  current)
    if dev_present; then
      "$HERE/fastboot-retry.sh" -- getvar current-slot 2>/dev/null | grep -oE "current-slot: [ab]" | awk '{print $2}'
    elif timeout 10 "${ADB_BIN:-adb}" devices 2>/dev/null | grep -q "device$"; then
      "$HERE/adb-retry.sh" -- "getprop ro.boot.slot_suffix" | tr -d '_'
    else
      echo "no device (fastboot or adb) — cannot determine slot" >&2
      exit 2
    fi
    ;;
  other)
    CUR=$( "$0" current )
    case "$CUR" in a) echo b ;; b) echo a ;; *) echo "unknown slot: $CUR" >&2; exit 1 ;; esac
    ;;
  list)
    if dev_present; then
      timeout 30 "${FASTBOOT_BIN:-fastboot}" getvar all 2>&1 | grep -E "slot-|current-slot|unlocked" || true
    else
      echo "no fastboot device — cannot list slots" >&2; exit 1
    fi
    ;;
  set)
    [ $# -eq 2 ] || { echo "usage: slot.sh set <a|b>" >&2; exit 64; }
    SLOT="$2"
    case "$SLOT" in a|b) : ;; *) echo "slot must be a or b" >&2; exit 64 ;; esac
    if dev_present; then
      "$HERE/fastboot-retry.sh" -- set_active "$SLOT"
    else
      echo "no fastboot device — cannot set active slot" >&2; exit 1
    fi
    ;;
  *)
    echo "usage: slot.sh current|other|list|set <a|b>" >&2; exit 64 ;;
esac
