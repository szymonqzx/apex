#!/usr/bin/env bash
# tools/build-rom.sh — build the APEX ROM from LineageOS 23.2 source
#
# Produces a flashable ROM zip for topaz/tapas (Redmi Note 12 4G).
# Integrates: LineageOS 23.2 base + topaz device tree + APEX patches + APEX kernel.
#
# Usage: ./tools/build-rom.sh [--clean] [--dry-run] [--no-kernel] [--version]
#   --clean:     force full rebuild (default: incremental)
#   --dry-run:   show what would be done without executing
#   --no-kernel: skip kernel build (use pre-built Image from out/)
#   --version:   print version info and exit
#
# Prerequisites:
#   - LineageOS 23.2 source tree synced at $LOS_SOURCE (default: ~/los)
#   - topaz device tree in device/xiaomi/topaz/
#   - APEX kernel built (or use --no-kernel with pre-built Image)
#   - Android build environment (lunch, m, etc.)
#
# Brick-safety: this script NEVER touches bootloader, aboot, or partition tables.
# It only builds system, vendor, boot, and product images.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"

# Config
LOS_SOURCE="${LOS_SOURCE:-$HOME/los}"
DEVICE="${DEVICE:-topaz}"
BUILD_TYPE="${BUILD_TYPE:-userdebug}"
APEX_VERSION="1.0.0"
ROM_NAME="apex-rom"

DO_CLEAN=0
DRY_RUN=0
NO_KERNEL=0
SHOW_VERSION=0

while [ $# -gt 0 ]; do
  case "$1" in
    --clean)     DO_CLEAN=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-kernel) NO_KERNEL=1 ;;
    --version)   SHOW_VERSION=1 ;;
  esac
  shift
done

GIT_HASH="$(cd "$APEX" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
BUILD_DATE="$(date '+%Y%m%d')"

if [ "$SHOW_VERSION" -eq 1 ]; then
  echo "apex ROM build system v$APEX_VERSION"
  echo "  git:     $GIT_HASH"
  echo "  date:    $BUILD_DATE"
  echo "  device:  $DEVICE (Redmi Note 12 4G)"
  echo "  base:    LineageOS 23.2 (Android 16 QPR2)"
  echo "  kernel:  APEX kernel (Linux 5.15.211, v0.4.2)"
  exit 0
fi

echo "=== APEX ROM build v$APEX_VERSION ==="
echo "  device:   $DEVICE"
echo "  source:   $LOS_SOURCE"
echo "  type:     $BUILD_TYPE"
echo "  kernel:   $([ "$NO_KERNEL" -eq 1 ] && echo 'pre-built' || echo 'build from source')"
echo "  clean:    $DO_CLEAN"
echo "  dry-run:  $DRY_RUN"
echo "  git:      $GIT_HASH"
echo ""

# ── Preflight checks ──────────────────────────────────────────────

check_los_source() {
  if [ ! -d "$LOS_SOURCE" ] || [ ! -f "$LOS_SOURCE/build/envsetup.sh" ]; then
    echo "  ERROR: LineageOS source not found at $LOS_SOURCE" >&2
    echo "  Set LOS_SOURCE env var or sync LineageOS 23.2:" >&2
    echo "    repo init -u https://github.com/LineageOS/android.git -b lineage-23.2" >&2
    echo "    repo sync" >&2
    exit 1
  fi
  echo "  LOS source: OK"
}

check_device_tree() {
  local dev_dir="$LOS_SOURCE/device/xiaomi/topaz"
  if [ ! -d "$dev_dir" ]; then
    echo "  ERROR: topaz device tree not found at $dev_dir" >&2
    echo "  Sync the topaz device tree:" >&2
    echo "    git clone https://github.com/LineageOS/android_device_xiaomi_topaz.git $dev_dir" >&2
    exit 1
  fi
  echo "  device tree: OK"
}

check_apex_kernel() {
  local kernel_image="$APEX/out/arch/arm64/boot/Image"
  if [ ! -f "$kernel_image" ]; then
    echo "  ERROR: APEX kernel Image not found at $kernel_image" >&2
    echo "  Build the kernel first: ./tools/build-kernel.sh" >&2
    exit 1
  fi
  echo "  APEX kernel: OK ($(du -h "$kernel_image" | cut -f1))"
}

check_brick_safety() {
  if [ -x "$APEX/tools/verify-brick-safety.sh" ]; then
    if ! "$APEX/tools/verify-brick-safety.sh" "$APEX"; then
      echo "  ERROR: brick-safety verification FAILED" >&2
      exit 1
    fi
    echo "  brick-safety: PASS"
  fi
}

if [ "$DRY_RUN" -eq 0 ]; then
  check_los_source
  check_device_tree
  if [ "$NO_KERNEL" -eq 0 ]; then
    check_apex_kernel
  fi
  check_brick_safety
fi

# ── Build phases ──────────────────────────────────────────────────

phase_start=0
phase_name=""
start_phase() {
  phase_name="$1"
  phase_start=$SECONDS
  if [ "$DRY_RUN" -eq 1 ]; then
    echo ">>> [DRY RUN] $phase_name"
  else
    echo ">>> $phase_name"
  fi
}
end_phase() {
  local elapsed=$((SECONDS - phase_start))
  echo "    ($phase_name: ${elapsed}s)"
}

# Phase 1: Build APEX kernel (if not skipped)
if [ "$NO_KERNEL" -eq 0 ]; then
  start_phase "Building APEX kernel"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$APEX/tools/build-kernel.sh" ${DO_CLEAN:+--clean}
  fi
  end_phase
fi

