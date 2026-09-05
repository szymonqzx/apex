#!/usr/bin/env bash
# apply.sh — add CHARGE_CONTROL_END_THRESHOLD to the bq2589x charger driver
#
# Instead of a parallel custom module (apex_charge.c), this patch adds the
# standard Android power_supply property CHARGE_CONTROL_END_THRESHOLD directly
# to the proven bq2589x charger driver.  The existing chg_dis_votable and
# monitor_work infrastructure handle the actual charger disable/enable — no
# new kernel threads, no new sysfs class, no novel code.
#
# Userspace writes the threshold percentage to:
#   /sys/class/power_supply/bbc/charge_control_end_threshold
# The monitor work (runs every 10 s) checks battery capacity against the
# threshold and votes on chg_dis_votable with 3% hysteresis.
#
# Idempotent: each modification checks its marker before applying.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

# ---------------------------------------------------------------------------
# 1. bq2589x_charger.h — add charge_end_threshold field to struct bq2589x
# ---------------------------------------------------------------------------
HDR="$KERNEL/drivers/power/supply/nopmi/bq2589x_charger.h"
if [ -f "$HDR" ] && ! grep -q 'charge_end_threshold' "$HDR"; then
  python3 - "$HDR" << 'PYEOF1'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tint\t\tchg_current;\n\tint\t\trsoc;"
new = "\tint\t\tchg_current;\n\tint\t\trsoc;\n\tint\t\tcharge_end_threshold;"
if old in s:
    s = s.replace(old, new, 1)
else:
    # Fallback: insert after chg_current line
    old2 = "\tint\t\tchg_current;"
    new2 = "\tint\t\tchg_current;\n\tint\t\tcharge_end_threshold;"
    if old2 in s:
        s = s.replace(old2, new2, 1)
open(p, 'w').write(s)
PYEOF1
  echo "  apex-charge: bq2589x_charger.h charge_end_threshold field"
fi

# ---------------------------------------------------------------------------
# 2. bq2589x_charger.c — add property, get/set/writeable, monitor_work check
# ---------------------------------------------------------------------------
SRC="$KERNEL/drivers/power/supply/nopmi/bq2589x_charger.c"
if [ -f "$SRC" ] && ! grep -q 'CHARGE_CONTROL_END_THRESHOLD' "$SRC"; then
  python3 - "$SRC" << 'PYEOF2'
import sys
p = sys.argv[1]
s = open(p).read()

# 2a. Add property to bq2589x_charger_props[]
old_props = """static enum power_supply_property bq2589x_charger_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CHARGE_TYPE, /* Charger status output */
	POWER_SUPPLY_PROP_ONLINE, /* External power source */
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};"""
new_props = """static enum power_supply_property bq2589x_charger_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CHARGE_TYPE, /* Charger status output */
	POWER_SUPPLY_PROP_ONLINE, /* External power source */
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT,
	POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};"""
if old_props in s:
    s = s.replace(old_props, new_props, 1)

# 2b. Add get handler (before MANUFACTURER case in get_property)
old_get = """	case POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT:
		val->intval = bq->cfg.term_current;
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:"""
new_get = """	case POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT:
		val->intval = bq->cfg.term_current;
		break;
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD:
		val->intval = bq->charge_end_threshold;
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:"""
if old_get in s:
    s = s.replace(old_get, new_get, 1)

# 2c. Add set handler (before CHARGE_TERM_CURRENT case in set_property)
old_set = """	case POWER_SUPPLY_PROP_CURRENT_NOW:
		bq->chg_current = val->intval;
		ret = main_set_charge_current(bq->chg_current);
		break;
	case POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT:"""
new_set = """	case POWER_SUPPLY_PROP_CURRENT_NOW:
		bq->chg_current = val->intval;
		ret = main_set_charge_current(bq->chg_current);
		break;
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD:
		if (val->intval < 0 || val->intval > 100)
			return -EINVAL;
		bq->charge_end_threshold = val->intval;
		break;
	case POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT:"""
if old_set in s:
    s = s.replace(old_set, new_set, 1)

# 2d. Add to writeable function
old_writable = """	case POWER_SUPPLY_PROP_CHARGE_TYPE:
	case POWER_SUPPLY_PROP_ONLINE:
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		return 1;"""
new_writable = """	case POWER_SUPPLY_PROP_CHARGE_TYPE:
	case POWER_SUPPLY_PROP_ONLINE:
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
	case POWER_SUPPLY_PROP_CURRENT_NOW:
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD:
		return 1;"""
if old_writable in s:
    s = s.replace(old_writable, new_writable, 1)

# 2e. Add threshold check in monitor_workfunc, after rsoc read
old_mon = """	bq->rsoc = bq2589x_read_batt_rsoc(bq);
	bq->vbus_volt = bq2589x_adc_read_vbus_volt(bq);"""
new_mon = """	bq->rsoc = bq2589x_read_batt_rsoc(bq);

	/* Charge end threshold: stop charging at target percentage */
	if (bq->charge_end_threshold > 0 && bq->chg_dis_votable) {
		if (bq->rsoc >= bq->charge_end_threshold)
			vote(bq->chg_dis_votable, "END_THRESHOLD_VOTER", true, 1);
		else if (bq->rsoc <= bq->charge_end_threshold - 3)
			vote(bq->chg_dis_votable, "END_THRESHOLD_VOTER", false, 0);
	}

	bq->vbus_volt = bq2589x_adc_read_vbus_volt(bq);"""
if old_mon in s:
    s = s.replace(old_mon, new_mon, 1)

open(p, 'w').write(s)
PYEOF2
  echo "  apex-charge: bq2589x_charger.c CHARGE_CONTROL_END_THRESHOLD support"
fi

# ---------------------------------------------------------------------------
# 3. Clean up the old apex_charge.c module (from prior patch versions)
# ---------------------------------------------------------------------------
DST_DIR="$KERNEL/drivers/apex"
if [ -f "$DST_DIR/apex_charge.c" ]; then
  rm -f "$DST_DIR/apex_charge.c"
  echo "  apex-charge: removed old apex_charge.c module"
fi

# Remove APEX_CHARGE from Kconfig (idempotent)
if [ -f "$DST_DIR/Kconfig" ] && grep -q "config APEX_CHARGE" "$DST_DIR/Kconfig"; then
  python3 - "$DST_DIR/Kconfig" << 'PYEOF3'
import sys, re
p = sys.argv[1]
s = open(p).read()
# Remove the APEX_CHARGE config block (from 'config APEX_CHARGE' to the next
# 'config' or end of file)
s = re.sub(r'\nconfig APEX_CHARGE\b.*?(?=\nconfig |\Z)', '', s, flags=re.DOTALL)
# Clean up any leading blank lines left behind
s = s.rstrip() + '\n'
open(p, 'w').write(s)
PYEOF3
  echo "  apex-charge: removed APEX_CHARGE Kconfig entry"
fi

# Remove apex_charge from Makefile (idempotent)
if [ -f "$DST_DIR/Makefile" ] && grep -q "apex_charge" "$DST_DIR/Makefile"; then
  sed -i '/apex_charge/d' "$DST_DIR/Makefile"
  echo "  apex-charge: removed apex_charge from Makefile"
fi

echo "  apex-charge: done"
