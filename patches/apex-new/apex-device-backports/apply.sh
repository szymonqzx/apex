#!/usr/bin/env bash
# apply.sh — port topaz device-specific drivers from legacy kernel to Zepharo
#
# Ports: fingerprint (FPC1020, Goodix FOD), NOPMI charger (BQ2589X, SC8551,
# SM5602, LN8000, PMIC voter), battery secret (DS28E16, onewire GPIO),
# ANT check, MI thermal interface.
#
# These are Xiaomi/Redmi device-specific drivers not in upstream CAF.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"
LEGACY="$(cd "$(dirname "$0")" && pwd)/legacy"

if [ ! -d "$LEGACY" ]; then
  echo "  ERROR: legacy source not found at $LEGACY" >&2
  exit 1
fi

echo "  porting device-specific drivers from legacy..."

# --- 1. Fingerprint ---
mkdir -p "$KERNEL/drivers/input/fingerprint/fpc"
mkdir -p "$KERNEL/drivers/input/fingerprint/goodix"
cp "$LEGACY/drivers/input/fingerprint/Kconfig" "$KERNEL/drivers/input/fingerprint/"
cp "$LEGACY/drivers/input/fingerprint/Makefile" "$KERNEL/drivers/input/fingerprint/"
cp "$LEGACY/drivers/input/fingerprint/fpc/Kconfig" "$KERNEL/drivers/input/fingerprint/fpc/"
cp "$LEGACY/drivers/input/fingerprint/fpc/Makefile" "$KERNEL/drivers/input/fingerprint/fpc/"
cp "$LEGACY/drivers/input/fingerprint/fpc/fpc1020_platform_tee.c" "$KERNEL/drivers/input/fingerprint/fpc/"
cp "$LEGACY/drivers/input/fingerprint/goodix/Kconfig" "$KERNEL/drivers/input/fingerprint/goodix/"
cp "$LEGACY/drivers/input/fingerprint/goodix/Makefile" "$KERNEL/drivers/input/fingerprint/goodix/"
cp "$LEGACY/drivers/input/fingerprint/goodix/"*.c "$KERNEL/drivers/input/fingerprint/goodix/"
cp "$LEGACY/drivers/input/fingerprint/goodix/"*.h "$KERNEL/drivers/input/fingerprint/goodix/"
echo "  fingerprint: ported"

# Add to drivers/input/Kconfig
if ! grep -q "drivers/input/fingerprint/Kconfig" "$KERNEL/drivers/input/Kconfig"; then
  sed -i '/source "drivers\/input\/keyboard\/Kconfig"/a source "drivers/input/fingerprint/Kconfig"' "$KERNEL/drivers/input/Kconfig"
fi
# Add to drivers/input/Makefile
if ! grep -q "fingerprint" "$KERNEL/drivers/input/Makefile"; then
  echo 'obj-$(CONFIG_INPUT_FINGERPRINT) += fingerprint/' >> "$KERNEL/drivers/input/Makefile"
fi

# --- 2. NOPMI charger ---
mkdir -p "$KERNEL/drivers/power/supply/nopmi"
cp "$LEGACY/drivers/power/supply/nopmi/"* "$KERNEL/drivers/power/supply/nopmi/"
# Copy nopmi_chg top-level files
cp "$LEGACY/drivers/power/supply/nopmi_chg.c" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg.h" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg_common.c" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg_common.h" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg_iio.h" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg_jeita.c" "$KERNEL/drivers/power/supply/"
cp "$LEGACY/drivers/power/supply/nopmi_chg_jeita.h" "$KERNEL/drivers/power/supply/"
echo "  nopmi charger: ported"

# --- 3. Battery secret ---
mkdir -p "$KERNEL/drivers/power/supply/battery_secret"
cp "$LEGACY/drivers/power/supply/battery_secret/"* "$KERNEL/drivers/power/supply/battery_secret/"
echo "  battery_secret: ported"

# Add NOPMI + battery_secret Kconfig sources to power/supply/Kconfig
if ! grep -q "drivers/power/supply/nopmi/Kconfig" "$KERNEL/drivers/power/supply/Kconfig"; then
  # Insert before endif # POWER_SUPPLY
  sed -i '/endif # POWER_SUPPLY/i\
source "drivers/power/supply/nopmi/Kconfig"\
source "drivers/power/supply/battery_secret/Kconfig"' "$KERNEL/drivers/power/supply/Kconfig"
fi

# Add NOPMI_CHARGER config entry
if ! grep -q "config NOPMI_CHARGER" "$KERNEL/drivers/power/supply/Kconfig"; then
  sed -i '/endif # POWER_SUPPLY/i\
config NOPMI_CHARGER\
	tristate "NOPMI Charger Support"\
	depends on FG_SM5602 && BQ2589X_CHARGER\
	help\
	  Say Y to include support for NOPMI Charger.' "$KERNEL/drivers/power/supply/Kconfig"
fi

# Add to power/supply/Makefile
if ! grep -q "nopmi" "$KERNEL/drivers/power/supply/Makefile"; then
  cat >> "$KERNEL/drivers/power/supply/Makefile" << 'EOF'
obj-$(CONFIG_NOPMI_CHARGER)     += nopmi/
obj-$(CONFIG_NOPMI_CHARGER)     += battery_secret/
obj-$(CONFIG_NOPMI_CHARGER)     += nopmi-chg.o
nopmi-chg-y	+= nopmi_chg.o nopmi_chg_jeita.o nopmi_chg_common.o
EOF
fi

# --- 4. ANT check ---
cp "$LEGACY/drivers/misc/ant_check.c" "$KERNEL/drivers/misc/"
cp "$LEGACY/drivers/misc/ant_check_div.c" "$KERNEL/drivers/misc/"
# Add Kconfig entries
if ! grep -q "config ANT_CHECK" "$KERNEL/drivers/misc/Kconfig"; then
  cat >> "$KERNEL/drivers/misc/Kconfig" << 'EOF'

config ANT_CHECK
	tristate "ANT check driver"
	help
	  Say Y to enable ANT check driver.

config ANT_CHECK_DIV
	tristate "ANT check div driver"
	depends on ANT_CHECK
	help
	  Say Y to enable ANT check div driver.
EOF
fi
# Add to Makefile
if ! grep -q "ant_check" "$KERNEL/drivers/misc/Makefile"; then
  echo 'obj-$(CONFIG_ANT_CHECK)         += ant_check.o' >> "$KERNEL/drivers/misc/Makefile"
  echo 'obj-$(CONFIG_ANT_CHECK_DIV)     += ant_check_div.o' >> "$KERNEL/drivers/misc/Makefile"
fi
echo "  ant_check: ported"

# --- 5. MI thermal interface ---
cp "$LEGACY/drivers/thermal/mi_thermal_interface.c" "$KERNEL/drivers/thermal/"
# Add Kconfig entry
if ! grep -q "config MI_THERMAL_INTERFACE" "$KERNEL/drivers/thermal/Kconfig"; then
  cat >> "$KERNEL/drivers/thermal/Kconfig" << 'EOF'

config MI_THERMAL_INTERFACE
	tristate "Xiaomi thermal interface"
	help
	  Say Y to enable Xiaomi thermal interface driver.
EOF
fi
# Add to Makefile
if ! grep -q "mi_thermal" "$KERNEL/drivers/thermal/Makefile"; then
  echo 'obj-$(CONFIG_MI_THERMAL_INTERFACE)	+= mi_thermal_interface.o' >> "$KERNEL/drivers/thermal/Makefile"
fi
echo "  mi_thermal_interface: ported"

echo "  device-backports: all drivers installed"
