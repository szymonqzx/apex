#!/usr/bin/env bash
# release.sh — Create an APEX release (kernel + ROM + modules)
#
# Usage: ./tools/release.sh <version> [--build] [--skip-tag] [--rom]
#   version: e.g. 0.2.1 (full semver; tag becomes v<version>-zepharo)
#   --build:  also run a full build before packaging
#   --skip-tag: skip creating the git tag (for testing)
#   --rom:    also package ROM zip + pentest modules + hiding stack
#
# Creates:
#   1. Flashable AnyKernel3 zip (via tools/package-anykernel3.sh)
#   2. ROM zip (via tools/package-rom.sh) — if --rom
#   3. Pentest driver modules zip (via tools/build-pentest-drivers.sh) — if --rom
#   4. Hiding stack zip (via tools/package-hiding-stack.sh) — if --rom
#   5. Agent models zip (pre-built GGUF models) — if --rom
#   6. Checksum + release manifest
#   7. Git tag v<version>-zepharo (after verification)
set -euo pipefail

APEX="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APEX"

VERSION="${1:?usage: release.sh <version> [--build] [--skip-tag] [--rom]}"
DO_BUILD=false
SKIP_TAG=false
DO_ROM=false

for arg in "${@:2}"; do
  case "$arg" in
    --build) DO_BUILD=true ;;
    --skip-tag) SKIP_TAG=true ;;
    --rom) DO_ROM=true ;;
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

# 4b. Package ROM artifacts if --rom
ROM_ZIP=""
PENTEST_ZIP=""
HIDING_ZIP=""
MODELS_ZIP=""

if [ "$DO_ROM" = true ]; then
  echo ""
  echo ">>> Packaging ROM zip..."
  if bash tools/package-rom.sh 2>/dev/null; then
    ROM_ZIP="apex-rom-${VERSION}-topaz.zip"
    if [ -f "$ROM_ZIP" ]; then
      sha256sum "$ROM_ZIP" > "${ROM_ZIP}.sha256"
      echo "  [OK] $ROM_ZIP ($(du -h "$ROM_ZIP" | cut -f1))"
    fi
  else
    echo "  [WARN] ROM packaging failed (LOS source tree may not be available)"
  fi

  echo ">>> Packaging pentest driver modules..."
  if bash tools/build-pentest-drivers.sh 2>/dev/null; then
    PENTEST_ZIP="apex-pentest-modules-${VERSION}.zip"
    if [ -f "$PENTEST_ZIP" ]; then
      sha256sum "$PENTEST_ZIP" > "${PENTEST_ZIP}.sha256"
      echo "  [OK] $PENTEST_ZIP"
    fi
  else
    echo "  [WARN] Pentest driver packaging failed (kernel headers may not be available)"
  fi

  echo ">>> Packaging hiding stack..."
  if bash tools/package-hiding-stack.sh 2>/dev/null; then
    HIDING_ZIP="apex-hiding-stack-${VERSION}.zip"
    if [ -f "$HIDING_ZIP" ]; then
      sha256sum "$HIDING_ZIP" > "${HIDING_ZIP}.sha256"
      echo "  [OK] $HIDING_ZIP"
    fi
  else
    echo "  [WARN] Hiding stack packaging failed"
  fi

  echo ">>> Packaging agent models..."
  MODELS_ZIP="apex-agent-models-${VERSION}.zip"
  if [ -d agent/llm/models ] && ls agent/llm/models/*.gguf >/dev/null 2>&1; then
    (cd agent/llm/models && zip -r "../../$MODELS_ZIP" *.gguf >/dev/null 2>&1)
    if [ -f "$MODELS_ZIP" ]; then
      sha256sum "$MODELS_ZIP" > "${MODELS_ZIP}.sha256"
      echo "  [OK] $MODELS_ZIP ($(du -h "$MODELS_ZIP" | cut -f1))"
    fi
  else
    echo "  [WARN] No pre-built GGUF models found — skipping agent-models zip"
  fi
fi

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
$(if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then echo "  - name: $ROM_ZIP"; echo "    sha256: $(cut -d' ' -f1 "${ROM_ZIP}.sha256" 2>/dev/null || echo 'pending')"; echo "    size: $(du -h "$ROM_ZIP" | cut -f1)"; fi)
$(if [ -n "$PENTEST_ZIP" ] && [ -f "$PENTEST_ZIP" ]; then echo "  - name: $PENTEST_ZIP"; echo "    sha256: $(cut -d' ' -f1 "${PENTEST_ZIP}.sha256" 2>/dev/null || echo 'pending')"; echo "    size: $(du -h "$PENTEST_ZIP" | cut -f1)"; fi)
$(if [ -n "$HIDING_ZIP" ] && [ -f "$HIDING_ZIP" ]; then echo "  - name: $HIDING_ZIP"; echo "    sha256: $(cut -d' ' -f1 "${HIDING_ZIP}.sha256" 2>/dev/null || echo 'pending')"; echo "    size: $(du -h "$HIDING_ZIP" | cut -f1)"; fi)
$(if [ -n "$MODELS_ZIP" ] && [ -f "$MODELS_ZIP" ]; then echo "  - name: $MODELS_ZIP"; echo "    sha256: $(cut -d' ' -f1 "${MODELS_ZIP}.sha256" 2>/dev/null || echo 'pending')"; echo "    size: $(du -h "$MODELS_ZIP" | cut -f1)"; fi)

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
echo "  kernel:   $ZIP"
echo "  checksum: ${ZIP}.sha256"
echo "  manifest: $MANIFEST"
if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
  echo "  rom:      $ROM_ZIP"
fi
if [ -n "$PENTEST_ZIP" ] && [ -f "$PENTEST_ZIP" ]; then
  echo "  pentest:  $PENTEST_ZIP"
fi
if [ -n "$HIDING_ZIP" ] && [ -f "$HIDING_ZIP" ]; then
  echo "  hiding:   $HIDING_ZIP"
fi
if [ -n "$MODELS_ZIP" ] && [ -f "$MODELS_ZIP" ]; then
  echo "  models:   $MODELS_ZIP"
fi
echo "  flash:    adb push $ZIP /sdcard/ && flash in recovery"
