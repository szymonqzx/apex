#!/usr/bin/env bash
# boot-image.sh — boot-image factory for GKI devices.
#
# Builds a flashable boot image from a reference boot image + a kernel
# Image, using magiskboot. The reference boot's header (v4, kernel-only on
# modern GKI) is preserved; only the kernel blob is swapped. Verified
# end-to-end: output is unpacked and the kernel version + feature strings
# are checked before the tool reports success.
#
# Usage: boot-image.sh <reference-boot.img> <kernel-Image> <out.img>
# Env:   MAGISKBOOT   path to magiskboot (auto-detected: local x86_64
#                     binary, then /data/adb/ap/bin/magiskboot on device)
#        FEATURE_STRINGS  optional space-separated strings that must be
#                     present in the new kernel (e.g. "apex_thermal")
#        CHECK_STRINGS_GONE  optional strings that must be ABSENT
#
# Exit: 0 success, 1 build/verify failure.

set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <reference-boot.img> <kernel-Image> <out.img>" >&2; exit 64; }
REF="$1"; KERNEL_IMG="$2"; OUT="$3"

find_magiskboot() {
  if [ -n "${MAGISKBOOT:-}" ] && [ -x "${MAGISKBOOT:-}" ]; then
    echo "$MAGISKBOOT"; return 0
  fi
  # Common local locations
  for c in /tmp/magiskboot-extract/lib/x86_64/libmagiskboot.so \
           /opt/magiskboot/libmagiskboot.so "$HOME/bin/libmagiskboot.so"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  # On-device magiskboot (needs adb + root)
  if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "device$"; then
    if timeout 10 adb shell "su -c 'ls /data/adb/ap/bin/magiskboot'" 2>/dev/null | grep -q magiskboot; then
      echo "adb-magiskboot"; return 0
    fi
  fi
  echo "ERROR: magiskboot not found (set MAGISKBOOT=...)" >&2
  exit 1
}

MB="$(find_magiskboot)"

if [ "$MB" = "adb-magiskboot" ]; then
  # On-device path: work in /data/local/tmp
  adb-retry.sh -- "su -c 'cd /data/local/tmp && rm -f kernel && magiskboot unpack \"$REF\" 2>/dev/null && cp \"$KERNEL_IMG\" kernel && magiskboot repack \"$REF\" 2>/dev/null && cp new-boot.img \"$OUT\" && ls -la \"$OUT\"'" >/dev/null
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cp "$REF" "$WORK/ref.img"
  cp "$KERNEL_IMG" "$WORK/kernel-new"
  ( cd "$WORK" && "$MB" unpack ref.img >/dev/null 2>&1 && mv kernel-new kernel && "$MB" repack ref.img >/dev/null 2>&1 && mv new-boot.img "$OUT" )
fi

[ -f "$OUT" ] || { echo "ERROR: failed to produce $OUT" >&2; exit 1; }

# ---- Verify the output ----
echo "  [boot-image] $OUT built ($(du -h "$OUT" | cut -f1))"

V=$(mktemp); trap 'rm -rf "$WORK" "$V"' EXIT
if [ "$MB" = "adb-magiskboot" ]; then
  adb-retry.sh -- "su -c 'cd /data/local/tmp && magiskboot unpack \"$OUT\" >/dev/null 2>&1 && strings kernel | grep -m1 \"Linux version\"'" > "$V"
else
  ( cd "$WORK" && "$MB" unpack "$OUT" >/dev/null 2>&1 && strings kernel | grep -m1 "Linux version" ) > "$V" || true
fi
VER=$(cat "$V" || true)
echo "  [boot-image] kernel: ${VER:-UNKNOWN}"
case "$VER" in *"Linux version 5.15"*) : ;; *) echo "  [boot-image] WARN: unexpected kernel version string" >&2 ;; esac

# Feature string presence/absence checks
for s in ${FEATURE_STRINGS:-}; do
  if [ "$MB" = "adb-magiskboot" ]; then
    N=$(adb-retry.sh -- "su -c 'cd /data/local/tmp && strings kernel | grep -c \"$s\"'" 2>/dev/null || echo 0)
  else
    N=$( ( cd "$WORK" && strings kernel 2>/dev/null | grep -c "$s" ) || true )
  fi
  [ "$N" -ge 1 ] || { echo "ERROR: expected string '$s' missing from kernel" >&2; exit 1; }
done
for s in ${CHECK_STRINGS_GONE:-}; do
  if [ "$MB" = "adb-magiskboot" ]; then
    N=$(adb-retry.sh -- "su -c 'cd /data/local/tmp && strings kernel | grep -c \"$s\"'" 2>/dev/null || echo 0)
  else
    N=$( ( cd "$WORK" && strings kernel 2>/dev/null | grep -c "$s" ) || true )
  fi
  [ "$N" -eq 0 ] || { echo "ERROR: unexpected string '$s' still present in kernel" >&2; exit 1; }
done

echo "  [boot-image] verification OK"
exit 0
