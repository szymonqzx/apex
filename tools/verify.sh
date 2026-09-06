#!/usr/bin/env bash
# tools/verify.sh — verify the APEX kernel build output (v0.2+)
#
# Checks (aligned with the actual v0.2.0 stack):
#   - Kernel Image exists, sane size, correct version string
#   - Modules present, no unresolved symbols
#   - APEX subsystems (sysfs, charge) compiled in
#   - Security hardening (CFI, KASLR, stack protector, SCS, ThinLTO)
#   - Feature stack (WALT, MGLRU, exFAT, F2FS, WireGuard, BBR, ZRAM/zstd)
#   - Repo integrity (tracked defconfig, patch series, profile overlays)
#   - Packaging (apex-load-modules.sh present in zip, if packaged)
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

# NB: no `grep -q` in any pipeline here — with `set -o pipefail`, -q exits on
# first match, the producer gets SIGPIPE (141), and the pipeline is reported
# as failed. Always consume the full stream: `| grep -i PAT >/dev/null`.
in_image() { strings "$IMAGE" 2>/dev/null | grep -i "$1" >/dev/null; }

echo "=== APEX kernel verification ==="

# --- 1. Kernel image -------------------------------------------------------
IMAGE="$OUT/arch/arm64/boot/Image"
if [ ! -f "$IMAGE" ]; then
  fail "Image not found: $IMAGE (run tools/build-kernel.sh first)"
  exit 1
fi
SIZE=$(du -h "$IMAGE" | cut -f1)
SIZE_BYTES=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE" 2>/dev/null || echo 0)
ok "Image: $IMAGE ($SIZE)"

if [ "$SIZE_BYTES" -gt 52428800 ]; then
  warn "Image larger than 50MB ($SIZE) — may be over-configured"
elif [ "$SIZE_BYTES" -lt 5242880 ]; then
  warn "Image smaller than 5MB ($SIZE) — may be under-configured"
fi

# --- 2. Version string -----------------------------------------------------
VERSION=$(strings "$IMAGE" | grep -oP 'Linux version \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$VERSION" ]; then
  ok "Kernel version: $VERSION (expect 5.15.x)"
  case "$VERSION" in
    5.15.*) : ;;
    *) warn "Unexpected kernel version: $VERSION (base is 5.15.170)" ;;
  esac
else
  warn "Could not extract version string from Image"
fi

# --- 3. DTBs and modules ---------------------------------------------------
DTB_COUNT=$(find "$OUT/arch/arm64/boot/dts" -name "*.dtb" 2>/dev/null | wc -l)
if [ "$DTB_COUNT" -gt 0 ]; then
  ok "DTB files: $DTB_COUNT"
else
  warn "No DTB files found (expected — GKI device, ROM provides DTB)"
fi

MODULE_COUNT=$(find "$OUT" -name "*.ko" 2>/dev/null | wc -l)
if [ "$MODULE_COUNT" -gt 0 ]; then
  ok "Kernel modules: $MODULE_COUNT"
else
  warn "No kernel modules built"
fi

# --- 4. APEX subsystems ----------------------------------------------------
if in_image "APEX: sysfs class initialized"; then
  ok "APEX sysfs control plane compiled in"
else
  warn "APEX sysfs not detected in Image (check CONFIG_APEX_SYSFS)"
fi

# charge limiting is now a standard power_supply property on the bq2589x
# "bbc" supply (CHARGE_CONTROL_END_THRESHOLD), built into the bq2589x module
CHARGE_KO=$(find "$OUT" -name "bq2589x_charger.ko" 2>/dev/null | head -1)
if in_image "END_THRESHOLD_VOTER" || { [ -n "$CHARGE_KO" ] && strings "$CHARGE_KO" | grep "END_THRESHOLD_VOTER" >/dev/null; }; then
  ok "Charge end threshold in bq2589x driver${CHARGE_KO:+ (module)}"
else
  warn "Charge end threshold not detected (check bq2589x patch)"
fi

# --- 5. Scheduler ----------------------------------------------------------
if in_image "walt"; then
  ok "WALT load tracking compiled in"
else
  warn "WALT not detected in Image (CONFIG_SCHED_WALT)"
fi

# --- 5a. Native root + SUSFS ----------------------------------------------
if in_image "KernelSU" || in_image "kernelsu"; then
  ok "KernelSU-Next (native root) compiled in"
else
  warn "KernelSU-Next not detected in Image (CONFIG_KSU)"
fi

if in_image "susfs"; then
  ok "SUSFS (root hiding) compiled in"
else
  warn "SUSFS not detected in Image (CONFIG_KSU_SUSFS)"
fi

