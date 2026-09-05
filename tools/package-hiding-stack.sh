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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/hiding/prebuilt}"

mkdir -p "$OUTPUT_DIR"

# Module sources (GitHub releases — pinned versions)
ZYGISK_NEXT_URL="https://github.com/mywalkiN/ZygiskNext/releases/download/v1.0.0/ZygiskNext_v1.0.0.zip"
SHAMIKO_URL="https://github.com/LSPosed/LSPosed.github.io/releases/download/shamiko-v1.1.1/shamiko-v1.1.1-517-release.zip"
HMA_OSS_URL="https://github.com/AlirezaIvwmd/HMA-OSS/releases/download/v1.0/hma_oss.zip"
TRICKY_STORE_URL="https://github.com/5ec1cff/TrickyStore/releases/download/v1.0.0/TrickyStore_v1.0.0.zip"

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

# Copy configuration files
cp "$PROJECT_ROOT/hiding/denylist.conf" "$OUTPUT_DIR/denylist.conf"
cp "$PROJECT_ROOT/hiding/install_modules.sh" "$OUTPUT_DIR/install_modules.sh"
cp "$PROJECT_ROOT/hiding/configure_hiding.sh" "$OUTPUT_DIR/configure_hiding.sh"

echo ""
echo "Hiding stack packaged at: $OUTPUT_DIR"
echo "Contents:"
ls -la "$OUTPUT_DIR/"
echo ""
echo "These files should be copied to:"
echo "  vendor/apex/hiding/ in the LOS source tree"
echo ""
echo "NOTE: Module URLs are placeholders — verify and pin actual"
echo "release versions before building the ROM."
