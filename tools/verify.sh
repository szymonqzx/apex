#!/usr/bin/env bash
# tools/verify.sh — verify the apex kernel build output
# Checks: Image exists, modules exist, dtb exists, version string correct,
#          apex subsystems compiled in, KernelSU/SuSFS present,
#          defconfig consistency, Image size sanity, hardening flags
#
# Usage: ./verify.sh [--strict]
#   --strict: warnings become failures (exit 1)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
OUT="$APEX/out"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
  esac
done

PASS=0
WARN=0
FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== APEX kernel verification ==="

# 1. Kernel image
IMAGE="$OUT/arch/arm64/boot/Image"
if [ -f "$IMAGE" ]; then
  SIZE=$(du -h "$IMAGE" | cut -f1)
  SIZE_BYTES=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE" 2>/dev/null || echo 0)
  ok "Image: $IMAGE ($SIZE)"

  # Image size sanity
  if [ "$SIZE_BYTES" -gt 52428800 ]; then
    warn "Image is larger than 50MB ($SIZE) — may be over-configured"
  elif [ "$SIZE_BYTES" -lt 5242880 ] && [ "$SIZE_BYTES" -gt 0 ]; then
    warn "Image is smaller than 5MB ($SIZE) — may be under-configured"
  fi
else
  fail "Image not found: $IMAGE"
  exit 1
fi

# 2. DTB files
DTB_COUNT=$(find "$OUT/arch/arm64/boot/dts" -name "*.dtb" 2>/dev/null | wc -l)
if [ "$DTB_COUNT" -gt 0 ]; then
  ok "DTB files: $DTB_COUNT"
else
  warn "No DTB files found (expected for GKI device — ROM provides DTB)"
fi

# 3. Modules
MODULE_COUNT=$(find "$OUT" -name "*.ko" 2>/dev/null | wc -l)
echo "  [INFO] Kernel modules: $MODULE_COUNT"

# Check if pentest.config is used and no modules found
if [ -f "$APEX/defconfig/pentest.config" ] && [ "$MODULE_COUNT" -eq 0 ]; then
  warn "pentest.config present but 0 modules built — pentest drivers may not compile"
fi

# 4. Version string
VERSION=$(strings "$IMAGE" | grep -o 'Linux version [^ ]+' | head -1)
if [ -n "$VERSION" ]; then
  ok "Version: $VERSION"
else
  warn "Could not extract version string"
fi

# 5. Check for apex governor
if strings "$IMAGE" | grep -q "cpufreq_apex"; then
  ok "apex governor compiled in"
else
  warn "apex governor not found in Image (may be a module)"
fi

# 6. Check for apex state machine
if strings "$IMAGE" | grep -q "apex control plane"; then
  ok "apex state machine compiled in"
else
  warn "apex state machine not found in Image"
fi

# 7. Check for apex watchdog
if strings "$IMAGE" | grep -q "apex watchdog"; then
  ok "apex watchdog compiled in"
else
  warn "apex watchdog not found in Image"
fi

# 8. Check for apex OOM-immortal
if strings "$IMAGE" | grep -q "apex OOM-immortal"; then
  ok "apex OOM-immortal compiled in"
else
  warn "apex OOM-immortal not found in Image"
fi

# 9. Check for apex USB autoload
if strings "$IMAGE" | grep -q "apex_usb_autoload"; then
  ok "apex USB autoload compiled in"
else
  warn "apex USB autoload not found in Image (may be a module)"
fi

# 10. Check for CASS scheduler
if strings "$IMAGE" | grep -q "CASS"; then
  ok "CASS scheduler compiled in"
else
  warn "CASS scheduler not found in Image"
fi

# 11. Check for WALT
if strings "$IMAGE" | grep -q "WALT"; then
  ok "WALT load tracking compiled in"
else
  warn "WALT not found in Image"
fi

# 12. Check for KernelSU
if strings "$IMAGE" | grep -qi "kernelsu"; then
  ok "KernelSU compiled in"
else
  warn "KernelSU not found in Image"
fi

# 13. Check for SuSFS
if strings "$IMAGE" | grep -qi "susfs"; then
  ok "SuSFS compiled in"
else
  warn "SuSFS not found in Image"
fi

# 14. Check for hardening flags
if strings "$IMAGE" | grep -qi "cfi"; then
  ok "CFI hardening detected"
else
  warn "CFI not detected in Image"
fi

if strings "$IMAGE" | grep -qi "kaslr\|randomize_base"; then
  ok "KASLR detected"
else
  warn "KASLR not detected in Image"
fi

if strings "$IMAGE" | grep -qi "stackprotector\|stack_protector"; then
  ok "Stack protector detected"
else
  warn "Stack protector not detected in Image"
fi

# 15. Check for LTO
if strings "$IMAGE" | grep -qi "thinlto"; then
  ok "ThinLTO build detected"
