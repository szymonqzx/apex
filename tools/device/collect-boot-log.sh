#!/usr/bin/env bash
# collect-boot-log.sh — gather boot diagnostics from a connected device.
#
# Collects: pstore/ramoops records (panic/console), kernel log (dmesg),
# logcat, boot properties, and current state — into a dated directory.
# The go-to tool when a boot failed and we don't know why (no serial
# console on these devices; ramoops is the only kernel-side breadcrumb).
#
# Usage: collect-boot-log.sh [--out <dir>] [--json]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-}"
[ -n "$OUT" ] || OUT="logs/boot-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

run() { "$HERE/adb-retry.sh" --max-tries 3 -- "$1" 2>/dev/null || true; }

echo "== collecting boot diagnostics → $OUT"

run "su -c 'ls -la /sys/fs/pstore/ 2>/dev/null'" > "$OUT/pstore-ls.txt" || true
run "su -c 'for f in /sys/fs/pstore/*; do echo \"===== \$f =====\"; cat \"\$f\"; done 2>/dev/null'" > "$OUT/pstore-dump.txt" || true
run "su -c 'dmesg'" > "$OUT/dmesg.txt" || true
run "su -c 'dmesg | grep -iE \"panic|oops|bug|hang|watchdog|ramoops|pstore|kernel offset\"'" > "$OUT/dmesg-scan.txt" || true
run "logcat -d -b all -t 2000" > "$OUT/logcat.txt" || true
run "getprop" > "$OUT/props.txt" || true

# Last-kmsg (if present — catches the previous boot's tail)
run "su -c 'cat /sys/fs/pstore/console-ramoops* 2>/dev/null'" > "$OUT/prev-console.txt" || true
run "su -c 'cat /proc/last_kmsg 2>/dev/null'" > "$OUT/last_kmsg.txt" || true

{
  echo "== summary =="
  grep -c "panic" "$OUT/pstore-ls.txt" 2>/dev/null | sed 's/^/pstore panic records: /'
  grep -cE "Kernel panic|BUG:|Oops:" "$OUT/dmesg.txt" 2>/dev/null | sed 's/^/dmesg crash lines: /'
  grep -E "Linux version" "$OUT/dmesg.txt" 2>/dev/null | head -1
} | tee "$OUT/summary.txt"

echo "== collected: $(ls "$OUT" | tr '\n' ' ')"
echo "$OUT"
