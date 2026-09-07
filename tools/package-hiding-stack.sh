#!/bin/bash
# package-hiding-stack.sh — assembles the 4 hiding stack KSU modules
# into flashable zip packages for inclusion in the ROM.
#
# This script does NOT create the modules from scratch — it downloads
# or uses pre-built module zips and packages them with the APEX
# configuration files (denylist, keybox placeholder).
#
# Usage: ./package-hiding-stack.sh [output-dir]
# Output: [output-dir]/{zygisk_next,shamiko,hma_oss,tricky_store}.zip
#
# Prerequisites:
#   - curl or wget for downloading modules
#   - zip for packaging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/hiding/prebuilt}"

mkdir -p "$OUTPUT_DIR"

# Module sources (GitHub releases — pinned versions, verified 2026-09-07)
ZYGISK_NEXT_URL="https://github.com/Dr-TSNG/ZygiskNext/releases/download/v1.5.0/Zygisk-Next-1.5.0-843-5217106-release.zip"
SHAMIKO_URL="https://github.com/LSPosed/LSPosed.github.io/releases/download/shamiko-414/Shamiko-v1.2.5-414-release.zip"
HMA_OSS_URL="https://github.com/frknkrc44/HMA-OSS/releases/download/oss-166/HMA-OSS-ZYGISK-oss-166-release.zip"
TRICKY_STORE_URL="https://github.com/5ec1cff/TrickyStore/releases/download/1.4.1/Tricky-Store-v1.4.1-245-72b2e84-release.zip"
YURIKEY_URL="https://github.com/Yurii0307/yurikey/releases/download/v3.0.6/Yurikey-v3.0.6.signed.zip"

download() {
    local url="$1"
    local output="$2"
    if [ -f "$output" ]; then
        echo "  already exists: $(basename "$output")"
        return 0
    fi
    echo "  downloading: $(basename "$output")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    else
        echo "ERROR: need curl or wget" >&2
        return 1
    fi
}

echo "Packaging hiding stack modules..."

download "$ZYGISK_NEXT_URL" "$OUTPUT_DIR/zygisk_next.zip"
download "$SHAMIKO_URL" "$OUTPUT_DIR/shamiko.zip"
download "$HMA_OSS_URL" "$OUTPUT_DIR/hma_oss.zip"
download "$TRICKY_STORE_URL" "$OUTPUT_DIR/tricky_store.zip"
download "$YURIKEY_URL" "$OUTPUT_DIR/yurikey.zip"

# Copy configuration files
cp "$PROJECT_ROOT/hiding/denylist.conf" "$OUTPUT_DIR/denylist.conf"
cp "$PROJECT_ROOT/hiding/install_modules.sh" "$OUTPUT_DIR/install_modules.sh"
cp "$PROJECT_ROOT/hiding/configure_hiding.sh" "$OUTPUT_DIR/configure_hiding.sh"

# Create combined hiding-stack zip for single-flash convenience
COMBINED="$PROJECT_ROOT/releases/apex-hiding-stack-1.0.0.zip"
echo ""
echo "Creating combined hiding-stack package..."
cd "$OUTPUT_DIR"
zip -j "$COMBINED" \
    zygisk_next.zip \
    shamiko.zip \
    hma_oss.zip \
    tricky_store.zip \
    yurikey.zip \
    denylist.conf \
    install_modules.sh \
    configure_hiding.sh 2>/dev/null || {
    echo "WARNING: zip command not available — individual modules at $OUTPUT_DIR"
}

echo ""
echo "Hiding stack packaged at: $OUTPUT_DIR"
echo "Contents:"
ls -la "$OUTPUT_DIR/"
echo ""
if [ -f "$COMBINED" ]; then
    echo "Combined package: $COMBINED ($(du -h "$COMBINED" | cut -f1))"
fi
echo ""
echo "These files should be copied to:"
echo "  vendor/apex/hiding/ in the LOS source tree"
echo ""
echo "Module versions (pinned 2026-09-07):"
echo "  Zygisk-Next:  v1.5.0 (843)"
echo "  Shamiko:      v1.2.5 (414)"
echo "  HMA-OSS:      oss-166"
echo "  TrickyStore:  v1.4.1 (245)"
echo "  Yurikey:      v3.0.6"
