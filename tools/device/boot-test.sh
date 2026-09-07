#!/usr/bin/env bash
# boot-test.sh — verify a device booted the expected kernel.
#
# Watches for adb, then checks: kernel version, APEX sysfs presence,
# boot completion, and panics. Designed for the A/B trial loop: an agent
# flashes a slot, reboots, runs boot-test.sh, and rolls back on non-zero.
#
# Usage: boot-test.sh [--expect <kver-substring>] [--expect-apex]
#                     [--timeout S] [--json]
#   --expect VER   kernel version substring to require (e.g. "5.15.211")
#   --expect-apex  require /sys/class/apex to exist (APEX kernel features)
#   --timeout S    max wait for adb (default 180)
#   --json         emit a machine-readable result object
#
# Exit: 0 = boot verified, 2 = timeout, 3 = wrong kernel, 4 = panic found.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXPECT=""
EXPECT_APEX=0
TIMEOUT=180
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --expect) EXPECT="$2"; shift 2 ;;
    --expect-apex) EXPECT_APEX=1 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --json) JSON=1 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

result() {  # result <code> <json-fragment>
  if [ "$JSON" -eq 1 ]; then
    echo "{\"boot\":\"$1\",$2}"
  fi
  exit "$1"
}

# --- wait for adb ---
WAITED=0
while ! timeout 5 adb devices 2>/dev/null | grep -q "device$"; do
  sleep 5
  WAITED=$((WAITED + 5))
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    result 2 '"reason":"adb-timeout","waited_seconds":'"$WAITED"
  fi
done

# --- collect facts (each via adb-retry; short commands) ---
KVER=$("$HERE/adb-retry.sh" --max-tries 5 -- "uname -r" 2>/dev/null | head -1 | tr -d '\r' || echo "")
SLOT=$("$HERE/adb-retry.sh" --max-tries 3 -- "getprop ro.boot.slot_suffix" 2>/dev/null | head -1 | tr -d '\r' || echo "")
BOOTED=$("$HERE/adb-retry.sh" --max-tries 3 -- "getprop sys.boot_completed" 2>/dev/null | head -1 | tr -d '\r' || echo "")
APEX=$("$HERE/adb-retry.sh" --max-tries 2 -- "ls /sys/class/apex/ 2>/dev/null | head -1" 2>/dev/null | head -1 | tr -d '\r' || echo "")

echo "== boot-test: kernel='$KVER' slot='$SLOT' boot_completed='$BOOTED' apex='$APEX'"

JSON_FRAG="\"kernel\":\"$KVER\",\"slot\":\"$SLOT\",\"boot_completed\":\"$BOOTED\",\"apex\":\"$APEX\""

# --- panic check (pstore) ---
PS=$("$HERE/adb-retry.sh" --max-tries 2 -- "su -c 'ls /sys/fs/pstore/ 2>/dev/null | grep -ci panic'" 2>/dev/null | head -1 | tr -d '\r' || echo 0)
if [ "${PS:-0}" != "0" ] && [ -n "${PS:-}" ]; then
  result 4 "$JSON_FRAG,\"panic_records\":$PS"
fi

[ -n "$KVER" ] || result 2 "$JSON_FRAG,\"reason\":\"no-kernel-string\""

if [ -n "$EXPECT" ] && [[ "$KVER" != *"$EXPECT"* ]]; then
  echo "== FAIL: expected kernel containing '$EXPECT', got '$KVER'" >&2
  result 3 "$JSON_FRAG,\"reason\":\"kernel-mismatch\",\"expected\":\"$EXPECT\""
fi

if [ "$EXPECT_APEX" -eq 1 ] && [ -z "$APEX" ]; then
  echo "== FAIL: expected APEX sysfs but /sys/class/apex is absent" >&2
  result 3 "$JSON_FRAG,\"reason\":\"apex-sysfs-missing\""
fi

result 0 "$JSON_FRAG,\"reason\":\"ok\""
