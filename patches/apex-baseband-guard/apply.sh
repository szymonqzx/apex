#!/usr/bin/env bash
# patches/apex-baseband-guard/apply.sh — apply baseband guard efisp exploit patches.
# Idempotent: uses git apply --check first, skips already-applied patches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

[ -d "$KERNEL/.git" ] || {
  echo "kernel tree must be a git repo: $KERNEL" >&2
  exit 1
}

# BBG patches target the Baseband-guard submodule (paths prefixed with Baseband-guard/).
# Apply with -p2 to strip the leading directory component.
BBG_DIR="$KERNEL/Baseband-guard"

[ -d "$BBG_DIR" ] || {
  echo "Baseband-guard directory not found: $BBG_DIR" >&2
  exit 1
}

# Patches that apply inside the BBG submodule (use -p2 to strip Baseband-guard/ prefix)
BBG_PATCHES=(
  "bbg-kconfig-recovery.patch"
  "bbg-efisp-exploit.patch"
)

# Patches that apply to the apex repo root (anykernel3 installer)
ROOT_PATCHES=(
  "anykernel-bbg-efisp-menu.patch"
)

for patch in "${BBG_PATCHES[@]}"; do
  PATCH_FILE="$HERE/$patch"
  [ -f "$PATCH_FILE" ] || {
    echo "missing patch: $PATCH_FILE" >&2
    continue
  }

  if git -C "$BBG_DIR" apply --check -p2 "$PATCH_FILE" 2>/dev/null; then
    git -C "$BBG_DIR" apply -p2 "$PATCH_FILE"
    echo "applied: $patch"
  else
    # Check if already applied by looking for a unique marker
    if grep -q 'allowlist_names_efisp_exploit' "$BBG_DIR/baseband_guard.c" 2>/dev/null; then
      echo "already applied: $patch"
    else
      echo "FAILED to apply: $patch (may need manual resolution)"
    fi
  fi
done

for patch in "${ROOT_PATCHES[@]}"; do
  PATCH_FILE="$HERE/$patch"
  [ -f "$PATCH_FILE" ] || {
    echo "missing patch: $PATCH_FILE" >&2
    continue
  }

  if git -C "$KERNEL/.." apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$KERNEL/.." apply "$PATCH_FILE"
    echo "applied: $patch"
  else
    # Check if already applied
    if grep -q 'oplusboot.secure_user_mode' "$KERNEL/../anykernel3/anykernel.sh" 2>/dev/null; then
      echo "already applied: $patch"
    else
      echo "FAILED to apply: $patch (may need manual resolution)"
    fi
  fi
done

echo "baseband guard patches: done"
