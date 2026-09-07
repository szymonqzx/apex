#!/vendor/bin/sh
# apex_pocket_detect.sh — pocket detection via proximity sensor
#
# Polls the proximity sensor sysfs node and sets apex.pocket property
# to 1 when near (in pocket) or 0 when far (out of pocket).
#
# The proximity sensor on topaz/tapas (SM6225-AD) exposes:
#   /sys/class/sensors/proximity/proximity_near  (0=far, 1=near)
# or via the IIO interface:
#   /sys/bus/iio/devices/iio:device*/in_proximity_near
#
# This script is started as a oneshot service from apex_pocket.rc.
# It loops with a 2-second interval to minimize battery impact.

set -euo pipefail

PROX_SYSFS=""
PROX_POLL_INTERVAL=2  # seconds

# Find the proximity sensor sysfs path
find_proximity_sensor() {
  # Try standard sysfs path first
  if [ -f /sys/class/sensors/proximity/proximity_near ]; then
    PROX_SYSFS="/sys/class/sensors/proximity/proximity_near"
    return 0
  fi
  # Try IIO interface
  for dev in /sys/bus/iio/devices/iio:device*; do
    if [ -f "$dev/in_proximity_near" ]; then
      PROX_SYSFS="$dev/in_proximity_near"
      return 0
    fi
  done
  # Try input device
  for dev in /sys/class/input/input*; do
    if [ -f "$dev/proximity" ]; then
      PROX_SYSFS="$dev/proximity"
      return 0
    fi
  done
  return 1
}

if ! find_proximity_sensor; then
  # No proximity sensor found — exit silently
  exit 0
fi

LAST_STATE=""

while true; do
  STATE=$(cat "$PROX_SYSFS" 2>/dev/null || echo "0")

  # Normalize: 1=near (in pocket), 0=far (out of pocket)
  if [ "$STATE" = "1" ] || [ "$STATE" = "near" ]; then
    STATE="1"
  else
    STATE="0"
  fi

  # Only setprop on state change to reduce property system load
  if [ "$STATE" != "$LAST_STATE" ]; then
    setprop "apex.pocket" "$STATE"
    LAST_STATE="$STATE"
  fi

  sleep "$PROX_POLL_INTERVAL"
done
