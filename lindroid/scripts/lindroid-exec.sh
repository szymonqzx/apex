#!/system/bin/sh
# lindroid-exec.sh — execute a command inside the running container.
#
# Uses nsenter to enter the container's namespaces and run a command.
# Usage: lindroid-exec.sh <command>

set -eu

PID_FILE="/data/adb/apex/.lindroid-pid"
CONTAINER_ROOT="/data/adb/apex/arch"

if [ ! -f "$PID_FILE" ]; then
    echo "ERROR: container not running"
    exit 1
fi

PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: container process not found"
    rm -f "$PID_FILE"
    exit 1
fi

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
    echo "ERROR: no command specified"
    exit 1
fi

# Enter all namespaces and execute the command
nsenter --target "$PID" \
    --pid --mount --net --uts --ipc \
    --root "$CONTAINER_ROOT" \
    /bin/sh -c "export DISPLAY=:0; $COMMAND"
