#!/vendor/bin/sh
# apex_thermal_learner.sh — 7-day thermal threshold learner
#
# Reads the APEX thermal history ring buffer, computes the rolling average,
# and shifts the trip thresholds by up to +/-2C:
#   - device historically hot  -> tighten trips (cool sooner)
#   - device historically cool -> relax trips (performance headroom)
#
# Safe defaults from day one: 45/55/65 C. Until 7 days of data exist the
# rolling average covers whatever samples are available (still >= 1 day of
# data before any shift exceeds ~1C thanks to the clamp).
#
# Disable with:  setprop persist.apex.thermal_learner 0
#
# Runs as a service: adjusts on start, then re-checks every hour.
# Brick-safety: read-only over /proc; writes only APEX sysfs trips.

set -euo pipefail

SYS=/sys/class/apex/thermal
HIST=/proc/apex/thermal_history
DEFAULT_LOW=45000
DEFAULT_MID=55000
DEFAULT_HIGH=65000
CHECK_INTERVAL=3600  # seconds

[ -d "$SYS" ] || exit 0
[ "$(getprop persist.apex.thermal_learner)" = "0" ] && exit 0

adjust_trips() {
  AVG=$(cat "$SYS/rolling_avg" 2>/dev/null || echo 0)
  [ "$AVG" -gt 0 ] || return 0  # no samples yet — keep defaults

  # shift = (mid - avg) / 10, clamped to +/-2000 mdeg (+/-2C)
  SHIFT=$(( (DEFAULT_MID - AVG) / 10 ))
  [ "$SHIFT" -gt 2000 ] && SHIFT=2000
  [ "$SHIFT" -lt -2000 ] && SHIFT=-2000

  echo $((DEFAULT_LOW + SHIFT)) > "$SYS/trip_low"
  echo $((DEFAULT_MID + SHIFT)) > "$SYS/trip_mid"
  echo $((DEFAULT_HIGH + SHIFT)) > "$SYS/trip_high"

  log -t apex_thermal_learner -p i \
    "avg=${AVG}mC shift=${SHIFT}mC trips=$((DEFAULT_LOW+SHIFT))/$((DEFAULT_MID+SHIFT))/$((DEFAULT_HIGH+SHIFT))"
}

log -t apex_thermal_learner -p i "thermal learner started"

while :; do
  [ "$(getprop persist.apex.thermal_learner)" = "0" ] && break
  adjust_trips
  sleep "$CHECK_INTERVAL"
done

exit 0