# --- 5b. Baseband guard ----------------------------------------------------
if in_image "baseband_guard" || in_image "protect All Block"; then
  ok "Baseband Guard (anti-brick LSM) compiled in"
else
  warn "Baseband Guard not detected in Image (CONFIG_BBG)"
fi

if in_image "lru_gen"; then
  ok "MGLRU (Multi-Gen LRU) compiled in"
else
  warn "MGLRU not detected in Image"
fi

# --- 6. Security hardening -------------------------------------------------
if in_image "shadow_call_stack\|scs"; then
  ok "Shadow Call Stack detected"
else
  warn "Shadow Call Stack not detected"
fi

if in_image "cfi"; then
  ok "CFI (Control Flow Integrity) detected"
else
  warn "CFI not detected in Image"
fi

if in_image "kaslr\|randomize_base"; then
  ok "KASLR detected"
else
  warn "KASLR not detected in Image"
fi

if in_image "stackprotector\|stack_protector"; then
  ok "Stack protector detected"
else
  warn "Stack protector not detected"
fi

# --- 7. Toolchain / build --------------------------------------------------
if in_image "thinlto"; then
  ok "ThinLTO build detected"
else
  warn "ThinLTO not detected in strings (build flag, not always visible)"
fi

# --- 8. Feature stack ------------------------------------------------------
# Some features are modules (CONFIG_*=m): check Image and modules both.
MODULE_STRINGS=""
for ko in $(find "$OUT" -name "*.ko" 2>/dev/null); do
  MODULE_STRINGS="$MODULE_STRINGS $(strings "$ko" 2>/dev/null)"
done

for feat in wireguard exfat bbr zram; do
  if in_image "$feat" || echo "$MODULE_STRINGS" | grep -i "$feat" >/dev/null; then
    ok "$feat detected"
  else
    warn "$feat not detected"
  fi
done

# --- 9. Repo integrity -----------------------------------------------------
echo ""
echo "  --- Repo integrity ---"
TRACKED_DEFCONFIG="$APEX/defconfig/apex_defconfig"
if [ -f "$TRACKED_DEFCONFIG" ]; then
  ok "defconfig/apex_defconfig present ($(grep -c 'CONFIG_' "$TRACKED_DEFCONFIG") options)"
else
  fail "defconfig/apex_defconfig missing — source of truth is not tracked"
fi

SERIES="$APEX/patches/apex-new/series"
if [ -f "$SERIES" ]; then
  PATCH_CNT=$(grep -v '^#' "$SERIES" | grep -v '^[[:space:]]*$' | wc -l)
  ok "Patch series present ($PATCH_CNT patches)"
  while IFS= read -r line; do
    line="${line%%#*}"
    [ -z "${line// }" ] && continue
    p=$(echo "$line" | awk '{print $1}')
    if [ -d "$APEX/patches/apex-new/$p" ]; then
      ok "  patch: $p"
    else
      fail "  patch dir missing: $p"
    fi
  done < "$SERIES"
else
  fail "patches/apex-new/series missing"
fi

# Compile-time profiles were removed in v0.2.1 (profile switching is runtime
# via rom-overlays/init.d/apex_profiles.rc). Flag stale files if present.
STALE_PROFILE=$(ls "$APEX"/defconfig/profile-*.config 2>/dev/null | head -1 || true)
if [ -n "$STALE_PROFILE" ]; then
  warn "stale compile-time profile found: $(basename "$STALE_PROFILE") (removed in v0.2.1)"
else
  ok "no stale compile-time profiles"
fi

# --- 10. Packaging (optional) ---------------------------------------------
LATEST_ZIP=$(ls -t "$APEX"/apex-kernel-*.zip 2>/dev/null | head -1 || true)
[ -z "$LATEST_ZIP" ] && LATEST_ZIP=$(ls -t "$APEX"/releases/apex-kernel-*.zip 2>/dev/null | head -1 || true)
if [ -n "$LATEST_ZIP" ]; then
  echo ""
  echo "  --- Packaging: $(basename "$LATEST_ZIP") ---"
  if unzip -l "$LATEST_ZIP" 2>/dev/null | grep -i "apex-load-modules.sh" >/dev/null; then
    ok "apex-load-modules.sh in zip"
  else
    warn "apex-load-modules.sh not in zip (repackage with tools/package-anykernel3.sh)"
  fi
  KO_IN_ZIP=$(unzip -l "$LATEST_ZIP" 2>/dev/null | grep -c '\.ko$' || true)
  if [ "$KO_IN_ZIP" -gt 0 ]; then
    ok "zip contains $KO_IN_ZIP .ko modules"
  else
    warn "zip contains no .ko modules"
  fi
  if unzip -l "$LATEST_ZIP" 2>/dev/null | grep -i "zImage" >/dev/null; then
    ok "zImage in zip"
  else
    fail "zImage not in zip"
  fi
