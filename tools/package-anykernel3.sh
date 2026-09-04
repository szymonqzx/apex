#!/usr/bin/env bash
# tools/package-anykernel3.sh — package the APEX kernel into a flashable zip
# Creates an AnyKernel3-format zip that can be flashed via TWRP/OrangeFox
# v0.1: bare Zepharo base — Image + modules only, no overlays
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="$(cd "$HERE/.." && pwd)"
OUT="$APEX/out"
AK3="$APEX/anykernel3"
VERSION="0.1.0-zepharo"
ZIP_NAME="apex-kernel-${VERSION}-anykernel3.zip"
ZIP_DIR="/tmp/apex-ak3-build"

echo "=== Packaging AnyKernel3 zip v${VERSION} ==="

# 1. Prepare build directory
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR/modules"

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
# For GKI devices (topaz/tapas), we do NOT package a DTB.
# The ROM's existing DTB in vendor_boot/init_boot is used.
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

# 6. Create the zip
cd "$ZIP_DIR"
zip -r9 "$APEX/$ZIP_NAME" . -x "*.DS_Store" >/dev/null 2>&1
echo ""
echo "=== Package created: $APEX/$ZIP_NAME ==="
echo "  Size: $(du -h "$APEX/$ZIP_NAME" | cut -f1)"
echo "  Contents:"
echo "    - zImage (kernel Image, 5.15.170 Zepharo R9)"
[ -f "$ZIP_DIR/dtbo.img" ] && echo "    - dtbo.img"
echo "    - modules/ ($MODULE_COUNT .ko files)"
echo ""
echo "  Flash via: adb push $ZIP_NAME /sdcard/ && flash in recovery"
