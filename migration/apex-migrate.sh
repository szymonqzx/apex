#!/bin/sh
# apex-migrate.sh — single-shot Magisk + APatch -> KernelSU-Next migration
# (BUILD_PLAN.md Step 2 / DESIGN.md §4)
#
# Run from a root shell (Magisk/APatch currently provides root). One reboot.
#
# THIS IS DESTRUCTIVE: it uninstalls Magisk/APatch/LSPosed apps and deletes
# their /data/adb residue. Keybox is preserved (Yurikey + TrickyStore stay).
# Make the one-time off-device keybox backup (Step 1) BEFORE running this.
#
# After this script completes, you must manually:
#   1. Reboot to recovery (do NOT reboot to system — Magisk is gone)
#   2. Flash apex-kernel-*.zip in recovery
#   3. Reboot to system — KernelSU-Next is now active
#   4. Run step 2 (hiding stack install) from the KSU root shell

set -e

APEX=/data/adb/apex

if [ "$(id -u)" != "0" ]; then
    echo "apex-migrate: must run as root (from Magisk/APatch su shell)" >&2
    exit 1
fi

echo "apex-migrate: creating $APEX skeleton"
mkdir -p "$APEX"/{incidents,modules,replay,var,bridge}

# 1. Uninstall apps (keep data with -k; Yurikey/TrickyStore are NOT touched)
pm uninstall -k --user 0 com.topjohnwu.magisk 2>/dev/null || true
pm uninstall -k --user 0 me.bmax.apatch        2>/dev/null || true
pm uninstall -k --user 0 org.lsposed.manager    2>/dev/null || true
pm uninstall -k --user 0 com.solohsu.android.edxp.manager 2>/dev/null || true

# 2. Remove Magisk residue
[ -d /sbin/.magisk ] && rm -rf /sbin/.magisk
[ -d /data/adb/magisk ] && rm -rf /data/adb/magisk
[ -f /sbin/su ] && rm -f /sbin/su
[ -f /sbin/magisk ] && rm -f /sbin/magisk
[ -f /data/local/tmp/magisk ] && rm -f /data/local/tmp/magisk

# 3. Remove APatch residue
[ -d /data/adb/ap ] && find /data/adb/ap -mindepth 1 -delete

# 4. Stop Magisk services
stop magisk_daemon 2>/dev/null || true
stop magisk_pfs    2>/dev/null || true

echo ""
echo "apex-migrate: step 1 complete. Magisk/APatch removed."
echo ""
echo "IMPORTANT: Do NOT reboot to system. Next steps:"
echo "  1. Reboot to recovery:  reboot recovery"
echo "  2. Flash apex-kernel-*.zip in recovery"
echo "  3. Reboot to system (KernelSU-Next is now active)"
echo "  4. Run step 2 (hiding stack install) from KSU root shell"
echo ""
echo "This script will NOT auto-reboot. Run 'reboot recovery' when ready."
