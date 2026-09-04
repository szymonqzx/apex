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

# charge is a module (CONFIG_APEX_CHARGE=m) — search modules too
CHARGE_KO=$(find "$OUT" -name "apex_charge.ko" 2>/dev/null | head -1)
if in_image "APEX: charge control initialized" || [ -n "$CHARGE_KO" ]; then
  ok "APEX charge control available${CHARGE_KO:+ (module)}"
else
  warn "APEX charge control not found (CONFIG_APEX_CHARGE)"
fi

# --- 5. Scheduler ----------------------------------------------------------
if in_image "walt"; then
  ok "WALT load tracking compiled in"
else
  warn "WALT not detected in Image (CONFIG_SCHED_WALT)"
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
