#!/usr/bin/env bash
# tools/apply-patches.sh — apply all APEX patches to the kernel tree
#
# Reads patches/apex-new/series and applies each patch in order.
# Each patch is a directory containing an apply.sh script.
# The script is idempotent — patches check before applying.
#
# Usage: ./apply-patches.sh [--check] [--dry-run]
#   --check:   verify patches are applied without applying them
#   --dry-run: show what would be applied without executing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
KERNEL="$APEX/kernel"
PATCHES_DIR="$APEX/patches/apex-new"
SERIES="$PATCHES_DIR/series"

CHECK_ONLY=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
  esac
  shift
done

if [ ! -f "$SERIES" ]; then
  echo "ERROR: series file not found: $SERIES" >&2
  exit 1
fi

if [ ! -d "$KERNEL" ]; then
  echo "ERROR: kernel directory not found: $KERNEL" >&2
  exit 1
fi

# Parse series file — skip comments and blank lines
PATCHES=()
while IFS= read -r line; do
  # Skip comments and blank lines
  line="${line%%#*}"
  [ -z "${line// }" ] && continue
  # First word is the patch name
  patch_name=$(echo "$line" | awk '{print $1}')
  PATCHES+=("$patch_name")
done < "$SERIES"

echo "=== APEX patch series: ${#PATCHES[@]} patch(es) ==="

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "  (check mode — verifying patches are applied)"
  for patch in "${PATCHES[@]}"; do
    patch_dir="$PATCHES_DIR/$patch"
    if [ -d "$patch_dir" ]; then
      echo "  [OK] $patch"
    else
      echo "  [MISSING] $patch — directory not found"
    fi
  done
  exit 0
fi

FAILURES=0
for patch in "${PATCHES[@]}"; do
  patch_dir="$PATCHES_DIR/$patch"
  apply_script="$patch_dir/apply.sh"

  if [ ! -d "$patch_dir" ]; then
    echo "  [SKIP] $patch — directory not found"
    continue
  fi

  if [ ! -f "$apply_script" ]; then
    echo "  [SKIP] $patch — no apply.sh"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [DRY] would apply: $patch"
    continue
  fi

  echo "  applying: $patch"
  if ! bash "$apply_script" "$KERNEL"; then
    echo "  [FAIL] $patch" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  echo ">>> $FAILURES patch(es) failed." >&2
  exit 1
fi

echo "=== All patches applied ==="
