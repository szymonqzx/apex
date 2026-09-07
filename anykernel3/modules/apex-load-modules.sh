#!/system/bin/sh
# apex-load-modules.sh — ordered module loading for APEX kernel
# Called from init.rc on boot to load critical modules in order.
# Remaining modules are loaded by the ROM's init system via modprobe.

MOD_PATH="/vendor/lib/modules"
LOG_TAG="apex-modules"

# Critical modules that must load early and in order
CRITICAL_ORDER="
sched_walt
mi_thermal_interface
tcpm
bq2589x_charger
sc8551_charger
fg_sm5602
ln8000_charger
nopmi_charger
tcpc_rt1711h
charger_pd_policy
dual_role_usb_intf
onewire_gpio
batt_verify_ds28e16
ant_check
ant_check_div
apex_charge
"

load_module() {
  local mod="$1"
  local ko_file

  # Try modprobe first (uses modules.dep for dependency resolution)
  if modprobe "$mod" 2>/dev/null; then
    setprop sys.apex.modules.loaded "$mod" 2>/dev/null
    return 0
  fi

  # Fallback: direct insmod
  ko_file=$(find "$MOD_PATH" -name "${mod}.ko" 2>/dev/null | head -1)
  if [ -n "$ko_file" ] && [ -f "$ko_file" ]; then
    insmod "$ko_file" 2>/dev/null && return 0
  fi

  return 1
}

# Load critical modules in order
LOADED=0
FAILED=0
for mod in $CRITICAL_ORDER; do
  if load_module "$mod"; then
    LOADED=$((LOADED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

# Load remaining modules via modprobe (uses modules.dep for ordering)
for ko in "$MOD_PATH"/*.ko; do
  [ -f "$ko" ] || continue
  modname=$(basename "$ko" .ko)
  # Skip already-loaded modules
  if grep -q "^${modname} " /proc/modules 2>/dev/null; then
    continue
  fi
  modprobe "$modname" 2>/dev/null || insmod "$ko" 2>/dev/null
done

setprop sys.apex.modules.status "loaded:${LOADED}:failed:${FAILED}" 2>/dev/null
