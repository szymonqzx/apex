#!/usr/bin/env bash
# apply.sh — install the APEX thermal learner module
#
# Adds drivers/apex/apex_thermal.c (thermal history ring buffer + tunable
# trips under /sys/class/apex/thermal/, history in /proc/apex/thermal_history).
# Must run AFTER apex-sysfs (needs the exported apex_kobj).
#
# Idempotent: each modification checks its marker before applying.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
DST_DIR="$KERNEL/drivers/apex"

mkdir -p "$DST_DIR"

# 1. Source file
if [ -f "$DST_DIR/apex_thermal.c" ]; then
  echo "  apex-thermal: source already installed"
else
  cp "$SRC_DIR/apex_thermal.c" "$DST_DIR/"
  echo "  apex-thermal: installed apex_thermal.c"
fi

# 2. drivers/apex/Makefile
if ! grep -q "CONFIG_APEX_THERMAL" "$DST_DIR/Makefile" 2>/dev/null; then
  echo 'obj-$(CONFIG_APEX_THERMAL) += apex_thermal.o' >> "$DST_DIR/Makefile"
  echo "  apex-thermal: Makefile updated"
fi

# 3. drivers/apex/Kconfig
if ! grep -q "APEX_THERMAL" "$DST_DIR/Kconfig" 2>/dev/null; then
  cat >> "$DST_DIR/Kconfig" << 'EOF'

config APEX_THERMAL
	tristate "APEX thermal learner (history + trips)"
	default y
	help
	  This enables the APEX thermal learner: a 7-day history ring
	  buffer (/proc/apex/thermal_history) sampled from the primary
	  thermal zone, plus tunable trip thresholds under
	  /sys/class/apex/thermal/ that the userspace learner adjusts
	  by up to +/-2C based on the rolling average.

	  If unsure, say Y.
EOF
  echo "  apex-thermal: Kconfig updated"
fi

echo "  apex-thermal: done"
