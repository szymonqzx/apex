#!/usr/bin/env bash
# release.sh — Create an APEX kernel release
#
# Usage: ./tools/release.sh <version> [--build]
#   version: e.g. 0.1.0, 0.2.0
#   --build: Also run a full build before packaging
#
# Creates:
#   1. Git tag v<version>-zepharo
#   2. Flashable AnyKernel3 zip
#   3. Release manifest with checksums
set -euo pipefail

APEX="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APEX"

VERSION="${1:?usage: release.sh <version> [--build]}"
DO_BUILD=false

if [ "${2:-}" = "--build" ]; then
  DO_BUILD=true
fi

echo "=== APEX Kernel Release: v${VERSION}-zepharo ==="
echo ""

# 1. Run certification tests
echo ">>> Running certification tests..."
python3 -m pytest tests/cert/ -v --tb=short
echo ""

# 2. Build if requested
if [ "$DO_BUILD" = true ]; then
  echo ">>> Building kernel..."
  bash tools/build-kernel.sh
  echo ""
fi

# 3. Package
echo ">>> Packaging AnyKernel3 zip..."
bash tools/package-anykernel3.sh
echo ""

# 4. Generate checksums
ZIP="apex-kernel-${VERSION}-zepharo-anykernel3.zip"
if [ ! -f "$ZIP" ]; then
  echo "ERROR: $ZIP not found" >&2
  exit 1
fi

sha256sum "$ZIP" > "${ZIP}.sha256"
echo ">>> Checksum: $(cat ${ZIP}.sha256)"

# 5. Generate release manifest
MANIFEST="apex-release-${VERSION}.manifest"
cat > "$MANIFEST" << EOF
# APEX Kernel Release Manifest
version: ${VERSION}
base: zepharo-r9
kernel_version: 5.15.170
device: topaz/tapas (Redmi Note 12 4G)
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

artifacts:
  - name: ${ZIP}
    sha256: $(cut -d' ' -f1 "${ZIP}.sha256")
    size: $(du -h "$ZIP" | cut -f1)

modules: $(find out/ -name "*.ko" | wc -l)
image_size: $(du -h out/arch/arm64/boot/Image | cut -f1)

config_fragments:
  - defconfig/apex-modern.config
  - defconfig/apex-security.config

patches:
$(ls -1 patches/apex-new/ | sed 's/^/  - /')

certification: all tests passed
EOF

echo ">>> Manifest: $MANIFEST"
cat "$MANIFEST"
echo ""
echo "=== Release v${VERSION}-zepharo ready ==="
echo "Flash: adb push ${ZIP} /sdcard/ && flash in recovery"
