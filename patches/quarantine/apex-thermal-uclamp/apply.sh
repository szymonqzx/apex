#!/bin/bash
# apex-thermal-uclamp — Apply the apex thermal uclamp cooling device
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${1:-.}"

echo "[apex-thermal-uclamp] Applying to $KERNEL_DIR"

# Copy the driver
cp "$SCRIPT_DIR/src/apex_thermal_uclamp.c" "$KERNEL_DIR/drivers/thermal/apex_thermal_uclamp.c"

# Add to Makefile
if ! grep -q 'apex_thermal_uclamp' "$KERNEL_DIR/drivers/thermal/Makefile"; then
	echo 'obj-$(CONFIG_APEX_THERMAL_UCLAMP) += apex_thermal_uclamp.o' >> "$KERNEL_DIR/drivers/thermal/Makefile"
fi

# Add Kconfig entry
KCONFIG="$KERNEL_DIR/drivers/thermal/Kconfig"
if ! grep -q 'APEX_THERMAL_UCLAMP' "$KCONFIG"; then
	sed -i '/endmenu/i\
config APEX_THERMAL_UCLAMP\
\ttristate "APEX thermal uclamp cooling device"\
\tdepends on THERMAL && CPU_FREQ && ENERGY_MODEL\
\thelp\
\t  Thermal cooling device that caps CPU frequency via the energy\
\t  model performance table instead of direct throttling. Provides\
\t  smoother performance degradation under thermal pressure.\
\t  Inspired by Google cdev_uclamp from Pixel kernel.\
\
' "$KCONFIG"
fi

echo "[apex-thermal-uclamp] Done"
