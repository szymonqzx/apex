#!/system/bin/sh
# apex-term — wrapper script for entering the apex chroot
# Mounts the chroot rootfs at /data/adb/apex/chroot, sets up bind mounts,
# and launches a shell inside the chroot with the apex bridge socket.
#
# Usage: apex-term [command...]
#   no args  → interactive shell
#   args     → run command and exit

set -eu

CHROOT_DIR="/data/adb/apex/chroot"
BRIDGE_SOCKET="/dev/socket/apex-bridge"

if [ ! -d "$CHROOT_DIR" ]; then
  echo "apex-term: chroot rootfs not found at $CHROOT_DIR" >&2
  echo "  Run 'apex-setup-chroot' first to install the rootfs." >&2
  exit 1
fi

# --- Parse args ---
MOUNT_ONLY=false
if [ "${1:-}" = "--mount-only" ]; then
  MOUNT_ONLY=true
  shift
fi

# --- Mount bind mounts ---
mount --bind /dev "$CHROOT_DIR/dev" 2>/dev/null || true
mount --bind /proc "$CHROOT_DIR/proc" 2>/dev/null || true
mount --bind /sys "$CHROOT_DIR/sys" 2>/dev/null || true
mount --bind /dev/socket "$CHROOT_DIR/dev/socket" 2>/dev/null || true

# Mount apex procfs
if [ -d /proc/apex ]; then
  mkdir -p "$CHROOT_DIR/proc/apex" 2>/dev/null || true
  mount --bind /proc/apex "$CHROOT_DIR/proc/apex" 2>/dev/null || true
fi

# Mount SD card
if [ -d /sdcard ]; then
  mkdir -p "$CHROOT_DIR/sdcard" 2>/dev/null || true
  mount --bind /sdcard "$CHROOT_DIR/sdcard" 2>/dev/null || true
fi

# Set up DNS
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf" 2>/dev/null || true

# --- Enter chroot (or just mount) ---
EXIT_CODE=0
if [ "$MOUNT_ONLY" = true ]; then
  echo "apex-term: mounts ready at $CHROOT_DIR"
  exit 0
fi

if [ $# -gt 0 ]; then
  # Run command and exit
  chroot "$CHROOT_DIR" "$@" || EXIT_CODE=$?
else
  # Interactive shell
  echo "apex-term: entering chroot at $CHROOT_DIR"
  echo "  Type 'exit' to leave."
  chroot "$CHROOT_DIR" /bin/bash || EXIT_CODE=$?
fi

# --- Cleanup (best effort) ---
umount "$CHROOT_DIR/dev/socket" 2>/dev/null || true
umount "$CHROOT_DIR/proc/apex" 2>/dev/null || true
umount "$CHROOT_DIR/sdcard" 2>/dev/null || true
umount "$CHROOT_DIR/dev" 2>/dev/null || true
umount "$CHROOT_DIR/proc" 2>/dev/null || true
umount "$CHROOT_DIR/sys" 2>/dev/null || true

exit $EXIT_CODE
