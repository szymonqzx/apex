#!/bin/bash
# package-hiding-stack.sh — assembles the hiding-stack KSU modules and APEX
# config into flashable packages for inclusion in the ROM.
#
# Modules (2026-09-07 stack — Shamiko REMOVED, ND v7.7 detects it):
#   zygisk_next     Zygisk runtime (needed by LSPosed/HMA)
#   hma_oss         package/path hiding (LSPosed module)
#   susfs4ksu       kernel-level hiding (sus_path/sus_mount/cmdline spoof)
#   tricky_store_oss FOSS attestation keybox (beakthoven, GPLv3)
#   yurikey         keybox manager (one-time setup)
#   lsposed_next    LSPosed framework for KSU-Next — no stable release
#                   assets; fetched from GitHub Actions artifacts or the
#                   project's Telegram channel. Optional here.
#
# Usage: ./package-hiding-stack.sh [output-dir]
# Output: [output-dir]/<module>.zip + releases/apex-hiding-stack-<ver>.zip
#
# Prerequisites: curl (or wget), zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/hiding/prebuilt}"
VERSION="1.1.0"

mkdir -p "$OUTPUT_DIR"

# Module sources (GitHub releases — pinned, verified 2026-09-07)
ZYGISK_NEXT_URL="https://github.com/Dr-TSNG/ZygiskNext/releases/download/v1.5.0/Zygisk-Next-1.5.0-843-5217106-release.zip"
HMA_OSS_URL="https://github.com/frknkrc44/HMA-OSS/releases/download/oss-166/HMA-OSS-ZYGISK-oss-166-release.zip"
SUSFS4KSU_URL="https://github.com/sidex15/susfs4ksu-module/releases/download/v1.5.2%2B_R28/ksu_module_susfs_1.5.2%2B.zip"
TRICKY_STORE_OSS_URL="https://github.com/beakthoven/TrickyStoreOSS/releases/download/v3.1.0/Tricky-Store-OSS-v3.1.0-172-41383f5-Release.zip"
YURIKEY_URL="https://github.com/Yurii0307/yurikey/releases/download/v3.0.6/Yurikey-v3.0.6.signed.zip"
# LSPosed-Next: no stable release assets (Actions/Telegram only). Uncomment
# and pin a URL here if you mirror a build.
# LSPOSED_NEXT_URL=""

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

echo "Packaging hiding stack modules (v$VERSION)..."

download "$ZYGISK_NEXT_URL"    "$OUTPUT_DIR/zygisk_next.zip"
download "$HMA_OSS_URL"        "$OUTPUT_DIR/hma_oss.zip"
download "$SUSFS4KSU_URL"      "$OUTPUT_DIR/susfs4ksu.zip"
download "$TRICKY_STORE_OSS_URL" "$OUTPUT_DIR/tricky_store_oss.zip"
download "$YURIKEY_URL"        "$OUTPUT_DIR/yurikey.zip"

# LSPosed-Next (optional — see header comment)
if [ -n "${LSPOSED_NEXT_URL:-}" ]; then
    download "$LSPOSED_NEXT_URL" "$OUTPUT_DIR/lsposed_next.zip"
else
    echo "  [SKIP] lsposed_next — no stable release asset; install from"
    echo "         F1xGOD/LSPosed-Next Actions artifacts or Telegram channel."
fi

# Copy configuration + APEX artifacts
cp "$PROJECT_ROOT/hiding/denylist.conf"        "$OUTPUT_DIR/denylist.conf"
cp "$PROJECT_ROOT/hiding/install_modules.sh"   "$OUTPUT_DIR/install_modules.sh"
cp "$PROJECT_ROOT/hiding/configure_hiding.sh"  "$OUTPUT_DIR/configure_hiding.sh"
cp "$PROJECT_ROOT/hiding/configure_susfs.sh"   "$OUTPUT_DIR/configure_susfs.sh"
if [ -f "$PROJECT_ROOT/hiding/prebuilt/lineage_hider.apk" ]; then
    if [ "$PROJECT_ROOT/hiding/prebuilt/lineage_hider.apk" != "$OUTPUT_DIR/lineage_hider.apk" ]; then
        cp "$PROJECT_ROOT/hiding/prebuilt/lineage_hider.apk" "$OUTPUT_DIR/lineage_hider.apk"
    fi
else
    echo "WARNING: lineage_hider.apk not built — build apps/lineage-hider first" >&2
fi

# Create combined hiding-stack zip for single-flash convenience
COMBINED="$PROJECT_ROOT/releases/apex-hiding-stack-$VERSION.zip"
echo ""
echo "Creating combined hiding-stack package..."
rm -f "$COMBINED"
cd "$OUTPUT_DIR"
zip -j "$COMBINED" \
    zygisk_next.zip \
    hma_oss.zip \
    susfs4ksu.zip \
    tricky_store_oss.zip \
    yurikey.zip \
    denylist.conf \
    install_modules.sh \
    configure_hiding.sh \
    configure_susfs.sh \
    lineage_hider.apk 2>/dev/null || {
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
echo "  Zygisk-Next:     v1.5.0 (843)"
echo "  HMA-OSS:         oss-166"
echo "  susfs4ksu:       v1.5.2+ (R28)"
echo "  TrickyStoreOSS:  v3.1.0 (172)"
echo "  Yurikey:         v3.0.6"
echo "  LSPosed-Next:    manual (Actions/Telegram)"
echo "  lineage-hider:   io.apex.lineagehider (libxposed 100+)"
