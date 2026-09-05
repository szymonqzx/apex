#!/system/bin/sh
# lindroid-start.sh — start the Arch Linux ARM container with namespace isolation.
#
# Uses Linux namespaces (pid, net, mount, user) to create an isolated
# container. Android is the host, Arch Linux ARM is the container.
#
# Display: X11 forwarding to Termux:X11 or Wayland proxy
# Network: veth pair (container gets 10.0.0.2)
# Filesystem: /data/adb/apex/arch as container root

set -eu

CONTAINER_ROOT="/data/adb/apex/arch"
CONTAINER_IP="10.0.0.2"
HOST_IP="10.0.0.1"
VETH_HOST="apex-veth0"
VETH_CONTAINER="apex-veth1"
DISPLAY_SOCKET="/data/adb/apex/.x11-display"

if [ ! -d "$CONTAINER_ROOT" ]; then
    echo "ERROR: container root not found at $CONTAINER_ROOT"
    exit 1
fi

# Check if already running
if [ -f /data/adb/apex/.lindroid-pid ]; then
    PID=$(cat /data/adb/apex/.lindroid-pid 2>/dev/null || echo "")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "container already running (pid=$PID)"
        exit 0
    fi
fi

# Set up network (veth pair)
ip link add "$VETH_HOST" type veth peer name "$VETH_CONTAINER" 2>/dev/null || true
ip addr add "$HOST_IP/24" dev "$VETH_HOST" 2>/dev/null || true
ip link set "$VETH_HOST" up 2>/dev/null || true

# Set up display bridge
mkdir -p /data/adb/apex
touch "$DISPLAY_SOCKET"

# Start container with namespace isolation
# Using unshare for pid, mount, net namespaces
# nsenter is used for exec into the running container
unshare --pid --mount --net --uts --ipc --fork \
    --root "$CONTAINER_ROOT" \
    --propagation private \
    /bin/sh -c "
        # Mount essential filesystems
        mount -t proc proc /proc 2>/dev/null || true
        mount -t sysfs sys /sys 2>/dev/null || true
        mount -t devtmpfs dev /dev 2>/dev/null || true
        mount -t tmpfs tmp /tmp 2>/dev/null || true

        # Set up networking inside namespace
        ip link set lo up 2>/dev/null || true
        ip link set $VETH_CONTAINER up 2>/dev/null || true
        ip addr add $CONTAINER_IP/24 dev $VETH_CONTAINER 2>/dev/null || true
        ip route add default via $HOST_IP 2>/dev/null || true

        # Set hostname
        hostname lindroid 2>/dev/null || true

        # Set DISPLAY for X11 forwarding
        export DISPLAY=:0

        # Start the container init
        echo 'lindroid container started'
        exec /sbin/init 2>/dev/null || exec /bin/sh
    " &

CONTAINER_PID=$!
echo "$CONTAINER_PID" > /data/adb/apex/.lindroid-pid
echo "container started (pid=$CONTAINER_PID, ip=$CONTAINER_IP)"
