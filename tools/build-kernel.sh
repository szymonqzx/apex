#!/usr/bin/env bash
# tools/build-kernel.sh — build the APEX kernel for Redmi Note 12 4G (topaz)
#
# Base: Zepharo R9 (topnotchfreaks/kernel_msm-5.15, Linux 5.15.170)
#
# Usage: ./build-kernel.sh [--clean] [--dry-run] [--modules] [--version]
#   --clean:   force full rebuild (default: incremental)
#   --dry-run: show what would be done without executing
#   --modules: only build modules (skip Image)
#   --version: print version info and exit
#
# Profile variants are handled at runtime by rom-overlays/init.d/apex_profiles.rc
# (sysfs writes on property change) — there are no compile-time profiles.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
KERNEL="$APEX/kernel"
OUT="$APEX/out"

DEFCONFIG="apex_defconfig"
DO_CLEAN=0
DRY_RUN=0
MODULES_ONLY=0
SHOW_VERSION=0

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) DO_CLEAN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --modules) MODULES_ONLY=1 ;;
    --version) SHOW_VERSION=1 ;;
    *_defconfig) DEFCONFIG="$1" ;;
  esac
  shift
done

# --- Version info ---
APEX_VERSION="0.4.0-zepharo"
GIT_HASH="$(cd "$APEX" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

if [ "$SHOW_VERSION" -eq 1 ]; then
  echo "apex kernel build system v$APEX_VERSION"
  echo "  git:     $GIT_HASH"
  echo "  date:    $BUILD_DATE"
  echo "  target:  Redmi Note 12 4G (topaz/tapas)"
  echo "  kernel:  Linux 5.15.170 (Zepharo R9, CAF msm-5.15)"
  echo "  base:    $(cat "$KERNEL/.apex-base" 2>/dev/null | grep 'Source:' || echo 'unknown')"
  exit 0
fi

JOBS=$(nproc)

# --- Toolchain dependency checks ---
check_toolchain() {
  local missing=0
  local tools=(
    "clang"
    "ld.lld"
    "llvm-ar"
    "llvm-nm"
    "llvm-objcopy"
    "llvm-objdump"
    "llvm-strip"
    "aarch64-linux-gnu-gcc"
  )
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "  ERROR: required tool not found: $tool" >&2
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    echo "  $missing tool(s) missing. Install clang/llvm and aarch64-linux-gnu-gcc." >&2
    exit 1
  fi

  # Toolchain version gate
  local clang_ver
  clang_ver="$(clang --version 2>/dev/null | head -1 | grep -oP 'version \K[0-9]+' || echo 0)"
  if [ "$clang_ver" -lt 17 ]; then
    echo "  ERROR: clang >= 17 required (found $clang_ver)" >&2
    exit 1
  fi
  echo "  toolchain: clang $clang_ver"
}

# Neutron Clang support (optional — for Polly/LTO/PGO)
if [ -n "${NEUTRON_CLANG:-}" ] && [ -d "${NEUTRON_CLANG}/bin" ]; then
  export PATH="${NEUTRON_CLANG}/bin:$PATH"
  echo "  Using Neutron Clang: ${NEUTRON_CLANG}/bin"
fi

echo "=== APEX kernel build v$APEX_VERSION ==="
echo "  defconfig: $DEFCONFIG"
echo "  jobs:      $JOBS"
echo "  kernel:    $KERNEL"
echo "  out:       $OUT"
echo "  clean:     $DO_CLEAN"
echo "  modules:   $MODULES_ONLY"
echo "  dry-run:   $DRY_RUN"
echo "  git:       $GIT_HASH"
echo ""

if [ "$DRY_RUN" -eq 0 ]; then
  check_toolchain
fi

[ -d "$KERNEL" ] || {
  echo "kernel tree not found: $KERNEL" >&2
  exit 1
}

# --- Preflight: fast structural checks before long build ---
if [ -x "$APEX/tools/build-preflight.sh" ]; then
  if ! "$APEX/tools/build-preflight.sh" "$KERNEL"; then
    exit 1
  fi
fi

# Timer helper
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

# 1. Clean output directory
start_phase "Cleaning output directory"
if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$DO_CLEAN" -eq 1 ] || [ ! -d "$OUT" ]; then
    rm -rf "$OUT"
    mkdir -p "$OUT"
  else
    echo "    (incremental build — use --clean for full rebuild)"
  fi
fi
end_phase

# 2. Apply patches from patches/apex-new/ using the series file
start_phase "Applying APEX patches"
if [ "$DRY_RUN" -eq 0 ]; then
  if ! bash "$HERE/apply-patches.sh"; then
    echo ">>> Patch application failed. Aborting build." >&2
    exit 1
  fi
