#!/usr/bin/env bash
# tools/package-anykernel3.sh — package the APEX kernel into a flashable zip
# Creates an AnyKernel3-format zip that can be flashed via TWRP/OrangeFox
# v0.2: modern stack + security + device drivers + ordered module loading
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
OUT="$APEX/out"
AK3="$APEX/anykernel3"
VERSION="${APEX_PKG_VERSION:-0.4.0-zepharo}"
ZIP_NAME="apex-kernel-${VERSION}-anykernel3.zip"
ZIP_DIR="/tmp/apex-ak3-build"

# Module policy (research 2026-09-07, docs/TOOLING.md): the proven kernels
# for this device (Ecstasy/YASK/Helios) ship NO modules — the ROM provides
# vendor dlkm partitions. APEX_NO_MODULES=1 produces the lean ~45MB zip;
# the default keeps shipping our 491 modules until on-device module
# compatibility is proven.
NO_MODULES="${APEX_NO_MODULES:-0}"

echo "=== Packaging AnyKernel3 zip v${VERSION} ==="
echo "  modules:  $([ "$NO_MODULES" = "1" ] && echo "NONE (APEX_NO_MODULES=1, ROM dlkm)" || echo "shipped ($(find "$OUT" -name '*.ko' 2>/dev/null | wc -l) .ko)")"

# 1. Prepare build directory (modules/ only when modules are shipped —
# an empty modules/ dir is NOT valid AK3 and confuses recovery installers)
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR"
[ "$NO_MODULES" = "1" ] || mkdir -p "$ZIP_DIR/modules"

# 2. Copy AnyKernel3 template (core engine + META-INF + anykernel.sh)
cp -r "$AK3/tools" "$ZIP_DIR/"
cp -r "$AK3/META-INF" "$ZIP_DIR/"
cp "$AK3/anykernel.sh" "$ZIP_DIR/"
cp "$AK3/README.md" "$ZIP_DIR/" 2>/dev/null || true
cp "$AK3/LICENSE" "$ZIP_DIR/" 2>/dev/null || true

# 3. Copy kernel image as Image.ksu (R9-proven AK3 naming: the anykernel.sh
# "Only KernelSU version found" branch renames it to Image and flashes)
IMAGE="$OUT/arch/arm64/boot/Image"
if [ -f "$IMAGE" ]; then
  cp "$IMAGE" "$ZIP_DIR/Image.ksu"
  echo "  [OK] Image.ksu copied ($(du -h "$IMAGE" | cut -f1))"
else
  echo "  [FAIL] kernel Image not found: $IMAGE"
  exit 1
fi

# 4. DTB Handling
# For GKI devices (topaz/tapas), we do NOT package a DTB.
# The ROM's existing DTB in vendor_boot/init_boot is used.
DTBO="$OUT/arch/arm64/boot/dtbo.img"
if [ -f "$DTBO" ]; then
  cp "$DTBO" "$ZIP_DIR/"
  echo "  [OK] dtbo.img copied"
fi

# 5. Copy modules and generate depmod metadata (skipped with APEX_NO_MODULES=1)
MODULE_COUNT=0
if [ "$NO_MODULES" = "1" ]; then
  echo "  [INFO] modules skipped (APEX_NO_MODULES=1 — ROM provides vendor dlkm)"
else
  for ko in $(find "$OUT" -name "*.ko" 2>/dev/null); do
    cp "$ko" "$ZIP_DIR/modules/"
    MODULE_COUNT=$((MODULE_COUNT + 1))
  done
  echo "  [INFO] $MODULE_COUNT modules copied"
fi