else
  warn "ThinLTO not detected in Image (may not be compiled with LTO)"
fi

# 16. Check for WireGuard
if strings "$IMAGE" | grep -qi "wireguard"; then
  ok "WireGuard VPN compiled in"
else
  warn "WireGuard not found in Image"
fi

# 17. Check for BBR + FQ
if strings "$IMAGE" | grep -qi "bbr"; then
  ok "TCP BBR congestion control detected"
else
  warn "TCP BBR not detected"
fi

# 18. Check for MGLRU
if strings "$IMAGE" | grep -qi "lru_gen\|mglru"; then
  ok "MGLRU (Multi-Gen LRU) detected"
else
  warn "MGLRU not detected (may not be backported to CAF 5.15)"
fi

# 19. Check for KCAL
if strings "$IMAGE" | grep -qi "apex_kcal"; then
  ok "KCAL display calibration compiled in"
else
  warn "KCAL display calibration not found in Image"
fi

# 19b. Check for BLX backlight dimmer
if strings "$IMAGE" | grep -qi "apex_blx"; then
  ok "BLX backlight dimmer compiled in"
else
  warn "BLX backlight dimmer not found in Image"
fi

# 19c. Check for CPU input boost
if strings "$IMAGE" | grep -qi "apex-cpu-boost"; then
  ok "CPU input boost compiled in"
else
  warn "CPU input boost not found in Image"
fi

# 19d. Check for thermal uclamp
if strings "$IMAGE" | grep -qi "apex_thermal_uclamp"; then
  ok "Thermal uclamp cooling device compiled in"
else
  warn "Thermal uclamp not found in Image"
fi

# 19e. Check for F2FS compression
if strings "$IMAGE" | grep -qi "f2fs.*compress\|F2FS_FS_COMPRESSION"; then
  ok "F2FS compression detected"
else
  warn "F2FS compression not detected in Image"
fi

# 20. Check for exFAT
if strings "$IMAGE" | grep -qi "exfat"; then
  ok "exFAT filesystem support detected"
else
  warn "exFAT not detected in Image"
fi

# 20b. Check for WireGuard
if strings "$IMAGE" | grep -qi "wireguard"; then
  ok "WireGuard VPN detected"
else
  warn "WireGuard not detected in Image"
fi

# 20c. Check for ThinLTO
if strings "$IMAGE" | grep -qi "thinlto"; then
  ok "ThinLTO build detected"
else
  warn "ThinLTO not detected (may not be in strings)"
fi

# 20d. Check for power-efficient workqueues
if strings "$IMAGE" | grep -qi "wq_power_efficient\|power.efficient"; then
  ok "Power-efficient workqueues detected"
else
  warn "Power-efficient workqueues not detected in Image"
fi

# 21. Run check-configs.py for defconfig consistency
if [ -f "$APEX/tools/check-configs.py" ]; then
  echo ""
  echo "  --- Defconfig consistency ---"
  if python3 "$APEX/tools/check-configs.py"; then
    ok "Defconfig consistency check passed"
  else
    warn "Defconfig consistency check reported issues"
  fi
fi

# Summary
# 22. Check for three-profile system
echo ""
echo "# 22. Three-profile build system"
for pf in battery balanced performance; do
  if [ -f "$APEX/defconfig/profile-${pf}.config" ]; then
    pass "profile-${pf}.config exists"
  else
    fail "profile-${pf}.config missing"
  fi
done
if grep -q 'PROFILE=' "$APEX/tools/build-kernel.sh"; then
  pass "build-kernel.sh supports --profile"
else
  fail "build-kernel.sh missing --profile support"
fi
if grep -q 'apex_profiles.rc' "$APEX/rom-overlays/init.d/apex_profiles.rc" 2>/dev/null; then
  pass "apex_profiles.rc exists"
else
  fail "apex_profiles.rc missing"
fi

# 22b. Check for wakelock audit script
echo ""
echo "# 22b. Wakelock audit script"
if [ -f "$APEX/tools/apex-wakelock-audit.sh" ]; then
  pass "apex-wakelock-audit.sh exists"
else
  fail "apex-wakelock-audit.sh missing"
fi

# 22c. Check for GPU bus DCVS
echo ""
echo "# 22c. GPU bus/DDR DCVS scaling"
if grep -q 'apex_gpu_bus_dcvs_update' "$APEX/patches/apex-state/src/apex.c"; then
  pass "GPU bus DCVS function in apex.c"
else
  fail "GPU bus DCVS function missing"
fi

# 22d. Check for Neutron Clang support
echo ""
echo "# 22d. Neutron Clang toolchain support"
if grep -q 'NEUTRON_CLANG' "$APEX/tools/build-kernel.sh"; then
  pass "Neutron Clang support in build-kernel.sh"
