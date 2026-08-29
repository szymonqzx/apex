#!/usr/bin/env bash
# tools/compile-selinux.sh — compile SELinux .te policies to sepolicy.rule
#
# Compiles all APEX .te policy files into KernelSU-Next-compatible
# sepolicy.rule binaries that can be shipped in the AnyKernel3 zip and
# loaded by KernelSU-Next's sepolicy injection mechanism.
#
# Policy files:
#   apex_chown.te  — chroot raw-HW domain (binder, NFC, USB, sensors)
#   apex_charge.te — charge manager procfs access (init, system_app, shell)
#
# Usage: ./compile-selinux.sh [--dry-run]
#
# Requires: sepolicy-inject (from libselinux) or magiskpolicy
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"

SELINUX_DIR="$APEX/rom-overlays/selinux"
OUTPUT_DIR="$APEX/anykernel3/apex"

# All .te policy files to compile
TE_FILES=(
  "$SELINUX_DIR/apex_chown.te"
  "$SELINUX_DIR/apex_charge.te"
)

DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

echo "=== APEX SELinux policy compiler ==="
echo "  policies: ${#TE_FILES[@]}"
echo "  output:   $OUTPUT_DIR/"
echo ""

# Verify all source files exist
for te in "${TE_FILES[@]}"; do
  if [ ! -f "$te" ]; then
    echo "ERROR: SELinux policy source not found: $te" >&2
    exit 1
  fi
  echo "  source: $(basename "$te")"
done
echo ""

# Check for available policy compilers
POLICY_COMPILER=""

# Try sepolicy-inject (from AOSP build or libselinux)
if command -v sepolicy-inject >/dev/null 2>&1; then
  POLICY_COMPILER="sepolicy-inject"
# Try magiskpolicy (from Magisk)
elif command -v magiskpolicy >/dev/null 2>&1; then
  POLICY_COMPILER="magiskpolicy"
# Try ksud (KernelSU-Next manager)
elif command -v ksud >/dev/null 2>&1; then
  POLICY_COMPILER="ksud"
fi

if [ -z "$POLICY_COMPILER" ]; then
  echo "WARNING: No SELinux policy compiler found (sepolicy-inject, magiskpolicy, ksud)"
  echo "  The .te files will be shipped as-is for on-device compilation."
  echo "  KernelSU-Next can compile .te files at install time via its"
  echo "  sepolicy.rule mechanism."
  echo ""

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$OUTPUT_DIR"
    for te in "${TE_FILES[@]}"; do
      base="$(basename "$te" .te)"
      out="$OUTPUT_DIR/${base}.sepolicy.rule"
      cp "$te" "$out"
      echo "  Copied $(basename "$te") → $out"
    done
  else
    echo "  [DRY RUN] Would copy .te policies to $OUTPUT_DIR/"
  fi
  exit 0
fi

echo "  compiler: $POLICY_COMPILER"
echo ""

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$OUTPUT_DIR"

  for te in "${TE_FILES[@]}"; do
    base="$(basename "$te" .te)"
    out="$OUTPUT_DIR/${base}.sepolicy.rule"

    case "$POLICY_COMPILER" in
      sepolicy-inject)
        "$POLICY_COMPILER" -t "$te" -o "$out" 2>/dev/null || {
          echo "  WARNING: sepolicy-inject failed for $base, falling back to text format"
          cp "$te" "$out"
        }
        ;;
      magiskpolicy)
        "$POLICY_COMPILER" --apply "$te" -o "$out" 2>/dev/null || {
          echo "  WARNING: magiskpolicy failed for $base, falling back to text format"
          cp "$te" "$out"
        }
        ;;
      ksud)
        cp "$te" "$out"
        echo "  (ksud uses text-format .te — copied as-is)"
        ;;
    esac

    echo "  Compiled: $(basename "$te") → $out ($(du -h "$out" | cut -f1))"
  done
else
  echo "  [DRY RUN] Would compile ${#TE_FILES[@]} policies with $POLICY_COMPILER"
fi

echo ""
echo "=== SELinux policy compilation complete ==="