# Generate modules.dep and related metadata so modprobe works at boot.
# This is critical — without modules.dep, the init system cannot resolve
# module dependencies and loading order.
if [ "$MODULE_COUNT" -gt 0 ]; then
  echo "  [INFO] Generating depmod metadata..."

  # Use the kernel version from the built Image
  KVER=$(strings "$OUT/arch/arm64/boot/Image" 2>/dev/null |
    grep -oP 'Linux version \K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -z "$KVER" ]; then
    KVER="5.15.211"
  fi

  # depmod expects modules at <root>/lib/modules/<kver>/
  # Create that structure in a temporary root, run depmod, then copy results
  DEPMOD_ROOT=$(mktemp -d)
  MOD_DEST="$DEPMOD_ROOT/lib/modules/$KVER"
  mkdir -p "$MOD_DEST"

  # Copy all .ko files and modules.builtin into the depmod root
  for ko in "$ZIP_DIR"/modules/*.ko; do
    [ -f "$ko" ] && cp "$ko" "$MOD_DEST/"
  done
  [ -f "$OUT/modules.builtin" ] && cp "$OUT/modules.builtin" "$MOD_DEST/"

  # Run depmod with the correct root and kernel version
  depmod -b "$DEPMOD_ROOT" "$KVER" 2>/dev/null || true

  # Copy generated metadata into the zip staging area
  for meta in modules.dep modules.alias modules.symbols modules.builtin modules.softdep; do
    if [ -f "$MOD_DEST/$meta" ]; then
      cp "$MOD_DEST/$meta" "$ZIP_DIR/modules/"
    fi
  done

  rm -rf "$DEPMOD_ROOT"

  if [ -f "$ZIP_DIR/modules/modules.dep" ]; then
    echo "  [OK] modules.dep generated for kernel $KVER"
  else
    echo "  [WARN] depmod did not produce modules.dep — modprobe may not work"
  fi
fi

# 6. Create module load script for ordered loading during boot (only when
# modules are shipped — with APEX_NO_MODULES=1 the ROM's dlkm handles it)
# This script is placed in /vendor/bin/ and called from init.rc
# It loads critical modules in the correct order before the rest
# are loaded by the ROM's init system via modprobe.
if [ "$NO_MODULES" = "1" ]; then
  rm -f "$ZIP_DIR/modules/apex-load-modules.sh"
else
  cat >"$ZIP_DIR/modules/apex-load-modules.sh" <<'LOADSCRIPT'
#!/system/bin/sh
# apex-load-modules.sh — ordered module loading for APEX kernel
# Called from init.rc on boot to load critical modules in order.
# Remaining modules are loaded by the ROM's init system via modprobe.

MOD_PATH="/vendor/lib/modules"
LOG_TAG="apex-modules"

# Critical modules that must load early and in order
CRITICAL_ORDER="
sched_walt
mi_thermal_interface
tcpm
bq2589x_charger
sc8551_charger
fg_sm5602
ln8000_charger
nopmi_charger
tcpc_rt1711h
charger_pd_policy
dual_role_usb_intf
onewire_gpio
batt_verify_ds28e16
ant_check
ant_check_div
apex_charge
"

load_module() {
  local mod="$1"
  local ko_file

  # Try modprobe first (uses modules.dep for dependency resolution)
  if modprobe "$mod" 2>/dev/null; then
    setprop sys.apex.modules.loaded "$mod" 2>/dev/null
    return 0
  fi

  # Fallback: direct insmod
  ko_file=$(find "$MOD_PATH" -name "${mod}.ko" 2>/dev/null | head -1)
  if [ -n "$ko_file" ] && [ -f "$ko_file" ]; then
    insmod "$ko_file" 2>/dev/null && return 0
  fi

  return 1
}

# Load critical modules in order
LOADED=0
FAILED=0
for mod in $CRITICAL_ORDER; do
  if load_module "$mod"; then
    LOADED=$((LOADED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

# Load remaining modules via modprobe (uses modules.dep for ordering)
for ko in "$MOD_PATH"/*.ko; do
  [ -f "$ko" ] || continue
  modname=$(basename "$ko" .ko)
  # Skip already-loaded modules
  if grep -q "^${modname} " /proc/modules 2>/dev/null; then
    continue
  fi
  modprobe "$modname" 2>/dev/null || insmod "$ko" 2>/dev/null
done

setprop sys.apex.modules.status "loaded:${LOADED}:failed:${FAILED}" 2>/dev/null
LOADSCRIPT
  chmod 755 "$ZIP_DIR/modules/apex-load-modules.sh"
  echo "  [OK] apex-load-modules.sh created"
fi

# 6. Create the zip
cd "$ZIP_DIR"
zip -r9 -X "$APEX/$ZIP_NAME" . -x "*.DS_Store" >/dev/null 2>&1
echo ""
echo "=== Package created: $APEX/$ZIP_NAME ==="
echo "  Size: $(du -h "$APEX/$ZIP_NAME" | cut -f1)"
echo "  Contents:"
echo "    - Image.ksu (kernel Image, 5.15.211 Zepharo branch)"
[ -f "$ZIP_DIR/dtbo.img" ] && echo "    - dtbo.img"
if [ "$NO_MODULES" = "1" ]; then
  echo "    - no modules (ROM vendor dlkm provides them)"
else
  echo "    - modules/ ($MODULE_COUNT .ko files)"
fi
echo ""
echo "  Flash via: adb push $ZIP_NAME /sdcard/ && flash in recovery"
