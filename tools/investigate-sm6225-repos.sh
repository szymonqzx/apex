#!/usr/bin/env bash
# tools/investigate-sm6225-repos.sh — diff xiaomi-6225-AD org repos
# against the ChicKernel tree to identify device-specific backports.
#
# Clones the xiaomi-6225-AD organization repos and diffs key files
# against the local kernel tree to find fixes not in ChicKernel.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
KERNEL="$APEX/kernel"
WORKDIR="${1:-/tmp/apex-sm6225-investigate}"

ORG="https://github.com/xiaomi-6225-AD"

echo "=== APEX SM6225-AD Repository Investigation ==="
echo "  workdir: $WORKDIR"
echo ""

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Repos to investigate
declare -A REPOS=(
  ["android_kernel_xiaomi_sm6225-modules"]="kernel/drivers/staging/qcom/  modules"
  ["android_kernel_xiaomi_sm6225-devicetrees"]="arch/arm64/boot/dts/qcom/  devicetrees"
  ["device_qcom_sepolicy_vndr"]="sepolicy  sepolicy"
)

for repo in "${!REPOS[@]}"; do
  echo ">>> Cloning $repo..."
  if [ ! -d "$repo" ]; then
    git clone --depth=1 "$ORG/$repo.git" "$repo" 2>/dev/null || {
      echo "    SKIP: could not clone $repo (may be private or WIP)"
      continue
    }
  fi
  echo "    cloned: $(ls "$repo" 2>/dev/null | head -5 | tr '\n' ' ')"
done

echo ""
echo "=== Diff Analysis ==="

# Compare device trees
if [ -d "android_kernel_xiaomi_sm6225-devicetrees" ]; then
  echo ""
  echo "--- Device Trees ---"
  # Find topaz/tapas DTS files
  find "android_kernel_xiaomi_sm6225-devicetrees" -name '*topaz*' -o -name '*tapas*' -o -name '*bengal*' 2>/dev/null | head -20
fi

# Compare sepolicy
if [ -d "device_qcom_sepolicy_vndr" ]; then
  echo ""
  echo "--- SELinux Policy ---"
  find "device_qcom_sepolicy_vndr" -name '*.te' -path '*bengal*' 2>/dev/null | head -20
fi

# Compare kernel modules
if [ -d "android_kernel_xiaomi_sm6225-modules" ]; then
  echo ""
  echo "--- Kernel Modules ---"
  find "android_kernel_xiaomi_sm6225-modules" -name '*.c' -o -name '*.h' 2>/dev/null | head -30
fi

echo ""
echo "=== Investigation complete ==="
echo "  Review the cloned repos in $WORKDIR for device-specific fixes."
echo "  Key things to look for:"
echo "    1. Updated OPP tables / thermal zones in device trees"
echo "    2. SELinux policy updates for bengal-5.15"
echo "    3. Module fixes not in ChicKernel tree"
echo "    4. Device-specific driver updates"
