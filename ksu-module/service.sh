#!/system/bin/sh
# APEX ROM KSU Module — service.sh (post-boot)
#
# Runs after sys.boot_completed=1.
# Starts the APEX agent daemon and applies runtime kernel tuning.

MODDIR=${0%/*}

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Additional wait for system_server to stabilize
sleep 5

echo "APEX ROM: Starting post-boot services..."

# Apply build.prop overlays (idempotent — checks for APEX marker)
APEX_MARKER="# APEX ROM overlay"
SYSTEM_BUILD_PROP=/system/build.prop

if ! grep -q "$APEX_MARKER" "$SYSTEM_BUILD_PROP" 2>/dev/null; then
  echo "APEX ROM: Applying build.prop overlays..."
  # Only if system is writable (KSU overlay makes /system writable)
  if [ -w "$SYSTEM_BUILD_PROP" ]; then
    cat "$MODDIR/system/build.prop.append" >> "$SYSTEM_BUILD_PROP"
  fi
fi

# Apply hidden packages list
if [ -f "$MODDIR/system/hidden_packages.list" ]; then
  HMA_LIST=/data/adb/apex/hidden_packages.list
  cp "$MODDIR/system/hidden_packages.list" "$HMA_LIST"
fi

# Start agent health monitor
if [ -f "$MODDIR/system/bin/apex_agent_healthcheck.sh" ]; then
  chmod 755 "$MODDIR/system/bin/apex_agent_healthcheck.sh"
  "$MODDIR/system/bin/apex_agent_healthcheck.sh" &
fi

# Apply kernel runtime parameters
if [ -f "$MODDIR/system/bin/apex_tuning.sh" ]; then
  chmod 755 "$MODDIR/system/bin/apex_tuning.sh"
  "$MODDIR/system/bin/apex_tuning.sh"
fi

echo "APEX ROM: Post-boot setup complete."
