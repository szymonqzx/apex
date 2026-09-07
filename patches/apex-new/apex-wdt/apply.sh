#!/usr/bin/env bash
# apply.sh — enable the PMIC watchdog (PON WDT) on modern PMICs
#
# The tree ships pm8916_wdt.c (the qcom PON WDT driver with hard-reset
# mode). Its of_device_id table only matches "qcom,pm8916-wdt"; SM6225
# boards (PM6125/PM8150-family PMICs) present the same PON WDT block under
# "qcom,pm8150-wdt"/"qcom,pm6125-wdt". This patch widens the table so the
# driver binds on topaz and the watchdog core keeps it petted (the 30s kick
# is handled by the watchdog subsystem worker while no userspace client owns
# the device). If the WDT fires, the PMIC hard-resets the SoC — the basis
# for APEX safe-mode recovery (userspace detects the crash bootreason and
# disables the KSU module).
#
# Idempotent: each modification checks its marker before applying.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

WDT="$KERNEL/drivers/watchdog/pm8916_wdt.c"

if [ ! -f "$WDT" ]; then
  echo "ERROR: $WDT not found" >&2
  exit 1
fi

# 1. Widen the of_device_id table
if ! grep -q "qcom,pm8150-wdt" "$WDT"; then
  python3 - "$WDT" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """static const struct of_device_id pm8916_wdt_id_table[] = {
	{ .compatible = "qcom,pm8916-wdt" },
	{ }
};"""
new = """static const struct of_device_id pm8916_wdt_id_table[] = {
	{ .compatible = "qcom,pm8916-wdt" },
	{ .compatible = "qcom,pm8150-wdt" },
	{ .compatible = "qcom,pm6125-wdt" },
	{ .compatible = "qcom,pm8998-wdt" },
	{ .compatible = "qcom,pms405-wdt" },
	{ }
};"""
if old not in s:
    sys.exit("pm8916_wdt id table not found")
open(p, "w").write(s.replace(old, new, 1))
PYEOF
  echo "  apex-wdt: pm8916_wdt id table widened (pm8150/pm6125/pm8998/pms405)"
else
  echo "  apex-wdt: id table already widened"
fi

# 2. Neutralize the misleading identity string (cosmetic, optional)
sed -i 's/"QCOM PM8916 PON WDT"/"QCOM PON WDT"/g' "$WDT" 2>/dev/null || true

echo "  apex-wdt: done"
