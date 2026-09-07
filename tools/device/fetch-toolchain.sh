#!/usr/bin/env bash
# fetch-toolchain.sh — fetch the toolchain the APEX build needs.
#
# The 2026-09-07 investigation proved the ecosystem builds these kernels
# with AOSP prebuilt clang (r547379), not distro clang — see
# docs/TOOLING.md. This fetches:
#   1. clang-r547379  (AOSP prebuilt, from topnotchfreaks/clang — the same
#      source the Zepharo R9 build uses)
#   2. magiskboot x86_64 (extracted from the Magisk APK) — for laptop-side
#      boot-image surgery
#
# Usage: fetch-toolchain.sh [--dir DIR]   (default: $HOME/.apex-toolchain)
# Env:   SKIP_MAGISKBOOT=1  skip the magiskboot fetch
#
# Exit: 0 success, 1 failure.

set -euo pipefail

DIR="${1:-$HOME/.apex-toolchain}"
[ "${1:-}" = "--dir" ] && DIR="$2"

mkdir -p "$DIR/bin"
echo "== fetching toolchain → $DIR"

# 1. AOSP clang r547379 (the R9 recipe toolchain)
CLANG_TGZ="$DIR/clang-r547379.tar.gz"
if [ -x "$DIR/bin/clang" ]; then
  echo "  clang already present: $($DIR/bin/clang --version | head -1)"
elif [ -f "$CLANG_TGZ" ]; then
  echo "  extracting cached $CLANG_TGZ"
  tar -xzf "$CLANG_TGZ" -C "$DIR"
else
  echo "  downloading clang-r547379 (1.1GB)..."
  curl -fL -o "$CLANG_TGZ" \
    "https://github.com/topnotchfreaks/clang/releases/download/v1.0.0/clang-r547379.tar.gz"
  tar -xzf "$CLANG_TGZ" -C "$DIR"
fi

# The TNF archive is flat (bin/ at the archive root) — extracting with
# -C "$DIR" puts it at $DIR/bin. Normalize for re-runs.
if [ -d "$DIR/bin" ] && [ -x "$DIR/bin/clang" ]; then
  :  # already in place
else
  echo "ERROR: expected clang at $DIR/bin/clang after extraction" >&2
  exit 1
fi

"$DIR/bin/clang" --version | head -1

# 2. magiskboot for x86_64 (boot-image surgery on the laptop)
if [ "${SKIP_MAGISKBOOT:-0}" != "1" ] && [ ! -x "$DIR/bin/magiskboot" ]; then
  echo "  fetching magiskboot (from Magisk APK)..."
  APK="$DIR/magisk.apk"
  curl -fL -o "$APK" "https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk"
  ( cd "$DIR" && unzip -o -q "$APK" "lib/x86_64/libmagiskboot.so" && \
    mv lib/x86_64/libmagiskboot.so bin/magiskboot && chmod +x bin/magiskboot && \
    rm -rf lib "$APK" )
  "$DIR/bin/magiskboot" 2>&1 | head -1
fi

echo "== toolchain ready:"
ls "$DIR/bin" | tr '\n' ' '; echo
