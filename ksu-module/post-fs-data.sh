#!/system/bin/sh
# APEX ROM KSU Module — post-fs-data script
#
# Runs after /data is mounted but before zygote starts.
# Sets up kernel detection and early boot properties.

MODDIR=${0%/*}

# APEX safe mode — after a watchdog/panic reboot apex_safe_mode.sh sets this
# flag and disables all KSU modules. Bail out early so the module stack does
# not run until the user clears safe mode (apex_safe_mode_clear.sh or
# Apex Control) and reboots.
if [ -f /data/adb/apex/safe_mode ]; then
  echo "APEX ROM: safe mode active — module stack disabled (clear + reboot to re-enable)"
  log -t apex_safe_mode -p w "safe mode active — skipping module setup"
  exit 0
fi

# Kernel detection — verify APEX kernel is present
APEX_KERNEL=$(cat /proc/version 2>/dev/null | grep -c "APEX")
if [ "$APEX_KERNEL" -eq 0 ]; then
  echo "APEX ROM: WARNING — APEX kernel not detected. Some features may not work."
  echo "APEX ROM: Expected APEX kernel 5.15.x. Found: $(cat /proc/version 2>/dev/null)"
else
  echo "APEX ROM: APEX kernel detected."
fi

# Set early boot properties
setprop ro.apex.kernel_detected $APEX_KERNEL
setprop ro.apex.version "1.0.0"
setprop ro.apex.rom "apex-rom"

# Create APEX data directories
mkdir -p /data/adb/apex
mkdir -p /data/adb/apex/models
mkdir -p /data/adb/apex/logs
mkdir -p /data/adb/apex/backup

# Set permissions for agent socket directory
mkdir -p /dev/socket/apex-agent
chown system:system /dev/socket/apex-agent
chmod 0750 /dev/socket/apex-agent
