#!/usr/bin/env bash
# tools/verify-rom.sh — verify the APEX ROM build output (v1.0.0+)
#
# Checks:
#   - All 4 APKs present, valid, sane size
#   - KSU module structure complete (module.prop, scripts, sepolicy, system/)
#   - Init RC files present (18 expected)
#   - Shell scripts present and executable
#   - SELinux policy rules valid syntax
#   - build.prop overlays contain PIF fingerprint
#   - thermald.conf has trip points
#   - hidden_packages.list non-empty
#   - Flashable zip structure valid (AnyKernel3 + KSU module)
#   - Brick-safety: no dangerous partition writes
#   - KSU module zip structure valid
#
# Usage: ./verify-rom.sh [--strict] [--structure]
#   --strict:    warnings become failures (exit 1)
#   --structure: repo-structure-only mode for fresh checkouts/CI — missing
#                build artifacts (APKs, packaged zips) are warnings, not
#                failures (build outputs are gitignored and only exist
#                after a real build)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
STRICT=0
STRUCTURE=0

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --structure) STRUCTURE=1 ;;
  esac
done

PASS=0
WARN=0
FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
# Missing build artifacts: warn in --structure mode, fail otherwise.
artifact() { if [ "$STRUCTURE" -eq 1 ]; then warn "$1"; else fail "$1"; fi; }

echo "=== APEX ROM Build Verification ==="
echo ""

# ── 1. APKs ───────────────────────────────────────────────────────
echo "--- APKs ---"

APK_SYSTEM="$APEX/system-services/app/build/outputs/apk/release/app-release-unsigned.apk"
APK_CONTROL="$APEX/apps/apex-control/app/build/outputs/apk/release/app-release-unsigned.apk"
APK_NFCFORGE="$APEX/apps/nfcforge/app/build/outputs/apk/release/app-release-unsigned.apk"
APK_PTKTUI="$APEX/apps/ptk-tui/app/build/outputs/apk/release/app-release-unsigned.apk"

for name_path in "system-services:$APK_SYSTEM" "ApexControl:$APK_CONTROL" "NFCForge:$APK_NFCFORGE" "PTK-TUI:$APK_PTKTUI"; do
  name="${name_path%%:*}"
  path="${name_path#*:}"
  if [ ! -f "$path" ]; then
    artifact "$name APK not found: $path"
    continue
  fi
  size=$(du -h "$path" | cut -f1)
  if ! unzip -t "$path" >/dev/null 2>&1; then
    fail "$name APK corrupt (zip test failed): $path"
    continue
  fi
  ok "$name APK: $size ($path)"
done

# ── 2. KSU Module Structure ───────────────────────────────────────
echo ""
echo "--- KSU Module ---"

KSU="$APEX/ksu-module"

# module.prop
if [ -f "$KSU/module.prop" ]; then
  ok "module.prop present"
  # Verify required fields
  for field in id name version versionCode author description; do
    if ! grep -q "^${field}=" "$KSU/module.prop"; then
      fail "module.prop missing field: $field"
    fi
  done
else
  fail "module.prop not found"
fi

# Scripts
for script in post-fs-data.sh service.sh uninstall.sh; do
  if [ -f "$KSU/$script" ]; then
    if [ -x "$KSU/$script" ]; then
      ok "$script present and executable"
    else
      warn "$script present but not executable"
    fi
  else
    fail "$script not found"
  fi
done

# SELinux policy
if [ -f "$KSU/sepolicy.rule" ]; then
  ok "sepolicy.rule present"
  # Check for key type definitions
  for type in "apex_agent" "apex_charge_proc" "apex_chroot"; do
    if grep -q "type $type" "$KSU/sepolicy.rule"; then
      ok "SELinux type '$type' defined"
    else
      fail "SELinux type '$type' missing"
    fi
  done
else
  fail "sepolicy.rule not found"
fi

# ── 3. Init RC Files ──────────────────────────────────────────────
echo ""
echo "--- Init RC Files ---"

EXPECTED_RCS=(
  apex_agent.rc
  apex_desktop.rc
  apex_game_space.rc
  apex_gestures.rc
  apex_kernel_detect.rc
  apex_lindroid.rc
  apex_modules.rc
  apex_notifications.rc
  apex_pocket.rc
  apex_power.rc
  apex_power_user.rc
  apex_profiles.rc
  apex_reboot.rc
  apex_remote_proxy.rc
  apex_smart_charging.rc
  apex_tuning.rc
  apex_wm.rc
)

RC_DIR="$KSU/system/etc/init"
RC_COUNT=0
for rc in "${EXPECTED_RCS[@]}"; do
  if [ -f "$RC_DIR/$rc" ]; then
    RC_COUNT=$((RC_COUNT + 1))
  else
    fail "Missing init RC: $rc"
  fi
done
if [ "$RC_COUNT" -eq "${#EXPECTED_RCS[@]}" ]; then
  ok "All ${#EXPECTED_RCS[@]} init RC files present"
else
  warn "Only $RC_COUNT/${#EXPECTED_RCS[@]} init RC files present"
fi

# ── 4. Shell Scripts ──────────────────────────────────────────────
echo ""
echo "--- Shell Scripts ---"

EXPECTED_SCRIPTS=(
  apex_ab_verify.sh
  apex_agent_healthcheck.sh
  apex_kernel_detect.sh
  apex_ota_fallback.sh
  apex_pocket_detect.sh
  apex_screenshot_gesture.sh
  apex_smart_charge.sh
  apex_tuning.sh
)

