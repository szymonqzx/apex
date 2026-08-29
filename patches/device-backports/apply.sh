#!/usr/bin/env bash
# patches/device-backports/apply.sh — apply all device-specific backport patches.
# Idempotent: uses git apply --check first, skips already-applied patches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

[ -d "$KERNEL/.git" ] || {
  echo "kernel tree must be a git repo: $KERNEL" >&2
  exit 1
}

PATCHES=(
  "sm5602-fuelgauge.patch"
  "dwc3-msm-core.patch"
  "mi-thermald-wrong-core.patch"
  "usb-tether-panic.patch"
  "kmsg-spam-suppress.patch"
  "batterydata-5000mah.patch"
  "sched-param-redef.patch"
)

for patch in "${PATCHES[@]}"; do
  PATCH_FILE="$HERE/$patch"
  [ -f "$PATCH_FILE" ] || {
    echo "missing patch: $PATCH_FILE" >&2
    continue
  }

  if git -C "$KERNEL" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$KERNEL" apply "$PATCH_FILE"
    echo "applied: $patch"
  else
    # Check if already applied by looking for the APEX marker
    if git -C "$KERNEL" log --oneline -20 | grep -q "$patch"; then
      echo "already applied: $patch"
    else
      echo "FAILED to apply: $patch (may need manual resolution)"
      # Don't exit — try the rest
    fi
  fi
done

echo "device backports: done"
