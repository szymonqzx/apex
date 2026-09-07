#!/system/bin/sh
# apex_agent_healthcheck.sh — monitors apexagentd and restarts if crashed
#
# Runs as a background loop from service.sh. Checks every 30 seconds.
# Maximum 5 restarts in 10 minutes (circuit breaker).

MODDIR="/data/adb/modules/apex_rom"
RESTART_COUNT=0
RESTART_WINDOW=600  # 10 minutes in seconds
WINDOW_START=$(date +%s)

while true; do
  # Check if apexagentd is running
  PID=$(pidof apexagentd 2>/dev/null)

  if [ -z "$PID" ]; then
    NOW=$(date +%s)
    ELAPSED=$((NOW - WINDOW_START))

    # Reset counter if window expired
    if [ "$ELAPSED" -gt "$RESTART_WINDOW" ]; then
      RESTART_COUNT=0
      WINDOW_START=$NOW
    fi

    # Circuit breaker: max 5 restarts per 10-minute window
    if [ "$RESTART_COUNT" -ge 5 ]; then
      echo "APEX ROM: apexagentd circuit breaker tripped — 5 restarts in 10min. Stopping." >&2
      # Log to APEX data dir for debugging
      echo "$(date): circuit breaker tripped" >> /data/adb/apex/logs/agent_health.log
      break
    fi

    echo "APEX ROM: apexagentd not running, attempting restart ($((RESTART_COUNT + 1))/5)..."
    start apexagentd 2>/dev/null || /system/bin/apexagentd &
    RESTART_COUNT=$((RESTART_COUNT + 1))
    echo "$(date): restart attempt $RESTART_COUNT" >> /data/adb/apex/logs/agent_health.log
  fi

  sleep 30
done