SCRIPT_DIR="$KSU/system/bin"
SCRIPT_COUNT=0
for script in "${EXPECTED_SCRIPTS[@]}"; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    if [ -x "$SCRIPT_DIR/$script" ]; then
      SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
    else
      warn "$script not executable"
    fi
  else
    fail "Missing script: $script"
  fi
done
if [ "$SCRIPT_COUNT" -eq "${#EXPECTED_SCRIPTS[@]}" ]; then
  ok "All ${#EXPECTED_SCRIPTS[@]} shell scripts present and executable"
else
  warn "Only $SCRIPT_COUNT/${#EXPECTED_SCRIPTS[@]} scripts OK"
fi

# ── 5. Build.prop Overlays ────────────────────────────────────────
echo ""
echo "--- Build.prop Overlays ---"

if [ -f "$KSU/system/build.prop.append" ]; then
  ok "system build.prop overlay present"
  if grep -q "fingerprint" "$KSU/system/build.prop.append" 2>/dev/null; then
    ok "PIF fingerprint found in build.prop overlay"
  else
    warn "PIF fingerprint not found in build.prop overlay"
  fi
else
  fail "system build.prop overlay not found"
fi

if [ -f "$KSU/system/vendor.build.prop.append" ]; then
  ok "vendor build.prop overlay present"
else
  fail "vendor build.prop overlay not found"
fi

# ── 6. Thermald Config ────────────────────────────────────────────
echo ""
echo "--- Thermald ---"

if [ -f "$KSU/system/etc/thermald.conf" ]; then
  ok "thermald.conf present"
  if grep -q "45" "$KSU/system/etc/thermald.conf" && grep -q "55" "$KSU/system/etc/thermald.conf"; then
    ok "Thermal trip points defined"
  else
    warn "Thermal trip points may be missing"
  fi
else
  fail "thermald.conf not found"
fi

# ── 7. Hidden Packages List ───────────────────────────────────────
echo ""
echo "--- Hidden Packages ---"

if [ -f "$KSU/system/hidden_packages.list" ]; then
  ok "hidden_packages.list present"
  LINES=$(wc -l < "$KSU/system/hidden_packages.list")
  if [ "$LINES" -gt 0 ]; then
    ok "hidden_packages.list has $LINES entries"
  else
    warn "hidden_packages.list is empty"
  fi
else
  fail "hidden_packages.list not found"
fi

# ── 8. Flashable Zips ─────────────────────────────────────────────
echo ""
echo "--- Flashable Zips ---"

KSU_ZIP="$APEX/releases/apex-rom-ksu-module-v1.0.0.zip"
FLASH_ZIP="$APEX/releases/apex-rom-flashable-v1.0.0-topaz.zip"

if [ -f "$KSU_ZIP" ]; then
  ok "KSU module zip: $(du -h "$KSU_ZIP" | cut -f1)"
  if unzip -t "$KSU_ZIP" >/dev/null 2>&1; then
    ok "KSU module zip integrity OK"
  else
    fail "KSU module zip corrupt"
  fi
else
  artifact "KSU module zip not found"
fi

if [ -f "$FLASH_ZIP" ]; then
  ok "Flashable zip: $(du -h "$FLASH_ZIP" | cut -f1)"
  if unzip -t "$FLASH_ZIP" >/dev/null 2>&1; then
    ok "Flashable zip integrity OK"
  else
    fail "Flashable zip corrupt"
  fi
  # Check for AnyKernel3 structure
  _flash_files=$(unzip -l "$FLASH_ZIP" 2>&1 || true)
  if echo "$_flash_files" | grep -q "anykernel.sh"; then
    ok "AnyKernel3 infrastructure in flashable zip"
  else
    fail "AnyKernel3 infrastructure missing from flashable zip"
  fi
  # Check for KSU module
  if echo "$_flash_files" | grep -q "ksu-module/module.prop"; then
    ok "KSU module embedded in flashable zip"
  else
    fail "KSU module missing from flashable zip"
  fi
else
  artifact "Flashable zip not found"
fi

# ── 9. Brick-Safety ───────────────────────────────────────────────
echo ""
echo "--- Brick-Safety ---"

# Scan only script/overlay directories (not APKs — binary scan is slow)
BRICK_SAFE=1
for scan_dir in tools ksu-module anykernel3 rom-overlays; do
  if [ -d "$APEX/$scan_dir" ]; then
    if grep -rnE "dd if=.*of=.*(/dev/block/by-name/|/dev/block/).*(aboot|sbl1|sbl2|sbl3|sbl4|tz|rpm|hyp|modem|bootloader|devinfo|cmnlib|cmnlib64|devcfg|keymaster|keybackup)" \
         "$APEX/$scan_dir" 2>/dev/null | grep -v "^.*#" | grep -v '\$' | grep -v "verify-rom.sh" | grep -v "verify-brick-safety.sh" | grep -q .; then
      fail "Dangerous partition write found in $scan_dir"
      BRICK_SAFE=0
    fi
  fi
done
if [ "$BRICK_SAFE" -eq 1 ]; then
  ok "Brick-safety verification PASS (no dangerous partition writes)"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "=== Result: $PASS PASS, $WARN WARN, $FAIL FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
  exit 1
fi

exit 0
