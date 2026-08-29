#!/usr/bin/env bash
# tools/autofdo-build.sh — AutoFDO profile-guided kernel build pipeline
#
# Google reports kernel accounts for 40% of CPU time on Android.
# AutoFDO uses runtime profiling to guide compiler code layout,
# producing measurable performance improvements.
#
# Workflow:
#   Phase 1: Build instrumented kernel with -fprofile-generate
#   Phase 2: Flash, boot, run workload (user does this manually)
#   Phase 3: Collect profile via perf record + create_llvm_prof
#   Phase 4: Rebuild with -fprofile-use
#
# Usage:
#   ./autofdo-build.sh phase1    # Build instrumented kernel
#   ./autofdo-build.sh phase3    # Collect profile from device
#   ./autofdo-build.sh phase4    # Rebuild with profile
#   ./autofdo-build.sh all       # Run all phases (interactive)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
KERNEL="$APEX/kernel"
OUT="$APEX/out"
OUT_INSTRUMENTED="$APEX/out-autofdo-instrumented"
OUT_OPTIMIZED="$APEX/out-autofdo-optimized"
PROFILE_DIR="$APEX/autofdo-profiles"
JOBS=$(nproc)

DEFCONFIG="chickernel_defconfig"
VARIANT="ksun"

# Parse args
PHASE="${1:-all}"
for arg in "${@:2}"; do
  case "$arg" in
    ksun|ksun.susfs) VARIANT="$arg" ;;
    *_defconfig) DEFCONFIG="$arg" ;;
  esac
done

mkdir -p "$PROFILE_DIR"

check_autofdo_deps() {
  local missing=0
  for tool in clang ld.lld llvm-profdata llvm-profgen perf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "  ERROR: required tool not found: $tool" >&2
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    echo "  $missing tool(s) missing." >&2
    echo "  Install: clang, llvm (profdata, profgen), perf, create_llvm_prof" >&2
    exit 1
  fi
}