fi
end_phase

# 3. Prepare configuration.
#    The tracked apex_defconfig at defconfig/apex_defconfig is the single
#    source of truth (kernel/ is not in git — it's extracted/checked out
#    separately). Sync it into the kernel tree before configuring so a
#    clean checkout builds identically.
start_phase "Preparing configuration"

TRACKED_DEFCONFIG="$APEX/defconfig/apex_defconfig"
if [ -f "$TRACKED_DEFCONFIG" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$KERNEL/arch/arm64/configs"
    cp "$TRACKED_DEFCONFIG" "$KERNEL/arch/arm64/configs/apex_defconfig"
  fi
  echo "  synced defconfig/apex_defconfig -> kernel/arch/arm64/configs/apex_defconfig"
else
  echo "  WARNING: defconfig/apex_defconfig not found — using kernel tree copy" >&2
fi
end_phase

# 4. Configure
start_phase "Configuring kernel"
if [ "$DRY_RUN" -eq 0 ]; then
  cd "$KERNEL"
  make O="$OUT" ARCH=arm64 CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm "$DEFCONFIG"
fi
end_phase

# 5. Build
start_phase "Building kernel"
if [ "$DRY_RUN" -eq 0 ]; then
  # KCFLAGS: -march=armv8.4-a needed because KHAJE uses armv8.2-a but kernel
  # inline asm uses ARMv8.4 TLBI range instructions. clang's integrated
  # assembler uses the compiler's -march for inline asm, not -Wa,-march.
  # -Wno-error downgrades remaining clang 22 diagnostics to warnings.
  if [ "$MODULES_ONLY" -eq 1 ]; then
    echo "  (modules only — skipping Image)"
    make O="$OUT" ARCH=arm64 -j"$JOBS" \
      CROSS_COMPILE=aarch64-linux-gnu- \
      CROSS_COMPILE_COMPAT=aarch64-linux-gnu- \
      CC=clang \
      AR=llvm-ar \
      NM=llvm-nm \
      OBJCOPY=llvm-objcopy \
      OBJDUMP=llvm-objdump \
      STRIP=llvm-strip \
      LD=ld.lld \
      AS=aarch64-linux-gnu- \
      KCFLAGS="-march=armv8.4-a+crc+sha2+aes -Wno-error" \
      modules
  else
    make O="$OUT" ARCH=arm64 -j"$JOBS" \
      CROSS_COMPILE=aarch64-linux-gnu- \
      CROSS_COMPILE_COMPAT=aarch64-linux-gnu- \
      CC=clang \
      AR=llvm-ar \
      NM=llvm-nm \
      OBJCOPY=llvm-objcopy \
      OBJDUMP=llvm-objdump \
      STRIP=llvm-strip \
      LD=ld.lld \
      AS=aarch64-linux-gnu- \
      KCFLAGS="-march=armv8.4-a+crc+sha2+aes -Wno-error"
  fi
fi
end_phase

# 6. Verify output
if [ "$DRY_RUN" -eq 0 ] && [ "$MODULES_ONLY" -eq 0 ]; then
  KERNEL_IMAGE="$OUT/arch/arm64/boot/Image"

  if [ -f "$KERNEL_IMAGE" ]; then
    echo ""
    echo "=== Build successful ==="
    echo "  Image: $KERNEL_IMAGE ($(du -h "$KERNEL_IMAGE" | cut -f1))"
    # DTB listing is non-fatal (Zepharo has no topaz DTS)
    dtb_count=$(find "$OUT"/arch/arm64/boot/dts -name "*.dtb" 2>/dev/null | wc -l)
    if [ "$dtb_count" -gt 0 ]; then
      echo "  DTBs: $dtb_count"
      find "$OUT"/arch/arm64/boot/dts -name "*.dtb" 2>/dev/null | head -5
    else
      echo "  DTBs: none (expected — DTB comes from device/stock kernel)"
    fi
    echo ""
    MODULE_COUNT=$(find "$OUT" -name "*.ko" | wc -l)
    echo "  Modules: $MODULE_COUNT"
    echo ""
    echo "  Next: ./tools/package-anykernel3.sh"
  else
    echo "=== Build FAILED ==="
    exit 1
  fi
elif [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "=== Dry run complete ==="
  echo "  (No files were modified or built)"
elif [ "$MODULES_ONLY" -eq 1 ]; then
  echo ""
  echo "=== Module build complete ==="
  MODULE_COUNT=$(find "$OUT" -name "*.ko" | wc -l)
  echo "  Modules: $MODULE_COUNT"
fi
