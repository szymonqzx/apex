#!/usr/bin/env bash
# build-rom-crave.sh — APEX ROM build for topaz, meant to run INSIDE a
# foss.crave.io devspace (or any x86_64 Linux host with ~350GB free).
#
# Usage:
#   Inside a devspace shell:   bash build-rom-crave.sh
#   From outside via crave:    crave devspace -- "bash -s" < tools/build-rom-crave.sh
#
# Env knobs:
#   LOS_DIR=/crave-devspaces/apex-los23   devspace project folder (persistent)
#   BUILD_TYPE=userdebug|eng|user       lunch variant (default: userdebug)
#   CLEAN=1                             wipe LOS_DIR and re-sync from scratch
#   SYNC_ONLY=1                         stop after repo sync (no build)
#   APEX_KERNEL=0|1                     if 1 and a prebuilt APEX Image is
#                                       provided via $APEX_IMAGE, drop it
#                                       into the prebuilt-kernel repo
#                                       (default 0 — stock topaz kernel)
#   APEX_IMAGE=/path/Image              APEX kernel Image for APEX_KERNEL=1
#
# The devspace is persistent: re-runs resume the synced tree (ccache + out/
# survive), so only the first run pays the ~80GB sync cost.
set -euo pipefail

LOS_DIR="${LOS_DIR:-/crave-devspaces/apex-los23}"
BUILD_TYPE="${BUILD_TYPE:-userdebug}"
DEVICE="topaz"

echo "=== APEX ROM build (crave devspace) ==="
echo "  tree:   $LOS_DIR"
echo "  device: $DEVICE / lineage-23.2"
echo "  type:   $BUILD_TYPE"

mkdir -p "$LOS_DIR"
cd "$LOS_DIR"

# ── 1. repo init + local manifest ────────────────────────────────
if [ "${CLEAN:-0}" = "1" ]; then
  echo ">>> CLEAN=1 — wiping $LOS_DIR"
  rm -rf "$LOS_DIR"/* "$LOS_DIR"/.repo
fi

if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git \
    -b lineage-23.2 --git-lfs --depth=1
fi

mkdir -p .repo/local_manifests
# The manifest lives in the apex repo — cloned to vendor/apex by the
# manifest itself on first sync; bootstrap it here for the first run.
if [ ! -f .repo/local_manifests/topaz.xml ]; then
  if [ -f vendor/apex/rom-overlays/manifests/topaz.xml ]; then
    cp vendor/apex/rom-overlays/manifests/topaz.xml .repo/local_manifests/
  else
    curl -fsSL -o .repo/local_manifests/topaz.xml \
      "https://raw.githubusercontent.com/szymonqzx/apex/main/rom-overlays/manifests/topaz.xml"
  fi
fi

# ── 2. sync ──────────────────────────────────────────────────────
echo ">>> repo sync"
repo sync -c -j"$(nproc)" --force-sync --no-clone-bundle --no-tags \
  --optimized-fetch --prune

# Optional: drop the APEX kernel into the prebuilt-kernel repo
if [ "${APEX_KERNEL:-0}" = "1" ] && [ -n "${APEX_IMAGE:-}" ]; then
  echo ">>> Installing APEX kernel Image into device/xiaomi/topaz-kernel"
  cp "$APEX_IMAGE" device/xiaomi/topaz-kernel/images/kernel
fi

# Decompress vendored wlan module if needed (kernel repo vendorsetup)
[ -f device/xiaomi/topaz-kernel/vendorsetup.sh ] && \
  bash device/xiaomi/topaz-kernel/vendorsetup.sh || true

if [ "${SYNC_ONLY:-0}" = "1" ]; then
  echo ">>> SYNC_ONLY — stopping after sync"
  exit 0
fi

# ── 3. build ─────────────────────────────────────────────────────
echo ">>> building lineage_$DEVICE-$BUILD_TYPE"
source build/envsetup.sh
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
ccache -M 100G 2>/dev/null || true
ccache -o compression=true 2>/dev/null || true

breakfast "$DEVICE" "$BUILD_TYPE"
mka bacon 2>&1 | tee "$LOS_DIR/build.log"

# ── 4. collect artifacts ─────────────────────────────────────────
OUT="out/target/product/$DEVICE"
echo ">>> artifacts:"
ls -lh "$OUT"/lineage-*.zip "$OUT"/*.img 2>/dev/null || true
echo "=== done ==="
