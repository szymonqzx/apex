#!/system/bin/sh
# lindroid-migrate.sh — migrate existing chroot to Lindroid container.
#
# Migrates the existing Arch Linux ARM chroot at /data/adb/apex/arch
# to the Lindroid container format. Preserves installed packages,
# home directory, and configurations.
#
# Changes:
#   1. Add /etc/lindroid.conf (container config)
#   2. Update /etc/resolv.conf for veth networking
#   3. Install xorg-x11-server-Xvfb for display bridge
#   4. Create display bridge init script

set -eu

CONTAINER_ROOT="/data/adb/apex/arch"

if [ ! -d "$CONTAINER_ROOT" ]; then
    echo "ERROR: no existing chroot at $CONTAINER_ROOT"
    echo "Install Arch Linux ARM first: lindroid-init.sh"
    exit 1
fi

echo "Migrating chroot to Lindroid container format..."

# 1. Create container config
cat > "$CONTAINER_ROOT/etc/lindroid.conf" << 'EOF'
# Lindroid container configuration
CONTAINER_IP=10.0.0.2
HOST_IP=10.0.0.1
DISPLAY=:0
DISPLAY_BRIDGE=x11
NETWORK=veth
EOF

# 2. Update DNS for veth networking
cat > "$CONTAINER_ROOT/etc/resolv.conf" << 'EOF'
nameserver 10.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# 3. Create display bridge init
mkdir -p "$CONTAINER_ROOT/etc/init.d"
cat > "$CONTAINER_ROOT/etc/init.d/x11-bridge" << 'BRIDGE'
#!/bin/sh
# X11 display bridge — starts Xvfb for headless X11 rendering
DISPLAY=:0
XVFB_RESOLUTION=1920x1080x24

case "$1" in
    start)
        echo "Starting X11 display bridge..."
        Xvfb :0 -screen 0 $XVFB_RESOLUTION &
        echo $! > /tmp/xvfb.pid
        ;;
    stop)
        if [ -f /tmp/xvfb.pid ]; then
            kill $(cat /tmp/xvfb.pid) 2>/dev/null || true
            rm -f /tmp/xvfb.pid
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
BRIDGE
chmod +x "$CONTAINER_ROOT/etc/init.d/x11-bridge"

# 4. Create container init script
cat > "$CONTAINER_ROOT/sbin/lindroid-init" << 'INIT'
#!/bin/sh
# Lindroid container init — runs on container start
export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/sbin
export DISPLAY=:0

# Start X11 display bridge
/etc/init.d/x11-bridge start

# Start D-Bus (if available)
if [ -x /usr/bin/dbus-daemon ]; then
    dbus-daemon --system --fork 2>/dev/null || true
fi

# Start a shell on the console
echo "Lindroid container ready (DISPLAY=:0)"
exec /bin/sh
INIT
chmod +x "$CONTAINER_ROOT/sbin/lindroid-init"

echo ""
echo "Migration complete."
echo "Container root: $CONTAINER_ROOT"
echo "Config: $CONTAINER_ROOT/etc/lindroid.conf"
echo ""
echo "To install Xvfb (if not already installed):"
echo "  lindroid-exec.sh 'pacman -Sy --noconfirm xorg-server-xvfb'"
echo ""
echo "To start the container:"
echo "  lindroid-start.sh"
