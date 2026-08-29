#!/bin/bash
# apex-blx — Apply the apex BLX backlight dimmer to the kernel tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${1:-.}"

echo "[apex-blx] Applying to $KERNEL_DIR"

# Copy the driver
cp "$SCRIPT_DIR/src/apex_blx.c" "$KERNEL_DIR/drivers/video/backlight/apex_blx.c"

# Add to Makefile
if ! grep -q 'apex_blx' "$KERNEL_DIR/drivers/video/backlight/Makefile"; then
	echo 'obj-$(CONFIG_APEX_BLX) += apex_blx.o' >> "$KERNEL_DIR/drivers/video/backlight/Makefile"
fi

# Add Kconfig entry
KCONFIG="$KERNEL_DIR/drivers/video/backlight/Kconfig"
if ! grep -q 'APEX_BLX' "$KCONFIG"; then
	sed -i '/endmenu/i\
config APEX_BLX\
\tbool "APEX BLX backlight dimmer"\
\tdepends on BACKLIGHT_CLASS_DEVICE && POWER_SUPPLY\
\thelp\
\t  Caps maximum backlight brightness on battery to save power\
\t  on AMOLED displays. Automatically removes cap when charging.\
\t  Configurable via /sys/kernel/apex_blx/max_brightness.\
\
' "$KCONFIG"
fi

echo "[apex-blx] Done"
