#!/bin/bash
# apex-cpuboost — Apply the apex CPU input boost driver to the kernel tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${1:-.}"

echo "[apex-cpuboost] Applying to $KERNEL_DIR"

# Copy the driver
cp "$SCRIPT_DIR/src/apex_cpu_boost.c" "$KERNEL_DIR/drivers/cpufreq/apex_cpu_boost.c"

# Add to Makefile
if ! grep -q 'apex_cpu_boost' "$KERNEL_DIR/drivers/cpufreq/Makefile"; then
	echo 'obj-$(CONFIG_APEX_CPU_BOOST) += apex_cpu_boost.o' >> "$KERNEL_DIR/drivers/cpufreq/Makefile"
fi

# Add Kconfig entry
KCONFIG="$KERNEL_DIR/drivers/cpufreq/Kconfig"
if ! grep -q 'APEX_CPU_BOOST' "$KCONFIG"; then
	sed -i '/endmenu/i\
config APEX_CPU_BOOST\
\tbool "APEX CPU input boost driver"\
\tdepends on CPU_FREQ\
\thelp\
\t  Input-driven CPU frequency booster for SM6225-AD.\
\t  Boosts CPU min frequency on touch events for immediate\
\t  responsiveness. Inspired by Qualcomm cpu-boost driver.\
\
' "$KCONFIG"
fi

echo "[apex-cpuboost] Done"
