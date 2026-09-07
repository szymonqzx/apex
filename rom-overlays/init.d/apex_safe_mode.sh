#!/system/bin/sh
# apex_safe_mode.sh — crash/watchdog safe-mode detector
#
# Runs early (post-fs-data, before zygote). If the last boot was caused by a
# watchdog reset, kernel panic, or hardware reset, set the APEX safe-mode flag
# and disable all KSU modules so the module stack that may have caused the hang
# does not run. The device boots into a known-good state instead of looping.
#
# The flag persists until the user clears it (Apex Control or
# apex_safe_mode_clear.sh), then a reboot re-enables the full stack.
#
# Brick-safety: only touches /data/adb — never system, boot, or bootloader.

SAFE_FLAG=/data/adb/apex/safe_mode
MODULE_DIR=/data/adb/modules

# qcom bootloader + common Android crash bootreasons
case "$(getprop ro.boot.bootreason)" in
  *watchdog*|*wdog*|*hard*|*panic*|*kernel_panic*|*hw_reset*|*s2r*|*smpl*|*wdt*)
    log -t apex_safe_mode -p w "crash bootreason '$(getprop ro.boot.bootreason)' — entering safe mode"
    mkdir -p /data/adb/apex
    touch "$SAFE_FLAG"
    setprop sys.apex.safe_mode 1
    # Disable all KSU modules. Markers persist, so the disabled state holds
    # across reboots until the user clears safe mode.
    for m in "$MODULE_DIR"/*; do
      [ -d "$m" ] || continue
      touch "$m/disable" 2>/dev/null || true
    done
    ;;
  *)
    setprop sys.apex.safe_mode 0
    ;;
esac

exit 0