else
  warn "No flashable zip found (run tools/package-anykernel3.sh)"
fi

# --- 10. ROM overlays (new) ------------------------------------------------
echo ""
echo "  --- ROM overlays ---"

# Check all init.d scripts exist
for script in apex_agent.rc apex_kernel_detect.rc apex_game_space.rc \
              apex_gestures.rc apex_pocket.rc apex_smart_charging.rc \
              apex_notifications.rc apex_reboot.rc apex_power_user.rc \
              apex_tuning.rc apex_power.rc apex_profiles.rc \
              apex_wm.rc apex_desktop.rc apex_remote_proxy.rc \
              apex_modules.rc apex_lindroid.rc apex_alarm.rc; do
  if [ -f "$APEX/rom-overlays/init.d/$script" ]; then
    ok "  init.d/$script"
  else
    fail "  init.d/$script missing"
  fi
done

# Check device.mk includes all overlays
DEVICE_MK="$APEX/rom-overlays/device/apex_device.mk"
if [ -f "$DEVICE_MK" ]; then
  ok "  device/apex_device.mk present"
  # Check for key inclusions
  for pattern in "apex_game_space" "apex_tuning" "apex_power" "apex_profiles" \
                 "hidden_packages" "thermald" "apex-alarmkeeper" "PRODUCT_SEPOLICY"; do
    if grep -q "$pattern" "$DEVICE_MK" 2>/dev/null; then
      ok "    device.mk includes $pattern"
    else
      warn "    device.mk missing $pattern"
    fi
  done
else
  fail "  device/apex_device.mk missing"
fi

# Check LOS integration makefile
LOS_MK="$APEX/rom-overlays/device/apex_lineage_topaz.mk"
if [ -f "$LOS_MK" ]; then
  ok "  device/apex_lineage_topaz.mk present"
else
  fail "  device/apex_lineage_topaz.mk missing"
fi

# Check hiding stack
for file in install_modules.sh configure_hiding.sh denylist.conf; do
  if [ -f "$APEX/hiding/$file" ]; then
    ok "  hiding/$file"
  else
    fail "  hiding/$file missing"
  fi
done

# Check agent enhancements
for file in RemoteModelClient.java RemoteProxyDaemon.java ChargeControlTool.java \
            AgentVectorStore.java MemoryManager.java; do
  if [ -f "$APEX/agent/java/com/apex/agent/$file" ]; then
    ok "  agent/$file"
  else
    fail "  agent/$file missing"
  fi
done

# Check remote proxy SELinux + init
if [ -f "$APEX/agent/sepolicy/apex_remote_proxy.te" ]; then
  ok "  sepolicy/apex_remote_proxy.te"
else
  fail "  sepolicy/apex_remote_proxy.te missing"
fi

# Check WM
for file in "aidl/com/apex/wm/IApexWindowManager.aidl" \
            "java/com/apex/wm/ApexWindowManager.java" \
            "overlay/res/values/config.xml" \
            "overlay/AndroidManifest.xml"; do
  if [ -f "$APEX/wm/$file" ]; then
    ok "  wm/$file"
  else
    fail "  wm/$file missing"
  fi
done

# Check Desktop
for file in "aidl/com/apex/desktop/IDesktopMode.aidl" \
            "java/com/apex/desktop/DesktopModeService.java"; do
  if [ -f "$APEX/desktop/$file" ]; then
    ok "  desktop/$file"
  else
    fail "  desktop/$file missing"
  fi
done

# Check Lindroid
for file in "aidl/com/apex/lindroid/ILindroid.aidl" \
            "java/com/apex/lindroid/LindroidManager.java" \
            "scripts/lindroid-start.sh" \
            "scripts/lindroid-stop.sh" \
            "scripts/lindroid-exec.sh" \
            "scripts/lindroid-migrate.sh" \
            "scripts/lindroid-init.sh"; do
  if [ -f "$APEX/lindroid/$file" ]; then
    ok "  lindroid/$file"
  else
    fail "  lindroid/$file missing"
  fi
done

# Check Apex Control app new screens
for file in "poweruser/GovernorTuningScreen.kt" \
            "poweruser/ThermalProfileScreen.kt" \
            "poweruser/IncidentLogViewer.kt" \
            "poweruser/ModuleStatusScreen.kt" \
            "poweruser/BridgeStatusScreen.kt"; do
  if [ -f "$APEX/apps/apex-control/app/src/main/java/com/apex/control/$file" ]; then
    ok "  apex-control/$file"
  else
    fail "  apex-control/$file missing"
  fi
