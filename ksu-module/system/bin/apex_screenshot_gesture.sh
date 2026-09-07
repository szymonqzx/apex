#!/vendor/bin/sh
# apex_screenshot_gesture.sh — three-finger screenshot gesture monitor
#
# Monitors touch input for three-finger swipe gesture and triggers
# a screenshot via the Android screencap utility.
#
# Uses getevent to detect multi-touch events. When 3+ touch slots
# are active and a downward swipe is detected, captures a screenshot.
#
# Screenshots are saved to /sdcard/Pictures/Screenshots/ with timestamp.

set -euo pipefail

SCREENSHOT_DIR="/sdcard/Pictures/Screenshots"
INPUT_DEVICE=""
THREE_FINGER_THRESHOLD=3

# Find the touchscreen input device
find_touchscreen() {
  for dev in /dev/input/event*; do
    # Check if device reports ABS_MT_SLOT (multi-touch)
    if [ -f "/sys/class/input/$(basename "$dev")/device/capabilities/abs" ]; then
      caps=$(cat "/sys/class/input/$(basename "$dev")/device/capabilities/abs" 2>/dev/null || echo "")
      if echo "$caps" | grep -q "2f"; then
        INPUT_DEVICE="$dev"
        return 0
      fi
    fi
  done
  return 1
}

# Initialize: create screenshot directory
if [ "${1:-}" = "--init" ]; then
  mkdir -p "$SCREENSHOT_DIR" 2>/dev/null || true
  exit 0
fi

if ! find_touchscreen; then
  exit 0
fi

mkdir -p "$SCREENSHOT_DIR" 2>/dev/null || true

# Monitor touch events for three-finger gesture
# This is a simplified implementation — production would use
# a native input monitor with proper gesture recognition.
# For now, we count active touch slots via getevent.
ACTIVE_SLOTS=0
LAST_SCREENSHOT=0

# Minimum seconds between screenshots (prevent spam)
COOLDOWN=2

take_screenshot() {
  NOW=$(date +%s)
  if [ $((NOW - LAST_SCREENSHOT)) -ge "$COOLDOWN" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILENAME="$SCREENSHOT_DIR/Screenshot_$TIMESTAMP.png"
    screencap -p "$FILENAME" 2>/dev/null || true
    LAST_SCREENSHOT=$NOW
    # Notify via property for Apex Control to pick up
    setprop apex.screenshot.taken "$FILENAME"
  fi
}

# Parse getevent output for touch slot events
getevent -l "$INPUT_DEVICE" 2>/dev/null | while IFS= read -r line; do
  # Count ABS_MT_SLOT events to track active fingers
  case "$line" in
    *ABS_MT_SLOT*)
      # This is a simplified heuristic — real implementation
      # would track slot creation and removal properly
      SLOT=$(echo "$line" | awk '{print $3}' | cut -c3-)
      if [ "$SLOT" -ge $((THREE_FINGER_THRESHOLD - 1)) ] 2>/dev/null; then
        take_screenshot
      fi
      ;;
  esac
done
