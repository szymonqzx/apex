#!/usr/bin/env bash
# patches/apex-display/apply.sh — apply KCAL display calibration patch
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$(cd "$HERE/../../.." && pwd)/kernel}"

echo ">>> Applying apex-display (KCAL) patch..."

# Copy the KCAL source into the kernel tree
mkdir -p "$KERNEL/drivers/video/apex"
cp "$HERE/src/apex_kcal.c" "$KERNEL/drivers/video/apex/apex_kcal.c"

# Add Kconfig entry for APEX_KCAL
KCONFIG="$KERNEL/drivers/video/Kconfig"
if ! grep -q "APEX_KCAL" "$KCONFIG" 2>/dev/null; then
    # Insert before the endmenu in drivers/video/Kconfig
    sed -i '/^endmenu/i\
config APEX_KCAL\
\ttristate "APEX KCAL display color calibration"\
\tdepends on FB\
\tdefault y\
\thelp\
\t  Provides RGB gain adjustment for the MDSS display panel via sysfs.\
\t  Exposes /sys/class/apex_kcal/rgb_gains for per-channel gain control.' "$KCONFIG"
fi

# Add Makefile entry
MAKEFILE="$KERNEL/drivers/video/Makefile"
if ! grep -q "apex_kcal" "$MAKEFILE" 2>/dev/null; then
    echo 'obj-$(CONFIG_APEX_KCAL) += apex/apex_kcal.o' >> "$MAKEFILE"
fi

echo "    apex-display patch applied"