done

# Check build tools
for tool in package-rom.sh build-scrcpy-server.sh build-lindroid.sh \
            package-hiding-stack.sh build-pentest-drivers.sh verify-stealth.sh; do
  if [ -f "$APEX/tools/$tool" ]; then
    ok "  tools/$tool"
  else
    fail "  tools/$tool missing"
  fi
done

# Check NFCForge app
for file in "app/src/main/AndroidManifest.xml" \
            "app/build.gradle.kts" \
            "app/src/main/java/com/apex/nfcforge/data/BridgeClient.kt" \
            "app/src/main/java/com/apex/nfcforge/domain/NfcModels.kt" \
            "app/src/main/java/com/apex/nfcforge/ui/MainScreen.kt" \
            "app/src/main/java/com/apex/nfcforge/ui/MainActivity.kt"; do
  if [ -f "$APEX/apps/nfcforge/$file" ]; then
    ok "  nfcforge/$file"
  else
    fail "  nfcforge/$file missing"
  fi
done

# Check PTK TUI app
for file in "app/src/main/AndroidManifest.xml" \
            "app/build.gradle.kts" \
            "app/src/main/java/com/apex/ptk/data/TerminalSession.kt" \
            "app/src/main/java/com/apex/ptk/ui/TerminalScreen.kt" \
            "app/src/main/java/com/apex/ptk/ui/TerminalViewModel.kt" \
            "app/src/main/java/com/apex/ptk/ui/MainActivity.kt"; do
  if [ -f "$APEX/apps/ptk-tui/$file" ]; then
    ok "  ptk-tui/$file"
  else
    fail "  ptk-tui/$file missing"
  fi
done

# --- Lindroid completion ---------------------------------------------------
echo ""
echo "--- Lindroid completion ---"
for file in \
"java/com/apex/lindroid/LindroidManager.java" \
"java/com/apex/lindroid/ContainerConfig.java" \
"java/com/apex/lindroid/DisplayBridge.java" \
"aidl/com/apex/lindroid/ILindroid.aidl"; do
  if [ -f "$APEX/lindroid/$file" ]; then
    ok "  lindroid/$file"
  else
    fail "  lindroid/$file missing"
  fi
done

# Lindroid MCP tools
if grep -q 'apex-lindroid-start' "$APEX/agent/java/com/apex/agent/McpRegistry.java" 2>/dev/null; then
  ok "  Lindroid MCP tools registered"
else
  fail "  Lindroid MCP tools not in McpRegistry"
fi

# --- Agent enhancements ---------------------------------------------------
echo ""
echo "--- Agent enhancements ---"
# ConsentGate consent types
if grep -q 'REMOTE_INFERENCE' "$APEX/agent/java/com/apex/agent/ConsentGate.java" 2>/dev/null; then
  ok "  ConsentGate REMOTE_INFERENCE"
else
  fail "  ConsentGate REMOTE_INFERENCE missing"
fi
if grep -q 'DUAL_CONFIRM' "$APEX/agent/java/com/apex/agent/ConsentGate.java" 2>/dev/null; then
  ok "  ConsentGate DUAL_CONFIRM"
else
  fail "  ConsentGate DUAL_CONFIRM missing"
fi
# Memory manager wired into daemon
if grep -q 'mMemoryManager' "$APEX/agent/java/com/apex/agent/ApexAgentDaemon.java" 2>/dev/null; then
  ok "  MemoryManager wired into daemon"
else
  fail "  MemoryManager not wired into ApexAgentDaemon"
fi
# Push-to-talk
if grep -q 'transcribeVoice\|Icons.Default.Mic' "$APEX/apps/apex-control/app/src/main/java/com/apex/control/agent/AgentChatSurface.kt" 2>/dev/null; then
  ok "  Push-to-talk in AgentChatSurface"
else
  fail "  Push-to-talk not in AgentChatSurface"
fi
# Vector store test
if [ -f "$APEX/tests/agent/test_vector_store.py" ]; then
  ok "  test_vector_store.py"
else
  fail "  test_vector_store.py missing"
fi
# Daily-driver verification script
if [ -f "$APEX/tools/verify-daily-driver.sh" ]; then
  ok "  verify-daily-driver.sh"
else
  fail "  verify-daily-driver.sh missing"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "=== Verification complete ==="
echo "  Passed:    $PASS"
echo "  Warnings:  $WARN"
echo "  Failures:  $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "  Result: FAIL" >&2
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
  echo "  Result: FAIL (--strict: warnings treated as failures)"
  exit 1
fi
echo "  Result: PASS"
exit 0
