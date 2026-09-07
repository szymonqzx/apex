#!/usr/bin/env bash
# adb-retry.sh — run an adb shell command resiliently.
#
# adb drops are common on custom ROMs (screen lock, USB-mode flips) and
# marginal links. This wrapper retries short commands with backoff. Keep
# commands SHORT — a long adb session is a dropped-link magnet.
#
# Usage: adb-retry.sh [--max-tries N] [--wait S] -- <shell command>
# Exit: 0 on success, 1 if the command returned non-zero, 2 no device.
#
# Example:
#   adb-retry.sh -- "uname -r; getprop ro.boot.slot_suffix"

set -euo pipefail

MAX_TRIES=6
WAIT=4
ADB_BIN="${ADB_BIN:-adb}"

while [ $# -gt 0 ]; do
  case "$1" in
    --max-tries) MAX_TRIES="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ $# -gt 0 ] || { echo "usage: $0 [--max-tries N] [--wait S] -- <shell command>" >&2; exit 64; }

attempt=0
while [ "$attempt" -lt "$MAX_TRIES" ]; do
  attempt=$((attempt + 1))
  OUT=$("$ADB_BIN" shell "$@" 2>&1) && {
    printf '%s\n' "$OUT"
    exit 0
  }
  echo "  [adb-retry] attempt $attempt/$MAX_TRIES failed: $(echo "$OUT" | head -1)" >&2
  sleep "$WAIT"
done

echo "adb-retry: giving up after $MAX_TRIES attempts" >&2
exit 2
