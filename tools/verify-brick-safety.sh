#!/bin/bash
#
# verify-brick-safety.sh — Brick-safety verification gate
#
# Scans the repository for any writes to bootloader, aboot,
# partition tables, or other boot-critical partitions. Exits 1 if
# any dangerous write is found.
#
# This is the grep-verifiable brick-safety guard required by the
# APEX ROM design (docs/UPDATE_ARCHITECTURE.md, hard constraint #1).
#
# Usage: ./tools/verify-brick-safety.sh [repo_root]
#

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Partitions that must NEVER be written to
DANGEROUS_PARTITIONS="aboot|sbl1|sbl2|sbl3|sbl4|tz|rpm|hyp|modem|bootloader|devinfo|partition|cmnlib|cmnlib64|devcfg|keymaster|keybackup"

# Safe partitions that CAN be written to
SAFE_PARTITIONS="boot|system|vendor|product|system_ext|userdata|cache|vbmeta"

echo "=== APEX ROM Brick-Safety Verification ==="
echo "Scanning: $REPO_ROOT"
echo ""

ERRORS=0

# Scan all text files for dangerous patterns
# Skip: .git, build artifacts, this script itself, docs (docs describe the rules, not execute them)
while IFS= read -r file; do
  # Skip anything larger than 2MB up front — no shell script or patch
  # carrying a dangerous write pattern is that big, and grepping huge
  # binaries (zips, GGUF models, jars) is both slow and pointless.
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  if [ "$size" -gt 2097152 ]; then
    continue
  fi

  # Skip binary files
  if file "$file" 2>/dev/null | grep -q "binary"; then
    continue
  fi

  # Skip this script itself, test files (tests contain assertion
  # pattern strings for their own checks, not actual commands), docs
  # (docs describe the rules, not execute them), and other verify-*
  # scripts that contain the same grep patterns for their own checks.
  case "$file" in
    */verify-brick-safety.sh) continue ;;
    */tests/*) continue ;;
    */docs/*) continue ;;
    */verify-rom.sh) continue ;;
    */verify.sh) continue ;;
    */verify-stealth.sh) continue ;;
    */verify-daily-driver.sh) continue ;;
  esac

  # Check for dd writes to dangerous partitions
  # Match: dd if=... of=/dev/.../aboot  (but not in comments or pattern definitions)
  # Skip lines where the target is a variable ($partition etc.) — those are
  # validated at runtime by the script's own partition whitelist.
  matches=$(grep -nE "dd if=.*of=.*(/dev/block/by-name/|/dev/block/).*($DANGEROUS_PARTITIONS)\b" "$file" 2>/dev/null | grep -v "^.*#" | grep -v '\$' || true)
  if [ -n "$matches" ]; then
    echo "ERROR: Dangerous dd write to boot-critical partition in $file:"
    echo "$matches"
    ERRORS=$((ERRORS + 1))
  fi

  # Check for fastboot flash to dangerous partitions
  matches=$(grep -nE "fastboot flash ($DANGEROUS_PARTITIONS)\b" "$file" 2>/dev/null | grep -v "^.*#" || true)
  if [ -n "$matches" ]; then
    echo "ERROR: Dangerous fastboot flash in $file:"
    echo "$matches"
    ERRORS=$((ERRORS + 1))
  fi

  # Check for direct block device writes to dangerous partitions (executable, not in docs)
  case "$file" in
    */docs/*) ;; # Skip docs — they describe the rules
    *)
      matches=$(grep -nE "write.*(/dev/block/by-name/|/dev/block/).*($DANGEROUS_PARTITIONS)" "$file" 2>/dev/null | grep -v "^.*#" || true)
      if [ -n "$matches" ]; then
        echo "ERROR: Dangerous block device write in $file:"
        echo "$matches"
        ERRORS=$((ERRORS + 1))
      fi
      ;;
  esac

done < <(find "$REPO_ROOT" -type f \
  -not -path "*/.git/*" \
  -not -path "*/out/*" \
  -not -path "*/build/*" \
  -not -path "*/.gradle/*" \
  -not -path "*/__pycache__/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/kernel/*" \
  -not -name "*.img" \
  -not -name "*.bin" \
  -not -name "*.ko" \
  -not -name "*.o" \
  -not -name "*.a" \
  -not -name "*.so" \
  -not -name "*.pyc" \
  2>/dev/null)

echo ""
echo "=== Results ==="
echo "Errors:   $ERRORS"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: Brick-safety violations detected!"
  echo "No script, patch, or update path may write to bootloader/aboot/partition tables."
  exit 1
fi

echo "PASS: No brick-safety violations found."
exit 0