# Phase 1: Build instrumented kernel
phase1() {
  echo "=== AutoFDO Phase 1: Build instrumented kernel ==="
  check_autofdo_deps

  rm -rf "$OUT_INSTRUMENTED"
  mkdir -p "$OUT_INSTRUMENTED"

  cd "$KERNEL"
  make O="$OUT_INSTRUMENTED" ARCH=arm64 "$DEFCONFIG"

  # Apply defconfig fragments (same as build-kernel.sh)
  FRAGMENTS=""
  for frag in "$APEX"/defconfig/*.config; do
    [ -f "$frag" ] || continue
    FRAGMENTS="$FRAGMENTS $frag"
  done
  if [ -n "$VARIANT" ] && [ -f "$KERNEL/arch/arm64/configs/chickernel-variants/$VARIANT.config" ]; then
    FRAGMENTS="$FRAGMENTS $KERNEL/arch/arm64/configs/chickernel-variants/$VARIANT.config"
  fi
  if [ -n "$FRAGMENTS" ]; then
    ./scripts/kconfig/merge_config.sh -m -r -O "$OUT_INSTRUMENTED" \
      "$OUT_INSTRUMENTED/.config" $FRAGMENTS
    make O="$OUT_INSTRUMENTED" ARCH=arm64 olddefconfig </dev/null
  fi

  # Build with profiling instrumentation
  make O="$OUT_INSTRUMENTED" ARCH=arm64 -j"$JOBS" \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC=clang AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    LD=ld.lld AS=aarch64-linux-gnu- \
    KCFLAGS="-march=armv8.4-a+crc+sha2+aes -Wno-error -fprofile-generate=$PROFILE_DIR/raw"

  echo ""
  echo "=== Phase 1 complete ==="
  echo "  Instrumented kernel: $OUT_INSTRUMENTED/arch/arm64/boot/Image"
  echo "  Profile output dir: $PROFILE_DIR/raw"
  echo ""
  echo "  Next steps:"
  echo "    1. Flash the instrumented kernel"
  echo "    2. Boot and run your typical workload for 10-30 minutes"
  echo "    3. Run: ./autofdo-build.sh phase3"
}

# Phase 3: Collect profile from device
phase3() {
  echo "=== AutoFDO Phase 3: Collect profile ==="
  echo ""
  echo "  Option A: On-device perf (requires root + perf)"
  echo "    adb shell su -c 'perf record -a -g -F 99 -o /data/perf.data -- sleep 30'"
  echo "    adb pull /data/perf.data $PROFILE_DIR/perf.data"
  echo ""
  echo "  Option B: Simple perf record (if perf not on device)"
  echo "    adb shell su -c 'cat /proc/profile > /data/profile.data'"
  echo "    adb pull /data/profile.data $PROFILE_DIR/profile.data"
  echo ""

  PERF_DATA="$PROFILE_DIR/perf.data"
  if [ ! -f "$PERF_DATA" ]; then
    echo "  ERROR: $PERF_DATA not found."
    echo "  Run perf record on device first, then pull the file."
    exit 1
  fi

  # Convert perf data to LLVM profile
  echo "  Converting perf data to LLVM profile..."
  llvm-profgen --perfdata="$PERF_DATA" \
    --binary="$OUT_INSTRUMENTED/arch/arm64/boot/Image" \
    --output="$PROFILE_DIR/autofdo.profdata"

  # Merge raw profiles if any
  if ls "$PROFILE_DIR/raw/"*.profraw 2>/dev/null 1>&2; then
    llvm-profdata merge -o "$PROFILE_DIR/merged.profdata" \
      "$PROFILE_DIR/raw/"*.profraw "$PROFILE_DIR/autofdo.profdata"
  fi

  echo ""
  echo "=== Phase 3 complete ==="
  echo "  Profile: $PROFILE_DIR/autofdo.profdata"
  echo "  Run: ./autofdo-build.sh phase4"
}

# Phase 4: Rebuild with profile
phase4() {
  echo "=== AutoFDO Phase 4: Rebuild with profile ==="

  PROFILE="$PROFILE_DIR/autofdo.profdata"
  if [ ! -f "$PROFILE" ]; then
    # Try merged profile
    PROFILE="$PROFILE_DIR/merged.profdata"
  fi
  if [ ! -f "$PROFILE" ]; then
    echo "  ERROR: No profile found in $PROFILE_DIR/"
    echo "  Run phase1 and phase3 first."
    exit 1
  fi

  rm -rf "$OUT_OPTIMIZED"
  mkdir -p "$OUT_OPTIMIZED"

  cd "$KERNEL"
  make O="$OUT_OPTIMIZED" ARCH=arm64 "$DEFCONFIG"

  # Apply defconfig fragments
  FRAGMENTS=""
  for frag in "$APEX"/defconfig/*.config; do
    [ -f "$frag" ] || continue
    FRAGMENTS="$FRAGMENTS $frag"
  done
  if [ -n "$VARIANT" ] && [ -f "$KERNEL/arch/arm64/configs/chickernel-variants/$VARIANT.config" ]; then
    FRAGMENTS="$FRAGMENTS $KERNEL/arch/arm64/configs/chickernel-variants/$VARIANT.config"
  fi
  if [ -n "$FRAGMENTS" ]; then
    ./scripts/kconfig/merge_config.sh -m -r -O "$OUT_OPTIMIZED" \
      "$OUT_OPTIMIZED/.config" $FRAGMENTS
    make O="$OUT_OPTIMIZED" ARCH=arm64 olddefconfig </dev/null
  fi

  # Build with profile-guided optimization
  make O="$OUT_OPTIMIZED" ARCH=arm64 -j"$JOBS" \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC=clang AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    LD=ld.lld AS=aarch64-linux-gnu- \
    KCFLAGS="-march=armv8.4-a+crc+sha2+aes -Wno-error -fprofile-use=$PROFILE -Wno-profile-uninstrumented"

  echo ""
  echo "=== Phase 4 complete ==="
  echo "  Optimized kernel: $OUT_OPTIMIZED/arch/arm64/boot/Image"
  echo "  Compare with baseline: $OUT/arch/arm64/boot/Image"
  echo ""
  echo "  Package: ./tools/package-anykernel3.sh"
  echo "  Use the optimized output directory."
}

case "$PHASE" in
  phase1) phase1 ;;
  phase3) phase3 ;;
  phase4) phase4 ;;
  all)
    phase1
    echo ""
    echo ">>> After flashing and running workload, run: ./autofdo-build.sh phase3"
    ;;
  *)
    echo "Usage: $0 {phase1|phase3|phase4|all}" >&2
    exit 1
    ;;
esac
