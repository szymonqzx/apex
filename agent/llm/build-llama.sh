#!/bin/bash
#
# build-llama.sh — Cross-compile llama.cpp for aarch64-linux-android
#
# Requirements:
# - Android NDK r26+ at $ANDROID_NDK_HOME
# - cmake 3.18+
# - git
#
# Output: libllama.so + llama-cli binary for arm64
#
# Part of the APEX ROM agent-spine (T3).

set -euo pipefail

LLAMA_VERSION="b4400"
BUILD_DIR="${BUILD_DIR:-/tmp/llama-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out/arm64}"
NDK_PATH="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path}"
API_LEVEL="${API_LEVEL:-28}"  # Android 9 (Pie) minimum

echo "=== Building llama.cpp for aarch64-linux-android ==="
echo "NDK: $NDK_PATH"
echo "API: $API_LEVEL"
echo "Output: $OUTPUT_DIR"
echo ""

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Clone llama.cpp if not present
if [ ! -d "$BUILD_DIR/llama.cpp" ]; then
  git clone --depth 1 --branch b"$LLAMA_VERSION" \
    https://github.com/ggerganov/llama.cpp.git "$BUILD_DIR/llama.cpp"
fi

cd "$BUILD_DIR/llama.cpp"

# NDK toolchain file
TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake"

# Configure
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-"$API_LEVEL" \
  -DANDROID_STL=c++_static \
  \
  -DLLAMA_NATIVE=OFF \
  -DLLAMA_AVX=OFF \
  -DLLAMA_AVX2=OFF \
  -DLLAMA_FMA=OFF \
  -DLLAMA_F16C=OFF \
  -DLLAMA_OPENBLAS=OFF \
  -DLLAMA_BLAS=OFF \
  -DLLAMA_CUBLAS=OFF \
  -DLLAMA_METAL=OFF \
  -DLLAMA_VULKAN=OFF \
  -DLLAMA_SDL=OFF \
  \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build-android -j"$(nproc)"

# Copy outputs
cp build-android/libllama.so "$OUTPUT_DIR/"
cp build-android/bin/llama-cli "$OUTPUT_DIR/" 2>/dev/null || true

echo ""
echo "=== Build complete ==="
echo "libllama.so: $OUTPUT_DIR/libllama.so"
echo "llama-cli:   $OUTPUT_DIR/llama-cli"
ls -lh "$OUTPUT_DIR/"
