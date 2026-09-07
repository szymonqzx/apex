#!/usr/bin/env bash
# rebrand-lineage.sh — hardened LineageOS source rebranding sweep.
#
# The endgame countermeasure: eliminate every 'lineage' string from the ROM
# source so no binary/path/property/service retains it. Run against a synced
# LineageOS tree (lineage-23.2) BEFORE building.
#
# Hardening vs naive sed sweeps (see docs/REBRAND.md):
#   - text files only (extension allowlist) — binaries are never touched
#   - ordered replacements, longest match first (org.lineageos before lineage)
#   - build-integration repos (vendor/lineage, lineage-sdk dir names) are
#     NOT renamed — only content strings; renaming them breaks lunch
#   - .git/.repo/out/prebuilts excluded
#   - dry-run mode + per-file change report
#   - signing-key step documented (see docs/REBRAND.md)
#
# Usage:
#   ./rebrand-lineage.sh <source-root> <brand> [--dry-run] [--apply]
#     brand: e.g. "myntra" -> org.lineageos -> com.<brand>os, lineage -> <brand>
#     --dry-run: report what WOULD change (default, safe)
#     --apply:   actually rewrite files (review the dry-run first!)
#
# Exit codes: 0 ok, 1 usage, 2 dry-run found changes (use --apply to commit)

set -euo pipefail

SOURCE_ROOT="${1:?usage: rebrand-lineage.sh <source-root> <brand> [--dry-run|--apply]}"
BRAND="${2:?usage: rebrand-lineage.sh <source-root> <brand> [--dry-run|--apply]}"
MODE="${3:---dry-run}"

OLD_PKG="org.lineageos"
NEW_PKG="com.${BRAND}os"
OLD="lineage"
NEW="${BRAND}"
OLD_CAPS="LineageOS"
NEW_CAPS="${BRAND^}OS"

# Binary-extension blocklist — belt-and-suspenders on top of grep -I (which
# already skips binary files natively). Catches binary formats that happen to
# contain no NUL bytes and would otherwise pass grep -I.
BINARY_EXTS=(png jpg jpeg gif webp ttf otf woff woff2 eot zip jar apk aar
             so a o ko img bin gz bz2 xz zst lz4 dex odex vdex art kmod)

EXCLUDES=(--exclude-dir=.git --exclude-dir=.repo --exclude-dir=out
          --exclude-dir=prebuilts --exclude-dir=.gradle --exclude-dir=build)

# Never rename these directories (build integration / generated).
NO_RENAME_DIRS=(
  vendor/lineage lineage-sdk device/lineage
)

is_binary() {
  local f="$1" ext
  ext="${f##*.}"
  for e in "${BINARY_EXTS[@]}"; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

changed=0
report_file="$(mktemp /tmp/rebrand-report.XXXXXX)"

echo "=== LineageOS rebrand sweep: '$OLD' -> '$NEW' (pkg $OLD_PKG -> $NEW_PKG) ==="
echo "  mode: $MODE"
echo "  root: $SOURCE_ROOT"
echo "  report: $report_file"
echo ""

# 1. Content sweep — ordered, longest match first.
#    grep -rlI skips binary files natively; the BINARY_EXTS blocklist is a
#    second guard for binary formats without NUL bytes. Extensionless text
#    files (Makefile, README, LICENSE, ...) ARE swept — they are common in
#    AOSP and grep -I classifies them correctly.
sweep() {
  local pattern="$1" repl="$2" label="$3"
  local files=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_binary "$f" && continue
    files=$((files + 1))
    if [ "$MODE" = "--apply" ]; then
      sed -i "s/${pattern}/${repl}/g" "$f"
      echo "  [SED] $label: $f" >> "$report_file"
    else
      echo "  [DRY] $label: $f" >> "$report_file"
    fi
    changed=$((changed + 1))
  done < <(grep -rlI "$pattern" "${EXCLUDES[@]}" "$SOURCE_ROOT" 2>/dev/null | head -20000)
  echo "  $label: $files file(s) $( [ "$MODE" = "--apply" ] && echo rewritten || echo would-change )"
}

sweep "$OLD_PKG" "$NEW_PKG" "org.lineageos -> com.${BRAND}os"
sweep "$OLD_CAPS" "$NEW_CAPS" "LineageOS -> ${BRAND^}OS"
sweep "$OLD" "$NEW" "lineage -> ${BRAND}"

# 2. Directory rename — content packages ONLY (never build integration).
if [ "$MODE" = "--apply" ]; then
  find "$SOURCE_ROOT" -type d -name "*${OLD}*" \
      ! -path "*/.git/*" ! -path "*/.repo/*" ! -path "*/out/*" | while read -r d; do
    rel="${d#"$SOURCE_ROOT"/}"
    skip=0
    for nd in "${NO_RENAME_DIRS[@]}"; do
      case "$rel" in
        "$nd"|"$nd"/*) skip=1 ;;
      esac
    done
    [ "$skip" = 1 ] && continue
    newd="$(dirname "$d")/$(basename "$d" | sed "s/${OLD}/${NEW}/g")"
    [ "$d" = "$newd" ] && continue
    mv "$d" "$newd"
    echo "  [MV] $rel -> $(basename "$newd")" >> "$report_file"
    changed=$((changed + 1))
  done
fi

echo ""
echo "=== Sweep complete: $changed change(s) ==="
echo "  Report: $report_file"
echo ""
if [ "$MODE" = "--dry-run" ]; then
  echo "Dry-run only. Review $report_file, then re-run with --apply."
  echo "After --apply: update signing keys (see docs/REBRAND.md), then build."
  exit 2
fi
echo "Next steps (docs/REBRAND.md):"
echo "  1. New signing keys (replace vendor/lineage keys)"
echo "  2. Update product/vendor props (ro.lineage.* leftovers)"
echo "  3. Verify no 'lineage' remains: grep -ri lineage --exclude-dir=.git --exclude-dir=out ."
echo "  4. Build: lunch ${BRAND}_tapas-userdebug && make bacon"
exit 0
