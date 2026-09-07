#!/usr/bin/env bash
# config-compare.sh — diff the local kernel .config against the RUNNING
# kernel's config (/proc/config.gz). Flags fatal deltas that explain boot
# or module-load failures on a specific ROM (HZ, module signing, missing
# drivers, cmdline...).
#
# Usage: config-compare.sh [--local out/.config] [--key '^CONFIG_HZ|^CONFIG_MODULE_SIG'] [--json]
# Default key set covers the deltas that mattered on the 2026-09-07 trial.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APEX="$(cd "$HERE/../.." && pwd)"
LOCAL="${LOCAL_CONFIG:-$APEX/out/.config}"
KEYS='^CONFIG_HZ=|^CONFIG_PREEMPT|^CONFIG_MODULE_SIG|^CONFIG_SECURITY=|^CONFIG_KSU|^CONFIG_BBG|^CONFIG_APEX_THERMAL|^CONFIG_CMDLINE|^CONFIG_ARM64_VA_BITS|^CONFIG_LTO|^CONFIG_CFI|^CONFIG_IKCONFIG|^CONFIG_GKI'
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

[ -f "$LOCAL" ] || { echo "ERROR: local config not found: $LOCAL" >&2; exit 1; }

# Fetch the running kernel's config
RUN="$("$HERE/adb-retry.sh" --max-tries 3 -- "su -c 'zcat /proc/config.gz 2>/dev/null'" 2>/dev/null || true)"
if [ -z "$RUN" ]; then
  echo "ERROR: could not read /proc/config.gz from device (root? CONFIG_IKCONFIG_PROC?)" >&2
  exit 1
fi

RUN_F=$(mktemp); LOCAL_F=$(mktemp)
trap 'rm -f "$RUN_F" "$LOCAL_F"' EXIT
printf '%s\n' "$RUN" | grep -E "$KEYS" | sort > "$RUN_F"
grep -E "$KEYS" "$LOCAL" | sort > "$LOCAL_F"

if [ "$JSON" -eq 1 ]; then
  DIFFS=$(diff "$RUN_F" "$LOCAL_F" | sed 's/^/  /' | tr '\n' '|')
  echo "{\"running_config\":\"$(head -c 200 "$RUN_F")\",\"diff\":\"$DIFFS\"}"
  exit 0
fi

echo "=== config deltas: RUNNING kernel (Ecstasy-style) vs LOCAL build ==="
echo "--- only in running kernel ---"; grep -vF -f "$LOCAL_F" "$RUN_F" | sed 's/^/  R /' || true
echo "--- only in local build ---"; grep -vF -f "$RUN_F" "$LOCAL_F" | sed 's/^/  L /' || true
echo "--- differing values ---"
join -t= -j 1 <(sort "$RUN_F") <(sort "$LOCAL_F") 2>/dev/null | grep -v "=" | head -0 || true
awk -F= 'NR==FNR {a[$1]=$2; next} ($1 in a) && a[$1] != $2 {printf "  %s: running=%s local=%s\n", $1, a[$1], $2}' "$RUN_F" "$LOCAL_F" || true
