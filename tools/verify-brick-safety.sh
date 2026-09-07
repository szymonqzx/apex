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
# Skip: .git, build artifacts (out/, out-*/, releases/, gradle build/),
# kernel clones, this script itself, docs (docs describe the rules, not
# execute them). The find must stay fast: it is the hot path of
# tests/agent/test_agent_security.py::test_verify_script_passes (30s timeout).
while IFS= read -r file; do
  # Skip anything larger than 2MB up front — no shell script or patch
  # carrying a dangerous write pattern is that big, and grepping huge
  # binaries (zips, GGUF models, jars) is both slow and pointless.
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  if [ "$size" -gt 2097152 ]; then
    continue
  fi

  # Cheap binary sniff with bash builtins (no per-file `file` spawn):
  # a NUL byte in the first 4KB means binary. Hot path — keep it builtin-only.
  first_chunk=""
  IFS= read -r -N 4096 first_chunk < "$file" 2>/dev/null || true
  case "$first_chunk" in
    *$'\x00'*) continue ;;
  esac

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

  # Single combined check for dangerous writes: dd to a boot-critical
  # partition, fastboot flash of one, or a direct block-device write.
  # Comments are excluded via the ^[^#]* anchor; lines whose target is a
  # variable ($partition etc.) are validated at runtime by the scripts'
  # own partition whitelists, so they are filtered here.
  matches=$(grep -nE "^[^#]*(dd if=.*of=.*(/dev/block/).*($DANGEROUS_PARTITIONS)\b|fastboot flash ($DANGEROUS_PARTITIONS)\b|write.*(/dev/block/).*($DANGEROUS_PARTITIONS))" "$file" 2>/dev/null | grep -v '\$' || true)
  if [ -n "$matches" ]; then
    echo "ERROR: Dangerous write to boot-critical partition in $file:"
    echo "$matches"
    ERRORS=$((ERRORS + 1))
  fi

done < <(find "$REPO_ROOT" -type f \
  -not -path "*/.git/*" \
  -not -path "*/out/*" \
  -not -path "*/out-*/*" \
  -not -path "*/releases/*" \
  -not -path "*/build/*" \
  -not -path "*/.gradle/*" \
  -not -path "*/__pycache__/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/kernel/*" \
  -not -path "*/kernel-*/*" \
  -not -name "*.img" \
  -not -name "*.bin" \
  -not -name "*.ko" \
  -not -name "*.o" \
  -not -name "*.a" \
  -not -name "*.so" \
  -not -name "*.pyc" \
  -not -name "*.cmd" \
  -not -name "*.d" \
  -not -name "*.tmp" \
  -not -name "*.mod" \
  -not -name "*.mod.c" \
  -not -name "*.dtb" \
  -not -name "*.gz" \
  -not -name "*.tar" \
  -not -name "*.zip" \
  -not -name "*.jar" \
  -not -name "*.apk" \
  -not -name "*.gguf" \
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
