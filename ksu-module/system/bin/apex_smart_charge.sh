#!/vendor/bin/sh
# apex_smart_charge.sh — smart charging scheduler
#
# Implements time-based charge limiting:
#   - Charges to a target percent (default 80%) during the night
#   - Tops up to 100% shortly before the user's wake time
#
# Reads properties:
#   persist.apex.charge_limit  — target charge percent (default: 80)
#   persist.apex.top_up_time   — time to start top-up (HHMM, default: 0630)
#   persist.apex.wake_time     — user wake time (HHMM, default: 0700)
#
# Polls battery level every 60 seconds. Minimal battery impact.

set -euo pipefail

POLL_INTERVAL=60  # seconds

get_prop() {
  getprop "$1" "$2"
}

get_current_time_hhmm() {
  date +%H%M
}

get_battery_level() {
  cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "0"
}

get_charge_limit() {
  LIMIT=$(get_prop persist.apex.charge_limit "80")
  echo "$LIMIT"
}

get_top_up_time() {
  get_prop persist.apex.top_up_time "0630"
}

get_wake_time() {
  get_prop persist.apex.wake_time "0700"
}

should_top_up() {
  CURRENT=$(get_current_time_hhmm)
  TOP_UP=$(get_top_up_time)
  WAKE=$(get_wake_time)

  # If current time is between top_up_time and wake_time, we should top up
  if [ "$CURRENT" -ge "$TOP_UP" ] 2>/dev/null && [ "$CURRENT" -lt "$WAKE" ] 2>/dev/null; then
    return 0
  fi
  return 1
}

while true; do
  LIMIT=$(get_charge_limit)

  if should_top_up; then
    # Top-up window: charge to 100%
    setprop apex.charge_limit 0
    setprop apex.smart_charge.state "top_up"
  else
    # Normal: charge to limit
    setprop apex.charge_limit "$LIMIT"
    setprop apex.smart_charge.state "limited"
  fi

  sleep "$POLL_INTERVAL"
done
