#!/usr/bin/env bash
# fastboot-retry.sh — run a fastboot command resiliently.
#
# The USB link on real devices is lossy (EMI, marginal cables, dying
# debugging stacks). A fastboot transfer can hang indefinitely or fail
# with a phantom error ("Device does not support slots" on a flaky link).
# This wrapper retries with backoff, kills stuck transfers, and verifies
# the device is actually responsive between attempts.
#
# Usage: fastboot-retry.sh [--max-tries N] [--wait S] -- <fastboot args...>
# Exit: 0 on success, 1 if the command failed, 2 if no device after retries.
#
# Examples:
#   fastboot-retry.sh -- flash boot_a new-boot.img
#   fastboot-retry.sh --max-tries 8 -- set_active a

set -euo pipefail

MAX_TRIES=5
WAIT=5
FASTBOOT_BIN="${FASTBOOT_BIN:-fastboot}"
STUCK_KILL_AFTER="${STUCK_KILL_AFTER:-60}"  # seconds; a transfer this long is hung on a bad link (raise for slow links, e.g. 240)

while [ $# -gt 0 ]; do
  case "$1" in
    --max-tries) MAX_TRIES="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ $# -gt 0 ] || { echo "usage: $0 [--max-tries N] [--wait S] -- <fastboot args...>" >&2; exit 64; }

run_once() {
  # Run the fastboot command; kill it if it exceeds STUCK_KILL_AFTER.
  local out err rc
  out=$("$FASTBOOT_BIN" "$@" 2>/tmp/fbr.err) &
  local pid=$!
  # poll for completion, kill when stuck
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$STUCK_KILL_AFTER" ]; then
      echo "  [fastboot-retry] transfer stuck ${waited}s — killing and retrying" >&2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
  done
  wait "$pid"
  rc=$?
  err=$(cat /tmp/fbr.err 2>/dev/null || true)
  if [ $rc -eq 0 ]; then
    echo "$out"
    return 0
  fi
  # Fastboot sometimes errors on the link; treat "no devices" and
  # "does not support slots" as retryable.
  echo "  [fastboot-retry] failed: ${out} ${err}" >&2
  return 1
}

attempt=0
while [ "$attempt" -lt "$MAX_TRIES" ]; do
  attempt=$((attempt + 1))

  # Ensure the device is actually present before trying.
  if ! timeout 10 "$FASTBOOT_BIN" devices 2>/dev/null | grep -q "fastboot"; then
    echo "  [fastboot-retry] no fastboot device (attempt $attempt/$MAX_TRIES)" >&2
    sleep "$WAIT"
    continue
  fi

  if run_once "$@"; then
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_TRIES" ]; then
    echo "  [fastboot-retry] retrying in ${WAIT}s (attempt $attempt/$MAX_TRIES)" >&2
    sleep "$WAIT"
  fi
done

echo "fastboot-retry: giving up after $MAX_TRIES attempts" >&2
exit 2
