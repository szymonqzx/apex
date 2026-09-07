#!/system/bin/sh
# apex_safe_mode_clear.sh — exit APEX safe mode
#
# Removes the safe-mode flag and re-enables all KSU modules. A reboot is
# required for the module stack to actually start again.
#
# Usage: /system/bin/apex_safe_mode_clear.sh
# Brick-safety: only touches /data/adb.

SAFE_FLAG=/data/adb/apex/safe_mode
MODULE_DIR=/data/adb/modules

if [ ! -f "$SAFE_FLAG" ]; then
  echo "APEX safe mode is not active."
  exit 0
fi

rm -f "$SAFE_FLAG"
for m in "$MODULE_DIR"/*; do
  [ -d "$m" ] || continue
  rm -f "$m/disable" 2>/dev/null || true
done
setprop sys.apex.safe_mode 0
log -t apex_safe_mode -p i "safe mode cleared — reboot to re-enable modules"
echo "APEX safe mode cleared. Reboot to re-enable the module stack."
exit 0
