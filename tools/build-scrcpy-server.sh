#!/bin/bash
# build-scrcpy-server.sh — builds the scrcpy server jar for APEX Desktop Mode.
#
# scrcpy server is a Java application that runs on the Android device
# and streams the display + audio to a connected client over ADB.
#
# This script:
#   1. Clones the scrcpy repository (or uses a local copy)
#   2. Builds the server jar using Gradle
#   3. Copies the jar to the APEX project for inclusion in the ROM
#
# Usage: ./build-scrcpy-server.sh [scrcpy-source-dir] [output-dir]
# Default: scrcpy-source-dir=~/src/scrcpy, output-dir=desktop/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRCPY_SRC="${1:-$HOME/src/scrcpy}"
OUTPUT_DIR="${2:-$PROJECT_ROOT/desktop}"

SCRCPY_VERSION="v4.1"
SCRCPY_REPO="https://github.com/Genymobile/scrcpy.git"

echo "Building scrcpy server ${SCRCPY_VERSION}..."

# Clone if not present
if [ ! -d "$SCRCPY_SRC" ]; then
    echo "Cloning scrcpy repository..."
    mkdir -p "$(dirname "$SCRCPY_SRC")"
    git clone --depth 1 --branch "$SCRCPY_VERSION" "$SCRCPY_REPO" "$SCRCPY_SRC"
fi

cd "$SCRCPY_SRC"

# Build the server jar
echo "Building server jar..."
# scrcpy server is in server/ directory
cd server

# Build with Gradle
if [ -f "gradlew" ]; then
    ./gradlew assembleRelease
    SERVER_JAR="build/outputs/apk/release/server-release-unsigned.apk"
elif [ -f "build.gradle" ]; then
    gradle assembleRelease
    SERVER_JAR="build/outputs/apk/release/server-release-unsigned.apk"
else
    # Fallback: build with direct javac
    echo "No Gradle found — building manually..."
    mkdir -p build/classes
    find src -name "*.java" -exec javac -d build/classes {} +
    # Build jar
    jar cf build/scrcpy-server.jar -C build/classes .
    SERVER_JAR="build/scrcpy-server.jar"
fi

if [ ! -f "$SERVER_JAR" ]; then
    echo "ERROR: server jar not found after build"
    exit 1
fi

# Copy to output
mkdir -p "$OUTPUT_DIR"
cp "$SERVER_JAR" "$OUTPUT_DIR/scrcpy-server.jar"
echo ""
echo "scrcpy server built: $OUTPUT_DIR/scrcpy-server.jar"
echo "Size: $(du -h "$OUTPUT_DIR/scrcpy-server.jar" | cut -f1)"
