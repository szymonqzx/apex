#!/system/bin/sh
# lindroid-stop.sh — stop the running Linux container.
set -eu

PID_FILE="/data/adb/apex/.lindroid-pid"
VETH_HOST="apex-veth0"
VETH_CONTAINER="apex-veth1"

if [ ! -f "$PID_FILE" ]; then
    echo "container not running (no pid file)"
    exit 0
fi

PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
if [ -z "$PID" ]; then
    echo "container not running (empty pid)"
    rm -f "$PID_FILE"
    exit 0
fi

if kill -0 "$PID" 2>/dev/null; then
    # Send SIGTERM for graceful shutdown
    kill -TERM "$PID" 2>/dev/null || true
    sleep 2
    # Force kill if still alive
    if kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null || true
    fi
    echo "container stopped (pid=$PID)"
else
    echo "container process not found (pid=$PID already dead)"
fi

# Clean up network
ip link delete "$VETH_HOST" 2>/dev/null || true
ip link delete "$VETH_CONTAINER" 2>/dev/null || true

rm -f "$PID_FILE"
