#!/system/bin/sh
# lindroid-init.sh — initialize a fresh Arch Linux ARM container.
#
# Downloads and extracts the Arch Linux ARM aarch64 rootfs to
# /data/adb/apex/arch. This is a one-time setup script.
#
# Prerequisites:
#   - ~2GB free space on /data
#   - Network access (downloads from os.archlinuxarm.org)
#   - Root access (KSU)

set -eu

CONTAINER_ROOT="/data/adb/apex/arch"
ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ROOTFS_TMP="/data/adb/apex/arch-rootfs.tar.gz"

if [ -d "$CONTAINER_ROOT" ] && [ -f "$CONTAINER_ROOT/etc/lindroid.conf" ]; then
    echo "Container already exists at $CONTAINER_ROOT"
    echo "Use lindroid-migrate.sh to upgrade, or remove $CONTAINER_ROOT to reinit."
    exit 0
fi

echo "Initializing Arch Linux ARM container..."
echo "Target: $CONTAINER_ROOT"
echo ""

# Create container root
mkdir -p "$CONTAINER_ROOT"

# Download rootfs
if [ ! -f "$ROOTFS_TMP" ]; then
    echo "Downloading Arch Linux ARM aarch64 rootfs..."
    echo "  URL: $ROOTFS_URL"
    echo "  This may take several minutes..."
    curl -fsSL -o "$ROOTFS_TMP" "$ROOTFS_URL" || {
        echo "ERROR: download failed"
        echo "Try manually: curl -o $ROOTFS_TMP $ROOTFS_URL"
        exit 1
    }
fi

# Extract rootfs
echo "Extracting rootfs to $CONTAINER_ROOT..."
tar xzf "$ROOTFS_TMP" -C "$CONTAINER_ROOT"
echo "Extraction complete."

# Clean up download
rm -f "$ROOTFS_TMP"

# Run migration to set up container config
echo "Running migration script..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sh "$SCRIPT_DIR/lindroid-migrate.sh"

echo ""
echo "Arch Linux ARM container initialized at $CONTAINER_ROOT"
echo "Start with: lindroid-start.sh"
