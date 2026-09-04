#!/usr/bin/env bash
# release.sh — Create an APEX kernel release
#
# Usage: ./tools/release.sh <version> [--build] [--skip-tag]
#   version: e.g. 0.2.1 (full semver; tag becomes v<version>-zepharo)
#   --build:  also run a full build before packaging
#   --skip-tag: skip creating the git tag (for testing)
#
# Creates:
#   1. Flashable AnyKernel3 zip (via tools/package-anykernel3.sh)
#   2. Checksum + release manifest
#   3. Git tag v<version>-zepharo (after verification)
set -euo pipefail

APEX="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APEX"

VERSION="${1:?usage: release.sh <version> [--build] [--skip-tag]}"
DO_BUILD=false
SKIP_TAG=false

for arg in "${@:2}"; do
  case "$arg" in
    --build) DO_BUILD=true ;;
    --skip-tag) SKIP_TAG=true ;;
  esac
done

# Basic semver sanity
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: version must be semver (e.g. 0.2.1), got: $VERSION" >&2
  exit 1
fi

TAG="v${VERSION}-zepharo"
ZIP="apex-kernel-${VERSION}-zepharo-anykernel3.zip"
MANIFEST="apex-release-${VERSION}.manifest"

if [ "$SKIP_TAG" = false ] && git tag "$TAG" >/dev/null 2>&1; then
  echo "ERROR: tag $TAG already exists — bump the version" >&2
  exit 1
fi

echo "=== APEX Kernel Release: $TAG ==="
echo ""

# 1. Pre-release checks (fast, no build)
echo ">>> Config consistency check..."
python3 tools/check-configs.py
echo ""

echo ">>> Certification tests..."
python3 -m pytest tests/cert/ -v --tb=short
echo ""

echo ">>> Tooling syntax checks..."
for s in tools/build-kernel.sh tools/package-anykernel3.sh tools/apply-patches.sh \
         tools/verify.sh anykernel3/anykernel.sh; do
  bash -n "$s"
  echo "  [OK] $s"
done
echo ""

# 2. Build if requested
if [ "$DO_BUILD" = true ]; then
  echo ">>> Building kernel..."
  bash tools/build-kernel.sh
  echo ""
fi

# 3. Verify build output (requires a build to have happened)
if [ -f out/arch/arm64/boot/Image ]; then
  echo ">>> Verifying build output..."
  bash tools/verify.sh --strict
  echo ""
else
  echo ">>> No build output found — skipping verify (run with --build for full)"
fi

# 4. Package
echo ">>> Packaging AnyKernel3 zip..."
bash tools/package-anykernel3.sh
echo ""

# 5. Checksums
if [ ! -f "$ZIP" ]; then
  echo "ERROR: $ZIP not found — packaging failed" >&2
  [ "$SKIP_TAG" = false ] && git tag -d "$TAG" >/dev/null 2>&1 || true
  exit 1
fi
sha256sum "$ZIP" > "${ZIP}.sha256"
echo ">>> Checksum: $(cat "${ZIP}.sha256")"

# 6. Release manifest
cat > "$MANIFEST" << EOF
# APEX Kernel Release Manifest
version: ${VERSION}
tag: ${TAG}
base: zepharo-r9
kernel_version: 5.15.170
device: topaz/tapas (Redmi Note 12 4G)
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

artifacts:
  - name: ${ZIP}
    sha256: $(cut -d' ' -f1 "${ZIP}.sha256")
    size: $(du -h "$ZIP" | cut -f1)

modules: $(find out/ -name "*.ko" 2>/dev/null | wc -l)
image_size: $(du -h out/arch/arm64/boot/Image 2>/dev/null | cut -f1)

config:
  - defconfig/apex_defconfig (tracked single source of truth)

patches:
$(grep -v '^#' patches/apex-new/series | sed '/^[[:space:]]*$/d' | awk '{print "  - " $1}')

certification: all tests passed
EOF

echo ">>> Manifest: $MANIFEST"
cat "$MANIFEST"
echo ""

# 7. Finalize tag
if [ "$SKIP_TAG" = false ]; then
  git add -A
  git commit --allow-empty -m "release: $TAG" --no-gpg-sign >/dev/null
  git tag "$TAG"
  echo ">>> Created tag: $TAG"
  echo "    Push with: git push origin $TAG"
fi

echo ""
echo "=== Release ${VERSION} ready ==="
echo "  zip:      $ZIP"
echo "  checksum: ${ZIP}.sha256"
echo "  manifest: $MANIFEST"
echo "  flash:    adb push $ZIP /sdcard/ && flash in recovery"
