#!/bin/bash
# apply.sh — Apply apex-charge patch
# Adds the APEX Charge Manager driver to the kernel build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_ROOT="${KERNEL_ROOT:-$(pwd)}"
SRC_DIR="$SCRIPT_DIR/src"

echo "  [apex-charge] Applying advanced charging & battery manager patch..."

# Copy source files to kernel tree
mkdir -p "$KERNEL_ROOT/drivers/power_supply/apex"
cp "$SRC_DIR/apex_charge.c" "$KERNEL_ROOT/drivers/power_supply/apex/"

# Add to Makefile
MAKEFILE="$KERNEL_ROOT/drivers/power_supply/apex/Makefile"
cat > "$MAKEFILE" << 'EOF'
# APEX Charge Manager
obj-$(CONFIG_APEX_CHARGE) += apex_charge.o
EOF

# Add Kconfig entry
KCONFIG="$KERNEL_ROOT/drivers/power_supply/Kconfig"
if ! grep -q 'APEX_CHARGE' "$KCONFIG" 2>/dev/null; then
    # Insert before the endif for POWER_SUPPLY
    sed -i '/^endif # POWER_SUPPLY/i\
config APEX_CHARGE\
	tristate "APEX Advanced Charging and Battery Manager"\
	depends on POWER_SUPPLY\
	default y\
	help\
	  APEX Charge Manager for PM7250B SMB5 charger and QG fuel gauge.\
	  Provides sysfs-controlled charge limiting, charging profiles,\
	  thermal mitigation, bypass charging, and battery health monitoring.\
	  Hardware: PM7250B SMB5 + SMB1355 + QG (Redmi Note 12 4G, 5000mAh, 33W).\
\
	  Say Y to enable advanced charging controls.
' "$KCONFIG"
fi

# Add to parent Makefile
PARENT_MAKE="$KERNEL_ROOT/drivers/power_supply/Makefile"
if ! grep -q 'apex' "$PARENT_MAKE" 2>/dev/null; then
    echo 'obj-$(CONFIG_APEX_CHARGE) += apex/' >> "$PARENT_MAKE"
fi

echo "  [apex-charge] Done."
