#!/bin/bash
#
# apex_ota_fallback.sh — Generate OTA-style zip for emergency recovery
#
# Takes a built ROM output directory and produces a flashable OTA zip
# compatible with LineageOS recovery / TWRP.
#
# Usage: apex_ota_fallback.sh <rom_output_dir> <output_zip>
#
# Part of the APEX ROM update architecture (docs/UPDATE_ARCHITECTURE.md).
#

set -euo pipefail

ROM_DIR="${1:?Usage: apex_ota_fallback.sh <rom_output_dir> <output_zip>}"
OUTPUT_ZIP="${2:?Usage: apex_ota_fallback.sh <rom_output_dir> <output_zip>}"

# Images required for a full OTA
REQUIRED_IMAGES=(
  "system.img"
  "vendor.img"
  "boot.img"
  "product.img"
  "system_ext.img"
)

# Verify all required images exist
for img in "${REQUIRED_IMAGES[@]}"; do
  if [ ! -f "$ROM_DIR/$img" ]; then
    echo "ERROR: Required image not found: $ROM_DIR/$img"
    exit 1
  fi
done

# Create staging directory
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "Staging OTA zip at $STAGE"

# Copy images
for img in "${REQUIRED_IMAGES[@]}"; do
  cp "$ROM_DIR/$img" "$STAGE/$img"
done

# Create META-INF updater script
mkdir -p "$STAGE/META-INF/com/google/android"

cat > "$STAGE/META-INF/com/google/android/update-binary" << 'UPDATEBINARY'
#!/sbin/sh
#
# APEX ROM OTA update-binary
# Compatible with LineageOS recovery / TWRP
#

OUTFD=/proc/self/fd/$2
ZIP=$3

print() {
  echo -e "ui_print $1\nui_print" > $OUTFD
}

print "================================"
print "  APEX ROM OTA Installer"
print "================================"
print ""

# Extract and flash each partition
for partition in system vendor boot product system_ext; do
  print "Flashing $partition..."
  unzip -o "$ZIP" "$partition.img" -d /tmp/
  if [ -f /tmp/$partition.img ]; then
    # SAFE: $partition is one of system/vendor/boot/product/system_ext only
    # (validated above). Brick-safety: never flashes bootloader/aboot/partition.
    dd if=/tmp/$partition.img of=/dev/block/by-name/$partition bs=8192k
    rm /tmp/$partition.img
    print "  $partition flashed OK"
  else
    print "  WARNING: $partition.img not found, skipping"
  fi
done

print ""
print "Wiping cache..."
rm -rf /cache/*
rm -rf /data/dalvik-cache/*

print ""
print "APEX ROM installed successfully!"
print "Rebooting in 5 seconds..."
sleep 5
reboot
UPDATEBINARY

chmod 755 "$STAGE/META-INF/com/google/android/update-binary"

cat > "$STAGE/META-INF/com/google/android/updater-script" << 'UPDATERSCRIPT'
# APEX ROM OTA updater-script
# This file is informational — the update-binary handles flashing.
# Format: assert/flash commands for compatibility with recovery parsers.

assert(getprop("ro.product.device") == "tapas" || getprop("ro.product.device") == "topaz");
show_progress(1.000000, 0);
show_progress(0.500000, 0);
package_extract_file("system.img", "/dev/block/by-name/system");
show_progress(0.100000, 0);
package_extract_file("vendor.img", "/dev/block/by-name/vendor");
show_progress(0.100000, 0);
package_extract_file("boot.img", "/dev/block/by-name/boot");
show_progress(0.100000, 0);
package_extract_file("product.img", "/dev/block/by-name/product");
show_progress(0.100000, 0);
package_extract_file("system_ext.img", "/dev/block/by-name/system_ext");
show_progress(0.100000, 0);
show_progress(1.000000, 10);
UPDATERSCRIPT

# Create the zip
echo "Creating OTA zip: $OUTPUT_ZIP"
(
  cd "$STAGE"
  zip -r "$OUTPUT_ZIP" . \
    -x "*.DS_Store" \
    -x "*__MACOSX*"
)

# Verify the zip
if [ -f "$OUTPUT_ZIP" ]; then
  SIZE=$(du -h "$OUTPUT_ZIP" | cut -f1)
  echo "OTA zip created: $OUTPUT_ZIP ($SIZE)"
  echo "Flash via recovery: adb push $OUTPUT_ZIP /sdcard/ && flash in TWRP"
else
  echo "ERROR: Failed to create OTA zip"
  exit 1
fi
