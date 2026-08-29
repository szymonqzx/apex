#!/usr/bin/env bash
# tools/package-anykernel3.sh — package the apex kernel into a flashable zip
# Creates an AnyKernel3-format zip that can be flashed via TWRP/OrangeFox
# Includes kernel Image, modules, and all ROM overlays for dirty apply.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
OUT="$APEX/out"
AK3="$APEX/anykernel3"
VERSION="1.2.0"
PROFILE="${APEX_PROFILE:-balanced}"
ZIP_NAME="apex-kernel-${VERSION}-${PROFILE}-anykernel3.zip"
ZIP_DIR="/tmp/apex-ak3-build"

echo "=== Packaging AnyKernel3 zip v${VERSION} ==="

# 1. Prepare build directory
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR/modules"
mkdir -p "$ZIP_DIR/overlays"

# 2. Copy AnyKernel3 template (core engine + META-INF + anykernel.sh)
cp -r "$AK3/tools" "$ZIP_DIR/"
cp -r "$AK3/META-INF" "$ZIP_DIR/"
cp "$AK3/anykernel.sh" "$ZIP_DIR/"
cp "$AK3/README.md" "$ZIP_DIR/" 2>/dev/null || true

# 3. Copy kernel image
IMAGE="$OUT/arch/arm64/boot/Image"
if [ -f "$IMAGE" ]; then
  cp "$IMAGE" "$ZIP_DIR/zImage"
  echo "  [OK] zImage copied ($(du -h "$IMAGE" | cut -f1))"
else
  echo "  [FAIL] kernel Image not found: $IMAGE"
  exit 1
fi

# 4. DTB Handling
# For GKI devices (topaz/tapas), we do NOT package a generic DTB directory.
# The ROM's existing DTB in vendor_boot/init_boot is used.
# Only copy dtbo.img if it exists and is specifically built for the device.
DTBO="$OUT/arch/arm64/boot/dtbo.img"
if [ -f "$DTBO" ]; then
  cp "$DTBO" "$ZIP_DIR/"
  echo "  [OK] dtbo.img copied"
fi

# 5. Copy modules
MODULE_COUNT=0
for ko in $(find "$OUT" -name "*.ko" 2>/dev/null); do
  cp "$ko" "$ZIP_DIR/modules/"
  MODULE_COUNT=$((MODULE_COUNT + 1))
done
echo "  [INFO] $MODULE_COUNT modules copied"

# 6. Copy ROM overlays (all of them)
OVERLAY_DIR="$APEX/rom-overlays"
if [ -d "$OVERLAY_DIR" ]; then
  echo "  [INFO] Copying ROM overlays..."

  # build.prop overlays (PIF)
  [ -f "$OVERLAY_DIR/build.prop/system.build.prop.append" ] && {
    cp "$OVERLAY_DIR/build.prop/system.build.prop.append" "$ZIP_DIR/overlays/"
    echo "  [OK] system.build.prop.append"
  }
  [ -f "$OVERLAY_DIR/build.prop/vendor.build.prop.append" ] && {
    cp "$OVERLAY_DIR/build.prop/vendor.build.prop.append" "$ZIP_DIR/overlays/"
    echo "  [OK] vendor.build.prop.append"
  }

  # init.rc
  [ -f "$OVERLAY_DIR/init.d/apex_power.rc" ] && {
    cp "$OVERLAY_DIR/init.d/apex_power.rc" "$ZIP_DIR/overlays/"
    echo "  [OK] apex_power.rc"
  }
  [ -f "$OVERLAY_DIR/init.d/apex_profiles.rc" ] && {
    cp "$OVERLAY_DIR/init.d/apex_profiles.rc" "$ZIP_DIR/overlays/"
    echo "  [OK] apex_profiles.rc"
  }

  # thermald
  [ -f "$OVERLAY_DIR/thermald/thermald.conf" ] && {
    cp "$OVERLAY_DIR/thermald/thermald.conf" "$ZIP_DIR/overlays/"
    echo "  [OK] thermald.conf"
  }

  # SELinux policy (all .te files)
  for te_file in "$OVERLAY_DIR"/selinux/*.te; do
    [ -f "$te_file" ] || continue
    cp "$te_file" "$ZIP_DIR/overlays/"
    echo "  [OK] $(basename "$te_file")"
  done

  # Hidden packages list
  [ -f "$OVERLAY_DIR/hidden_packages.list" ] && {
    cp "$OVERLAY_DIR/hidden_packages.list" "$ZIP_DIR/overlays/"
    echo "  [OK] hidden_packages.list"
  }

  # Pre-compiled binaries (if available)
  [ -f "$OVERLAY_DIR/bin/apex-alarmkeeper" ] && {
    cp "$OVERLAY_DIR/bin/apex-alarmkeeper" "$ZIP_DIR/overlays/"
    echo "  [OK] apex-alarmkeeper binary"
  }
  [ -f "$OVERLAY_DIR/bin/apex-bridge" ] && {
    cp "$OVERLAY_DIR/bin/apex-bridge" "$ZIP_DIR/overlays/"
    echo "  [OK] apex-bridge binary"
  }

  echo "  [OK] ROM overlays packaged"
fi

# 7. Copy dirty-modify script (for manual application option)
[ -f "$APEX/tools/apex-dirty-modify.sh" ] && {
  cp "$APEX/tools/apex-dirty-modify.sh" "$ZIP_DIR/"
  echo "  [OK] apex-dirty-modify.sh included (manual option)"
}

# 7b. Copy wakelock audit script
[ -f "$APEX/tools/apex-wakelock-audit.sh" ] && {
  cp "$APEX/tools/apex-wakelock-audit.sh" "$ZIP_DIR/"
  echo "  [OK] apex-wakelock-audit.sh included"
}

# 8. Create the zip
cd "$ZIP_DIR"
zip -r9 "$APEX/$ZIP_NAME" . -x "*.DS_Store" >/dev/null 2>&1
echo ""
echo "=== Package created: $APEX/$ZIP_NAME ==="
echo "  Size: $(du -h "$APEX/$ZIP_NAME" | cut -f1)"
echo "  Contents:"
echo "    - zImage (kernel Image)"
[ -f "$ZIP_DIR/dtbo.img" ] && echo "    - dtbo.img"
echo "    - modules/ ($MODULE_COUNT .ko files)"
echo "    - overlays/ (build.prop, init.rc, thermald, SELinux, hidden_packages)"
echo "    - apex-dirty-modify.sh (manual dirty-apply script)"
echo ""
echo "  Flash via: adb push $ZIP_NAME /sdcard/ && flash in recovery"
echo "  Or dirty-apply overlays only:"
echo "    adb push apex-dirty-modify.sh /data/local/tmp/"
echo "    adb shell su -c 'sh /data/local/tmp/apex-dirty-modify.sh'"
