#!/usr/bin/env bash
# patches/device-backports/apply.sh — apply all device-specific backport patches.
# Idempotent: uses git apply --check first, skips already-applied patches.
# Note: Most device-backport patches are already present in the ChicKernel base tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

[ -d "$KERNEL/.git" ] || {
  echo "kernel tree must be a git repo: $KERNEL" >&2
  exit 1
}

# Patches that are already in the ChicKernel base tree — skip silently
ALREADY_IN_BASE=(
  "sm5602-fuelgauge.patch"      # EPROBE_DEFER already in sm5602_fg.c
  "dwc3-msm-core.patch"         # EPROBE_DEFER already in dwc3-msm-core.c
  "mi-thermald-wrong-core.patch" # found+pr_debug already in mi_thermal_interface.c
  "usb-tether-panic.patch"      # NULL check already in udc/core.c
  "kmsg-spam-suppress.patch"    # pr_dbg already in qcom_glink_native.c
  "batterydata-5000mah.patch"   # Target DTSI not in GKI tree (N/A)
)

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

  # Check if already in base tree
  already=0
  for base_patch in "${ALREADY_IN_BASE[@]}"; do
    if [ "$patch" = "$base_patch" ]; then
      echo "already in base tree: $patch"
      already=1
      break
    fi
  done
  [ "$already" -eq 1 ] && continue

  if git -C "$KERNEL" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$KERNEL" apply "$PATCH_FILE"
    echo "applied: $patch"
  else
    # Check if already applied via git log
    if git -C "$KERNEL" log --oneline -30 | grep -qi "sched_param"; then
      echo "already applied: $patch"
    else
      echo "FAILED to apply: $patch (may need manual resolution)"
    fi
  fi
done

echo "device backports: done"