# Phase 2: Apply APEX patches to LOS source
start_phase "Applying APEX patches"
if [ "$DRY_RUN" -eq 0 ]; then
  PATCH_DIR="$APEX/patches/apex-new"
  if [ -f "$PATCH_DIR/series" ]; then
    while IFS= read -r patch; do
      [ -z "$patch" ] && continue
      case "$patch" in \#*) continue ;; esac
      echo "  applying: $patch"
      # Patches are applied to the LOS source tree
      (cd "$LOS_SOURCE" && git apply --check "$PATCH_DIR/$patch" 2>/dev/null && git apply "$PATCH_DIR/$patch" || echo "  (already applied or skipped: $patch)")
    done < "$PATCH_DIR/series"
  fi
fi
end_phase

# Phase 3: Copy APEX overlays into LOS source
start_phase "Installing APEX overlays"
if [ "$DRY_RUN" -eq 0 ]; then
  OVERLAY_DIR="$APEX/rom-overlays"
  # build.prop append
  if [ -f "$OVERLAY_DIR/build.prop/system.build.prop.append" ]; then
    cat "$OVERLAY_DIR/build.prop/system.build.prop.append" >> \
      "$LOS_SOURCE/device/xiaomi/topaz/system.prop" 2>/dev/null || true
  fi
  # SELinux policies
  for te_file in "$OVERLAY_DIR"/selinux/*.te; do
    [ -f "$te_file" ] || continue
    cp "$te_file" "$LOS_SOURCE/system/sepolicy/vendor/" 2>/dev/null || true
  done
  # Agent sepolicy
  for te_file in "$APEX"/agent/sepolicy/*.te; do
    [ -f "$te_file" ] || continue
    cp "$te_file" "$LOS_SOURCE/system/sepolicy/vendor/" 2>/dev/null || true
  done
  # init.d scripts
  for rc_file in "$OVERLAY_DIR"/init.d/*.rc; do
    [ -f "$rc_file" ] || continue
    cp "$rc_file" "$LOS_SOURCE/device/xiaomi/topaz/init/" 2>/dev/null || true
  done
  # Update scripts
  for sh_file in "$OVERLAY_DIR"/update/*.sh; do
    [ -f "$sh_file" ] || continue
    cp "$sh_file" "$LOS_SOURCE/device/xiaomi/topaz/prebuilt/bin/" 2>/dev/null || true
  done
  echo "  overlays installed"
fi
end_phase

# Phase 4: Install APEX kernel into LOS build
start_phase "Installing APEX kernel into build tree"
if [ "$DRY_RUN" -eq 0 ]; then
  KERNEL_IMAGE="$APEX/out/arch/arm64/boot/Image"
  KERNEL_MODULES=$(find "$APEX/out" -name "*.ko" 2>/dev/null)
  TARGET_KERNEL="$LOS_SOURCE/device/xiaomi/topaz/prebuilt/kernel"
  mkdir -p "$(dirname "$TARGET_KERNEL")"
  cp "$KERNEL_IMAGE" "$TARGET_KERNEL"
  # Copy kernel modules
  for ko in $KERNEL_MODULES; do
    cp "$ko" "$LOS_SOURCE/device/xiaomi/topaz/prebuilt/modules/" 2>/dev/null || true
  done
  echo "  kernel Image + modules installed"
fi
end_phase

# Phase 5: Install agent module into LOS build
start_phase "Installing APEX agent module"
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -d "$APEX/agent" ]; then
    # Copy agent AIDL + Java sources into the LOS build
    mkdir -p "$LOS_SOURCE/vendor/apex/agent"
    cp -r "$APEX/agent/aidl" "$LOS_SOURCE/vendor/apex/agent/"
    cp -r "$APEX/agent/java" "$LOS_SOURCE/vendor/apex/agent/"
    cp -r "$APEX/agent/sepolicy" "$LOS_SOURCE/vendor/apex/agent/"
    cp "$APEX/agent/Android.bp" "$LOS_SOURCE/vendor/apex/agent/"
    # LLM JNI libraries (pre-built or built separately)
    if [ -d "$APEX/agent/llm/libllm_jni" ]; then
      cp -r "$APEX/agent/llm/libllm_jni" "$LOS_SOURCE/vendor/apex/agent/"
    fi
    echo "  agent module installed"
  fi
fi
end_phase

# Phase 6: Build ROM
start_phase "Building ROM (lunch + m)"
if [ "$DRY_RUN" -eq 0 ]; then
  cd "$LOS_SOURCE"
  # shellcheck disable=SC1091
  source build/envsetup.sh
  lunch "lineage_${DEVICE}-${BUILD_TYPE}"
  if [ "$DO_CLEAN" -eq 1 ]; then
    make clean
  fi
  m target-files-package bacon
fi
end_phase

# Phase 7: Verify output
start_phase "Verifying ROM output"
if [ "$DRY_RUN" -eq 0 ]; then
  ROM_ZIP=$(find "$LOS_SOURCE/out" -name "lineage-*.zip" -path "*target*" 2>/dev/null | head -1)
  if [ -z "$ROM_ZIP" ]; then
    ROM_ZIP=$(find "$LOS_SOURCE/out" -name "apex-*.zip" 2>/dev/null | head -1)
  fi
  if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
    echo "=== Build successful ==="
    echo "  ROM zip: $ROM_ZIP ($(du -h "$ROM_ZIP" | cut -f1))"
    echo "  device:  $DEVICE"
    echo "  version: $APEX_VERSION ($BUILD_DATE)"
    echo ""
    echo "  Next: flash via recovery (dirty-flash over existing LOS 23.2)"
  else
    echo "=== Build FAILED — no ROM zip found ==="
    exit 1
  fi
else
  echo "=== Dry run complete ==="
fi
end_phase
