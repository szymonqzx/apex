#!/bin/bash
# package-ksu-module.sh — assembles the APEX ROM KSU module into a flashable zip
#
# Output: releases/apex-rom-ksu-module-v1.0.0.zip
#
# This zip is flashed via KernelSU manager's "Install module" option.
# It overlays system files without modifying partitions directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$PROJECT_ROOT/ksu-module"
OUTPUT_DIR="${1:-$PROJECT_ROOT/releases}"

APEX_VERSION="1.0.0"
ZIP_NAME="apex-rom-ksu-module-v${APEX_VERSION}.zip"

mkdir -p "$OUTPUT_DIR"

echo "════════════════════════════════════════════════════════════════"
echo "  APEX ROM KSU Module Packager v${APEX_VERSION}"
echo "  Output: $OUTPUT_DIR/$ZIP_NAME"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Verify module structure
echo "[1/4] Verifying module structure..."
required_files=(
  "module.prop"
  "post-fs-data.sh"
  "service.sh"
  "sepolicy.rule"
  "system/priv-app/ApexSystemServices/ApexSystemServices.apk"
  "system/priv-app/ApexControl/ApexControl.apk"
  "system/app/NFCForge/NFCForge.apk"
  "system/app/PTKTUI/PTKTUI.apk"
)
for f in "${required_files[@]}"; do
  if [ ! -f "$MODULE_DIR/$f" ]; then
    echo "ERROR: Missing required file: $f"
    exit 1
  fi
done
echo "  All required files present."

# Verify APKs are valid ZIP files (basic integrity check)
echo "[2/4] Verifying APK integrity..."
for apk in "$MODULE_DIR"/system/priv-app/*/*.apk "$MODULE_DIR"/system/app/*/*.apk; do
  if ! unzip -t "$apk" >/dev/null 2>&1; then
    echo "ERROR: Corrupt APK: $apk"
    exit 1
  fi
  size=$(du -h "$apk" | cut -f1)
  echo "  OK: $(basename "$apk") ($size)"
done

# Create zip
echo "[3/4] Creating KSU module zip..."
STAGING=$(mktemp -d)
cp -r "$MODULE_DIR"/* "$STAGING/"
cd "$STAGING"
zip -r "$OUTPUT_DIR/$ZIP_NAME" . -x "*.git*" 2>/dev/null
cd "$PROJECT_ROOT"
rm -rf "$STAGING"

# Summary
echo "[4/4] Summary:"
echo "  Module: $OUTPUT_DIR/$ZIP_NAME"
echo "  Size: $(du -h "$OUTPUT_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "  Contents:"
echo "    - 4 system APKs (ApexSystemServices, ApexControl, NFCForge, PTK TUI)"
echo "    - 18 init RC files"
echo "    - 8 shell scripts (health check, tuning, pocket detect, etc.)"
echo "    - SELinux policy rules (apex_agent, apex_chroot, apex_charge)"
echo "    - build.prop overlays (PIF spoofing)"
echo "    - thermald.conf (custom thermal profile)"
echo "    - hidden_packages.list (HMA-OSS blacklist)"
echo ""
echo "  Install: KernelSU Manager → Install from storage → select zip"
echo "════════════════════════════════════════════════════════════════"
