#!/system/bin/sh
# APEX ROM KSU Module — uninstall.sh
#
# Cleans up APEX-specific data directories and stops the agent daemon.
# The KSU module system automatically removes /system overlay files.

MODDIR=${0%/*}

# Stop apexagentd if running
stop apexagentd 2>/dev/null
killall apexagentd 2>/dev/null

# Stop health check monitor
killall apex_agent_healthcheck.sh 2>/dev/null

# Clean up socket
rm -rf /dev/socket/apex-agent 2>/dev/null

# Preserve logs but remove runtime data
rm -rf /data/adb/apex/models 2>/dev/null

# Reset properties
setprop ro.apex.kernel_detected 0 2>/dev/null

echo "APEX ROM: Module uninstalled. Agent daemon stopped."
echo "APEX ROM: Logs preserved at /data/adb/apex/logs/"
