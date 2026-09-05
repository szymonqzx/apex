#!/system/bin/sh
#
# apex_ab_verify.sh — A/B slot verification gate
#
# Runs on first boot of a new A/B slot. If all checks pass, marks the slot
# as boot-successful. If any check fails, switches back to the previous slot.
#
# This is the software-level test-before-commit gate. The bootloader's
# retry_count mechanism provides a hardware-level fallback if this script
# itself fails to run.
#
# Part of the APEX ROM update architecture (docs/UPDATE_ARCHITECTURE.md).
#

set -euo pipefail

LOG_TAG="apex_ab_verify"
PREVIOUS_SLOT=""
FAIL_ACTION="rollback"

log() {
  command log -t "$LOG_TAG" -p "i" "$1"
  echo "$1" >> /data/apex/ab_verify.log
}

fail() {
  log "VERIFY FAILED: $1"
  # Switch back to previous slot
  if [ -n "$PREVIOUS_SLOT" ]; then
    log "Rolling back to slot $PREVIOUS_SLOT"
    bootctl set-active-boot-slot "$PREVIOUS_SLOT"
  fi
  # Reboot to previous slot
  sync
  reboot
  exit 1
}

pass() {
  log "VERIFY PASSED: $1"
}

# Wait for property system to be ready
while [ "$(getprop ro.boot.slot_suffix)" = "" ]; do
  sleep 1
done

CURRENT_SLOT=$(getprop ro.boot.slot_suffix)
CURRENT_SLOT="${CURRENT_SLOT#_}"  # strip leading underscore

if [ "$CURRENT_SLOT" = "a" ]; then
  PREVIOUS_SLOT="b"
elif [ "$CURRENT_SLOT" = "b" ]; then
  PREVIOUS_SLOT="a"
else
  fail "Cannot determine current slot (got: '$CURRENT_SLOT')"
fi

log "Running A/B verification on slot $CURRENT_SLOT (previous: $PREVIOUS_SLOT)"

mkdir -p /data/apex

# ── Check 1: Kernel version ──────────────────────────────────────────
KVER=$(uname -r)
log "Kernel version: $KVER"
case "$KVER" in
  5.15*)
    pass "Kernel version OK ($KVER)"
    ;;
  *)
    fail "Kernel version not 5.15.x (got: $KVER)"
    ;;
esac

# ── Check 2: APEX sysfs present ──────────────────────────────────────
if [ -d /sys/class/apex/ ]; then
  pass "APEX sysfs present"
else
  fail "APEX sysfs not found at /sys/class/apex/"
fi

# ── Check 3: system_server started ───────────────────────────────────
# Wait up to 60 seconds for system_server
SYSSERVER_OK=0
for i in $(seq 1 60); do
  if service list 2>/dev/null | grep -q "activity"; then
    SYSSERVER_OK=1
    break
  fi
  sleep 1
done

if [ "$SYSSERVER_OK" = 1 ]; then
  pass "system_server started"
else
  fail "system_server not started within 60s"
fi

# ── Check 4: apexagentd registered with servicemanager ───────────────
# Wait up to 30 seconds for apexagentd
AGENT_OK=0
for i in $(seq 1 30); do
  if service list 2>/dev/null | grep -q "apex.agent"; then
    AGENT_OK=1
    break
  fi
  # apexagentd may not be registered if this is a pre-agent build
  # Check if the service file exists — if not, skip this check
  if [ ! -f /system/bin/apexagentd ]; then
    log "apexagentd binary not present — skipping agent check"
    AGENT_OK=1
    break
  fi
  sleep 1
done

if [ "$AGENT_OK" = 1 ]; then
  pass "Agent service check OK"
else
  fail "apexagentd not registered with servicemanager within 30s"
fi

# ── All checks passed ────────────────────────────────────────────────
setprop persist.apex.slot_verified 1
bootctl mark-boot-successful
log "Slot $CURRENT_SLOT verified and marked successful"
sync
