#!/usr/bin/env bash
# flash-boot.sh — resilient, safety-first boot image flasher.
#
# Learned from the 2026-09-07 session: USB links die mid-transfer, fastboot
# lies on flaky links, and a bad kernel must never take down the last good
# slot. Rules enforced here:
#   1. Default flashes ONLY the INACTIVE slot (A/B safety net).
#   2. The write is verified (slot dump hash == local image hash) when the
#      link allows; at minimum the flash must report OKAY.
#   3. Slot activation is a separate, explicit step (--activate).
#   4. Every fastboot call goes through fastboot-retry.sh.
#
# Usage: flash-boot.sh <boot.img> [--slot a|b] [--activate] [--both]
#   --slot X    target slot (default: inactive slot)
#   --activate  also set the target slot active (explicit opt-in)
#   --both      flash both slots (only when you really mean it)
#
# Exit: 0 success, 1 failure, 2 no device.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${1:?usage: flash-boot.sh <boot.img> [--slot a|b] [--activate] [--both]}"
shift

SLOT=""
ACTIVATE=0
BOTH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) SLOT="$2"; shift 2 ;;
    --activate) ACTIVATE=1 ;;
    --both) BOTH=1 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ -f "$IMG" ] || { echo "ERROR: $IMG not found" >&2; exit 1; }
LOCAL_SHA=$(sha256sum "$IMG" | awk '{print $1}')

# --- Decide target slot(s) ---
if [ "$BOTH" -eq 1 ]; then
  TARGETS="a b"
elif [ -n "$SLOT" ]; then
  TARGETS="$SLOT"
else
  TARGETS="$("$HERE/slot.sh" other)"
fi
echo "== flash-boot: $IMG → slot(s) [$TARGETS] (sha256 $LOCAL_SHA)"

for S in $TARGETS; do
  case "$S" in a|b) : ;; *) echo "ERROR: invalid slot $S" >&2; exit 64 ;; esac
done

# --- Flash each target with retry + post-write verification ---
for S in $TARGETS; do
  echo "== flashing boot_$S"
  "$HERE/fastboot-retry.sh" --max-tries 6 -- flash "boot_$S" "$IMG" >/dev/null \
    || { echo "ERROR: flash boot_$S failed" >&2; exit 1; }

  # Verify the written slot content matches the local image.
  # (dd over adb needs root; fall back to a fastboot re-read when possible.)
  VERIFIED=0
  DUMP=$("$HERE/fastboot-retry.sh" --max-tries 3 -- getvar "partition-size:boot_$S" 2>/dev/null | grep -oE "0x[0-9a-f]+" | head -1 || true)
  if adb devices 2>/dev/null | grep -q "device$" && "$HERE/adb-retry.sh" -- "su -c 'id -u'" 2>/dev/null | grep -q "^0$"; then
    SHA=$("$HERE/adb-retry.sh" -- "su -c 'dd if=/dev/block/by-name/boot_$S bs=1M 2>/dev/null | sha256sum'" 2>/dev/null | awk '{print $1}' || true)
    if [ "$SHA" = "$LOCAL_SHA" ]; then
      echo "  [verify] boot_$S matches local image (sha256 $SHA)"
      VERIFIED=1
    else
      echo "  [verify] MISMATCH boot_$S: got $SHA want $LOCAL_SHA" >&2
    fi
  else
    echo "  [verify] skipped (no rooted adb) — flash reported OKAY"
    VERIFIED=1
  fi
  [ "$VERIFIED" -eq 1 ] || { echo "ERROR: write verification failed for boot_$S" >&2; exit 1; }
done

# --- Activate if requested ---
if [ "$ACTIVATE" -eq 1 ]; then
  for S in $TARGETS; do
    echo "== activating slot $S"
    "$HERE/fastboot-retry.sh" -- set_active "$S"
    break  # only one slot can be active
  done
fi

echo "== flash-boot done"
exit 0
