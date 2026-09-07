#!/usr/bin/env bash
# rom-overlays/init.d/apex_kernel_detect.sh
#
# Detects whether the running kernel is the APEX kernel.
# Sets system properties for Apex Control to display a badge/notice.
#
# The ROM WARNS (never blocks boot) when not running the APEX kernel:
# - Sets ro.apex.kernel to "apex" or "stock"
# - Writes a dmesg flag for diagnostics
# - Sets ro.apex.kernel_notice for the boot notice text
#
# Design decision: APEX kernel is a clean drop-in for LineageOS 23.2.
# The ROM boots on any compatible kernel but warns when APEX kernel
# features (agent, charging, tuning, chroot) are unavailable.
#
# Brick-safety: READ-ONLY. No writes to any partition or sysfs.
set -euo pipefail

PROC_VERSION="/proc/version"
APEX_MARKER="apex"

# Read kernel version string
kernel_string=""
if [ -r "$PROC_VERSION" ]; then
  kernel_string="$(cat "$PROC_VERSION")"
fi

# Detect APEX kernel by looking for the apex marker in the version string.
# The APEX kernel sets LOCALVERSION to "-apex" and includes "apex" in
# /proc/version (via CONFIG_LOCALVERSION and the build script).
is_apex=0
if echo "$kernel_string" | grep -qi "$APEX_MARKER"; then
  is_apex=1
fi

# Also check /proc/sys/kernel/version or /proc/version_signature
if [ "$is_apex" -eq 0 ]; then
  # Check for APEX-specific sysfs node (created by apex kernel module)
  if [ -e "/proc/apex/version" ]; then
    is_apex=1
  fi
fi

# Set properties via setprop (available in init context)
if [ "$is_apex" -eq 1 ]; then
  setprop ro.apex.kernel "apex"
  setprop ro.apex.kernel_detected "true"
  setprop ro.apex.kernel_notice ""
  # dmesg flag for diagnostics
  echo "APEX: kernel detected — APEX kernel running" > /dev/kmsg 2>/dev/null || true
else
  setprop ro.apex.kernel "stock"
  setprop ro.apex.kernel_detected "false"
  setprop ro.apex.kernel_notice "WARNING: Stock kernel detected. APEX agent features (charging, tuning, chroot) require the APEX kernel. Flash the APEX kernel for full functionality."
  # dmesg flag for diagnostics
  echo "APEX: WARNING — stock kernel detected, APEX features limited" > /dev/kmsg 2>/dev/null || true
fi