else
  fail "Neutron Clang support missing"
fi

# 22e. Check for NetHunter monitor mode
echo ""
echo "# 22e. NetHunter monitor mode config"
if grep -q 'FEATURE_MONITOR_MODE_SUPPORT' "$APEX/defconfig/pentest.config"; then
  pass "CONFIG_FEATURE_MONITOR_MODE_SUPPORT in pentest.config"
else
  fail "CONFIG_FEATURE_MONITOR_MODE_SUPPORT missing"
fi

# 23. Check for APEX Charge Manager
echo ""
echo "# 23. APEX Charge Manager"
if [ -f "$APEX/patches/apex-charge/src/apex_charge.c" ]; then
  pass "apex_charge.c exists"
else
  fail "apex_charge.c missing"
fi
if [ -f "$APEX/patches/apex-charge/apply.sh" ]; then
  pass "apex-charge apply.sh exists"
else
  fail "apex-charge apply.sh missing"
fi
if [ -f "$APEX/defconfig/charging.config" ]; then
  pass "charging.config exists"
else
  fail "charging.config missing"
fi
if grep -q 'CONFIG_APEX_CHARGE=y' "$APEX/defconfig/charging.config"; then
  pass "CONFIG_APEX_CHARGE=y in charging.config"
else
  fail "CONFIG_APEX_CHARGE missing"
fi
if grep -q '5000' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "correct battery capacity (5000mAh)"
else
  fail "wrong battery capacity"
fi
if grep -q '33W\|33W\|APEX_BATT_FAST_CHG_W.*33' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "correct fast charge wattage (33W)"
else
  fail "wrong fast charge wattage"
fi
if grep -q 'PM7250B' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "correct charger IC (PM7250B)"
else
  fail "wrong charger IC"
fi
if grep -q 'input_suspend' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "input_suspend support"
else
  fail "missing input_suspend"
fi
if grep -q 'bypass_charging' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "bypass charging support"
else
  fail "missing bypass charging"
fi
if grep -q 'thermal_mitigation' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "thermal mitigation support"
else
  fail "missing thermal mitigation"
fi
if grep -q 'quick_charge_type' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "quick charge type detection"
else
  fail "missing quick charge type"
fi
if grep -q 'apex_charge_tick' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "charge tick exported"
else
  fail "missing charge tick"
fi
# Check profiles.rc has charge manager entries
if grep -q 'apex_charge' "$APEX/rom-overlays/init.d/apex_profiles.rc"; then
  pass "profiles.rc has charge manager entries"
else
  fail "profiles.rc missing charge manager"
fi
# Check apex_power.rc has charge manager init
if grep -q 'apex_charge' "$APEX/rom-overlays/init.d/apex_power.rc"; then
  pass "apex_power.rc has charge manager init"
else
  fail "apex_power.rc missing charge manager init"
fi
# Check thermald.conf has charging thermal zones
if grep -q 'charger-skin-therm' "$APEX/rom-overlays/thermald/thermald.conf"; then
  pass "thermald.conf has charger-skin-therm zone"
else
  fail "thermald.conf missing charger thermal zone"
fi

# 24. Check for SELinux charge policy
echo ""
echo "# 24. SELinux charge manager policy"
if [ -f "$APEX/rom-overlays/selinux/apex_charge.te" ]; then
  pass "apex_charge.te exists"
else
  fail "apex_charge.te missing"
fi
if grep -q 'apex_charge_proc' "$APEX/rom-overlays/selinux/apex_charge.te"; then
  pass "apex_charge_proc type defined"
else
  fail "apex_charge_proc type missing"
fi
if grep -q 'allow init' "$APEX/rom-overlays/selinux/apex_charge.te"; then
  pass "init domain allowed"
else
  fail "init domain not allowed"
fi
if grep -q 'allow system_app' "$APEX/rom-overlays/selinux/apex_charge.te"; then
  pass "system_app domain allowed"
else
  fail "system_app domain not allowed"
fi

# 25. Check health tick integration
echo ""
echo "# 25. Health tick integration"
if grep -q 'apex_charge_tick' "$APEX/patches/apex-state/src/apex.c"; then
  pass "apex.c calls apex_charge_tick()"
else
  fail "apex.c missing apex_charge_tick() call"
fi
if grep -q 'CONFIG_APEX_CHARGE' "$APEX/patches/apex-state/src/apex.c"; then
  pass "apex.c guards charge tick with #ifdef CONFIG_APEX_CHARGE"
else
  fail "apex.c missing #ifdef guard for charge tick"
fi
if grep -q 'EXPORT_SYMBOL_GPL(apex_charge_tick)' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "apex_charge_tick exported"
else
  fail "apex_charge_tick not exported"
fi

