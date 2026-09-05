#!/bin/bash
# build-lindroid.sh — builds the Lindroid container image for APEX ROM.
#
# This script:
#   1. Downloads Arch Linux ARM aarch64 rootfs
#   2. Installs essential packages (Xvfb, pacman, etc.)
#   3. Applies Lindroid configuration (lindroid-migrate.sh)
#   4. Packages as a tar.gz for inclusion in the ROM or post-install download
#
# Usage: ./build-lindroid.sh [output-dir]
# Default: output-dir=lindroid/prebuilt/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/lindroid/prebuilt}"
TMP_ROOTFS="/tmp/lindroid-build"

ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

echo "Building Lindroid container image..."

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TMP_ROOTFS"

# ── Step 1: Download rootfs ───────────────────────────────────────

ROOTFS_TAR="$OUTPUT_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
if [ ! -f "$ROOTFS_TAR" ]; then
    echo "[1/4] Downloading Arch Linux ARM rootfs..."
    curl -fsSL -o "$ROOTFS_TAR" "$ROOTFS_URL"
else
    echo "[1/4] Rootfs already downloaded"
fi

# ── Step 2: Extract and prepare ───────────────────────────────────

echo "[2/4] Extracting rootfs..."
rm -rf "$TMP_ROOTFS/root"
mkdir -p "$TMP_ROOTFS/root"
tar xzf "$ROOTFS_TAR" -C "$TMP_ROOTFS/root"

# ── Step 3: Install packages ──────────────────────────────────────

echo "[3/4] Installing essential packages..."
# This requires aarch64 binfmt + chroot or qemu-user-static
if command -q qemu-aarch64-static 2>/dev/null || [ -f /usr/bin/qemu-aarch64-static ]; then
    cp /usr/bin/qemu-aarch64-static "$TMP_ROOTFS/root/usr/bin/"
    chroot "$TMP_ROOTFS/root" /usr/bin/pacman -Sy --noconfirm \
        xorg-server-xvfb \
        dbus \
        openssh \
        base-devel \
        git 2>/dev/null || echo "  WARNING: some packages failed to install"
    rm -f "$TMP_ROOTFS/root/usr/bin/qemu-aarch64-static"
else
    echo "  WARNING: qemu-aarch64-static not found — skipping package installation"
    echo "  Packages will need to be installed on-device after first boot"
fi

# Apply Lindroid migration
if [ -f "$PROJECT_ROOT/lindroid/scripts/lindroid-migrate.sh" ]; then
    echo "  Applying Lindroid configuration..."
    # Run migration in the extracted rootfs
    CONTAINER_ROOT="$TMP_ROOTFS/root"
    # The migration script expects /data/adb/apex/arch as the root
    # We adapt it to run on the extracted rootfs
    bash -c "CONTAINER_ROOT='$CONTAINER_ROOT' && $(sed 's|/data/adb/apex/arch|'"$CONTAINER_ROOT"'|g' "$PROJECT_ROOT/lindroid/scripts/lindroid-migrate.sh")" 2>/dev/null || true
fi

# ── Step 4: Package ───────────────────────────────────────────────

echo "[4/4] Packaging container image..."
CONTAINER_TAR="$OUTPUT_DIR/lindroid-container.tar.gz"
cd "$TMP_ROOTFS"
tar czf "$CONTAINER_TAR" root/
cd "$PROJECT_ROOT"

echo ""
echo "Lindroid container built: $CONTAINER_TAR"
echo "Size: $(du -h "$CONTAINER_TAR" | cut -f1)"
echo ""
echo "Install on device:"
echo "  mkdir -p /data/adb/apex/arch"
echo "  tar xzf lindroid-container.tar.gz -C /data/adb/apex/arch --strip-components=1"
echo "  lindroid-start.sh"

# Cleanup
rm -rf "$TMP_ROOTFS"
