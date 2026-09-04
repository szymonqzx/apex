#!/system/bin/sh
# apex-wakelock-audit.sh — Audit and blacklist cosmetic wakelocks
#
# Xiaomi's HyperOS/MIUI vendor services are disproportionately wake-happy.
# Standby drain on these devices is usually death by a thousand small
# wakelocks rather than one big offender.
#
# Strategy:
#   - Audit /sys/kernel/debug/wakeup_sources for top offenders
#   - Blacklist provably cosmetic wakelocks (telemetry-adjacent)
#   - LEAVE ALONE: modem/RIL stack, WLAN driver — killing their wakelocks
#     breaks connectivity, not just battery. These are also the drivers
#     we're patching for NetHunter, so they must stay functional.
#
# Usage:
#   adb shell su -c "sh /data/adb/apex/wakelock-audit.sh"
#   adb shell su -c "sh /data/adb/apex/wakelock-audit.sh --apply"

set -uo pipefail

MODE="audit"
if [ "${1:-}" = "--apply" ]; then
  MODE="apply"
fi

WAKEUP_SOURCES="/sys/kernel/debug/wakeup_sources"
WL_BLACKLIST_DIR="/data/adb/apex/wakelock-blacklist"

# Wakelocks that are SAFE to suppress (cosmetic / telemetry-adjacent)
# Format: one pattern per line, matched against wakelock name.
# NOTE: Each pattern MUST be on its own line.  The previous form used
# backslash-continued lines inside double quotes, which concatenates
# without newlines — producing one giant string like
# "telemetryanalyticsmiui.*report..." that never matches anything.
SAFE_PATTERNS='telemetry
analytics
miui.*report
xiaomi.*log
data.*report
usage.*stats
feedback
crash.*report'

# Wakelocks that must NEVER be suppressed (connectivity-critical)
# If a wakelock matches any of these, it is spared regardless of SAFE_PATTERNS
PROTECTED_PATTERNS='qmi
ril
modem
wlan
wifi
ath
wcn
cnss
ipc
dsi
display
panel
sensor
alarm
power.*key'

echo "=== APEX Wakelock Audit ==="
echo "Mode: $MODE"
echo ""

if [ ! -f "$WAKEUP_SOURCES" ]; then
  echo "ERROR: $WAKEUP_SOURCES not found"
  echo "  Ensure debugfs is mounted: mount -t debugfs none /sys/kernel/debug"
  exit 1
fi

mkdir -p "$WL_BLACKLIST_DIR"

# Read top wakelock offenders (sorted by active time)
echo "--- Top 20 wakelock offenders (by active time) ---"
# Format: name active_count event_count expire_count active_since last_time
# Preventing_since wakeup_count
awk 'NR<=20 {printf "%-40s active=%-8s events=%-8s\n", $1, $2, $3}' "$WAKEUP_SOURCES" 2>/dev/null || \
  head -20 "$WAKEUP_SOURCES" 2>/dev/null

echo ""
echo "--- Analysis ---"

SUPPRESSED=0
SPARED=0
TOTAL=0

# Check each wakelock against patterns
while IFS= read -r line; do
  [ -z "$line" ] && continue
  WL_NAME=$(echo "$line" | awk '{print $1}')
  [ -z "$WL_NAME" ] && continue
  TOTAL=$((TOTAL + 1))

  # Check if protected (connectivity-critical)
  # NOTE: The original code used `echo "$PROTECTED_PATTERNS" | while ...`
  # which runs the while loop in a pipeline *subshell*.  Variables set
  # inside that subshell (IS_PROTECTED=1) never propagated to the parent
  # shell, so every wakelock was classified as UNKNOWN — including
  # modem/RIL/QMI wakelocks that must never be suppressed.  Fix: use a
  # here-doc redirect (no pipeline subshell) so variables survive.
  IS_PROTECTED=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if echo "$WL_NAME" | grep -qi "$pat"; then
      IS_PROTECTED=1
      break
    fi
  done <<EOF
$PROTECTED_PATTERNS
EOF

  # Check if safe to suppress
  IS_SAFE=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if echo "$WL_NAME" | grep -qi "$pat"; then
      IS_SAFE=1
      break
    fi
  done <<EOF
$SAFE_PATTERNS
EOF

  if [ "$IS_PROTECTED" -eq 1 ]; then
    echo "  [SPARE] $WL_NAME (protected: connectivity-critical)"
    SPARED=$((SPARED + 1))
  elif [ "$IS_SAFE" -eq 1 ]; then
    echo "  [SUPPRESS] $WL_NAME (cosmetic/telemetry)"
    if [ "$MODE" = "apply" ]; then
      echo "$WL_NAME" >> "$WL_BLACKLIST_DIR/blacklist.conf"
      # Attempt to release the wakelock if it has an active count
      echo 0 > "/sys/kernel/debug/wakeup_sources/$WL_NAME" 2>/dev/null || true
    fi
    SUPPRESSED=$((SUPPRESSED + 1))
  else
    echo "  [UNKNOWN] $WL_NAME (review manually)"
  fi
done < "$WAKEUP_SOURCES" 2>/dev/null

echo ""
echo "=== Audit Summary ==="
echo "  Total wakelocks: $TOTAL"
echo "  Suppressed (cosmetic): $SUPPRESSED"
echo "  Spared (protected): $SPARED"
echo "  Unknown (review): $((TOTAL - SUPPRESSED - SPARED))"

if [ "$MODE" = "audit" ]; then
  echo ""
  echo "  Run with --apply to suppress cosmetic wakelocks:"
  echo "    sh /data/adb/apex/wakelock-audit.sh --apply"
else
  echo ""
  echo "  Blacklist saved to: $WL_BLACKLIST_DIR/blacklist.conf"
  echo "  Cosmetic wakelocks suppressed."
fi

echo ""
echo "  Protected categories (never suppressed):"
echo "    modem, RIL, QMI, WLAN, WiFi, ath, WCN, CNSS"
echo "    display, panel, sensor, alarm, power key"
echo ""
echo "  Suppressed categories (cosmetic):"
echo "    telemetry, analytics, miui reporting, xiaomi logging"
echo "    data reporting, usage stats, feedback, crash reports"
