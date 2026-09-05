#!/bin/bash
#
# build-whisper.sh — Cross-compile whisper.cpp for aarch64-linux-android
#
# Requirements:
# - Android NDK r26+ at $ANDROID_NDK_HOME
# - cmake 3.18+
# - git
#
# Output: libwhisper.so + whisper-cli binary for arm64
#
# Part of the APEX ROM agent-spine (T6 — on-device voice).

set -euo pipefail

WHISPER_VERSION="v1.7.3"
BUILD_DIR="${BUILD_DIR:-/tmp/whisper-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out/arm64}"
NDK_PATH="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path}"
API_LEVEL="${API_LEVEL:-28}"

echo "=== Building whisper.cpp for aarch64-linux-android ==="
echo "NDK: $NDK_PATH"
echo "API: $API_LEVEL"
echo "Output: $OUTPUT_DIR"
echo ""

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Clone whisper.cpp if not present
if [ ! -d "$BUILD_DIR/whisper.cpp" ]; then
  git clone --depth 1 --branch "$WHISPER_VERSION" \
    https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR/whisper.cpp"
fi

cd "$BUILD_DIR/whisper.cpp"

TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake"

# Configure
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-"$API_LEVEL" \
  -DANDROID_STL=c++_static \
  \
  -DWHISPER_NATIVE=OFF \
  -DWHISPER_AVX=OFF \
  -DWHISPER_AVX2=OFF \
  -DWHISPER_FMA=OFF \
  -DWHISPER_F16C=OFF \
  -DWHISPER_OPENBLAS=OFF \
  -DWHISPER_CUBLAS=OFF \
  \
  -DBUILD_SHARED_LIBS=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build-android -j"$(nproc)"

# Copy outputs
cp build-android/libwhisper.so "$OUTPUT_DIR/"
cp build-android/bin/whisper-cli "$OUTPUT_DIR/" 2>/dev/null || \
  cp build-android/whisper-cli "$OUTPUT_DIR/" 2>/dev/null || true

echo ""
echo "=== Build complete ==="
echo "libwhisper.so: $OUTPUT_DIR/libwhisper.so"
echo "whisper-cli:   $OUTPUT_DIR/whisper-cli"
ls -lh "$OUTPUT_DIR/"