# 26. Check battery data DTSI
echo ""
echo "# 26. Battery data DTSI (5000mAh correction)"
if [ -f "$APEX/patches/device-backports/bn5m-5000mah-batterydata.dtsi" ]; then
  pass "bn5m-5000mah-batterydata.dtsi exists"
else
  fail "bn5m-5000mah-batterydata.dtsi missing"
fi
if [ -f "$APEX/patches/device-backports/batterydata-5000mah.patch" ]; then
  pass "batterydata-5000mah.patch exists"
else
  fail "batterydata-5000mah.patch missing"
fi
if grep -q 'batterydata-5000mah' "$APEX/patches/device-backports/apply.sh"; then
  pass "apply.sh includes batterydata patch"
else
  fail "apply.sh missing batterydata patch"
fi
if grep -q '5000' "$APEX/patches/device-backports/bn5m-5000mah-batterydata.dtsi"; then
  pass "DTSI has 5000mAh design capacity"
else
  fail "DTSI missing 5000mAh capacity"
fi

# 27. Check dead Kconfig symbols removed
echo ""
echo "# 27. Dead Kconfig symbols removed"
if ! grep -q 'CONFIG_APEX_CHARGE_LIMIT_BATTERY' "$APEX/defconfig/profile-battery.config"; then
  pass "CONFIG_APEX_CHARGE_LIMIT_BATTERY removed"
else
  fail "CONFIG_APEX_CHARGE_LIMIT_BATTERY still present"
fi
if ! grep -q 'CONFIG_APEX_CHARGE_LIMIT_BALANCED' "$APEX/defconfig/profile-balanced.config"; then
  pass "CONFIG_APEX_CHARGE_LIMIT_BALANCED removed"
else
  fail "CONFIG_APEX_CHARGE_LIMIT_BALANCED still present"
fi
if ! grep -q 'CONFIG_APEX_CHARGE_LIMIT_PERFORMANCE' "$APEX/defconfig/profile-performance.config"; then
  pass "CONFIG_APEX_CHARGE_LIMIT_PERFORMANCE removed"
else
  fail "CONFIG_APEX_CHARGE_LIMIT_PERFORMANCE still present"
fi

# 28. Check hvdcp_opti coexistence documented
echo ""
echo "# 28. hvdcp_opti coexistence"
if grep -q 'hvdcp_opti' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "hvdcp_opti coexistence documented in apex_charge.c"
else
  fail "hvdcp_opti coexistence not documented"
fi
if grep -q 'Do NOT disable' "$APEX/patches/apex-charge/src/apex_charge.c"; then
  pass "hvdcp_opti keep-running directive present"
else
  fail "hvdcp_opti keep-running directive missing"
fi

# 29. Check thermald.conf is reference-only
echo ""
echo "# 29. thermald.conf reference clarification"
if grep -q 'REFERENCE DOCUMENTATION ONLY' "$APEX/rom-overlays/thermald/thermald.conf"; then
  pass "thermald.conf marked as reference-only"
else
  fail "thermald.conf not marked as reference-only"
fi

# 30. Check compile-selinux.sh handles multiple .te files
echo ""
echo "# 30. compile-selinux.sh multi-policy"
if grep -q 'apex_charge.te' "$APEX/tools/compile-selinux.sh"; then
  pass "compile-selinux.sh includes apex_charge.te"
else
  fail "compile-selinux.sh missing apex_charge.te"
fi

# 31. Check dirty-modify.sh installs all .te files
echo ""
echo "# 31. dirty-modify.sh SELinux handling"
if grep -q '\*.te' "$APEX/tools/apex-dirty-modify.sh"; then
  pass "dirty-modify.sh globs all .te files"
else
  fail "dirty-modify.sh doesn't glob .te files"
fi
if grep -q 'selinux_charge_te' "$APEX/tools/apex-dirty-modify.sh"; then
  pass "dirty-modify.sh manifest has charge_te entry"
else
  fail "dirty-modify.sh manifest missing charge_te"
fi

# 32. Check AnyKernel3 installs all .te files
echo ""
echo "# 32. AnyKernel3 SELinux handling"
if grep -q '\*.te' "$APEX/anykernel3/anykernel.sh"; then
  pass "anykernel.sh globs all .te files"
else
  fail "anykernel.sh doesn't glob .te files"
fi

# 33. Check package script copies all .te files
echo ""
echo "# 33. package-anykernel3.sh SELinux handling"
if grep -q 'selinux/\*.te' "$APEX/tools/package-anykernel3.sh"; then
  pass "package-anykernel3.sh globs all .te files"
else
  fail "package-anykernel3.sh doesn't glob .te files"
fi

echo ""
echo "=== Verification complete ==="
echo "  Passed:    $PASS"
echo "  Warnings:  $WARN"
echo "  Failures:  $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
  echo "  (--strict: warnings treated as failures)"
  exit 1
fi

exit 0
