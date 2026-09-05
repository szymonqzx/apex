#!/usr/bin/env bash
# tools/verify-stealth.sh — verify hiding stack configuration and module structure
#
# Checks that the APEX hiding stack (Shamiko, HMA, TrickyStore, Yurikey)
# is properly configured: module props, denylist, keybox, PIF properties.
#
# Usage: ./tools/verify-stealth.sh [apex_root]
#   apex_root: path to APEX repo root (default: parent of this script's dir)
#
# Exit codes: 0 = PASS, 1 = FAIL
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX="${1:-$(cd "$HERE/.." && pwd)}"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=== APEX Hiding Stack Verification ==="
echo ""

# ── 1. Hiding stack scripts ─────────────────────────────────────────
echo "--- Hiding stack scripts ---"
for f in hiding/install_modules.sh hiding/configure_hiding.sh hiding/denylist.conf; do
  path="$APEX/$f"
  if [ -f "$path" ]; then
    ok "$f present"
    # Check shebang for scripts
    case "$f" in
      *.sh)
        if head -1 "$path" | grep -q '^#!'; then ok "  $f shebang"; else fail "  $f missing shebang"; fi
        if grep -q 'set -' "$path"; then ok "  $f has set -"; else warn "  $f no set -"; fi
        ;;
    esac
  else
    fail "$f missing"
  fi
done

# ── 2. Module packaging ─────────────────────────────────────────────
echo ""
echo "--- Module packaging ---"
if [ -f "$APEX/tools/package-hiding-stack.sh" ]; then
  ok "package-hiding-stack.sh present"
  # Check it references the right modules
  for mod in shamiko hma tricky_store yurikey zygisk_next; do
    if grep -qi "$mod" "$APEX/tools/package-hiding-stack.sh"; then
      ok "  references $mod"
    else
      warn "  missing reference to $mod"
    fi
  done
else
  fail "package-hiding-stack.sh missing"
fi

# ── 3. Denylist contents ────────────────────────────────────────────
echo ""
echo "--- Denylist configuration ---"
DENY="$APEX/hiding/denylist.conf"
if [ -f "$DENY" ]; then
  entries=$(grep -cv '^\s*#' "$DENY" || true)
  if [ "$entries" -ge 10 ]; then
    ok "denylist has $entries entries"
  else
    warn "denylist only $entries entries (expected 10+)"
  fi

  # Check critical categories are covered
  for category in "banking\|bank" "gms\|google" "stream\|netflix\|disney" "security\|kaspersky\|avast" "payment\|paypal\|venmo"; do
    if grep -qiE "$category" "$DENY"; then
      ok "  denylist covers $category"
    else
      warn "  denylist missing $category"
    fi
  done
else
  fail "denylist.conf not found"
fi

# ── 4. PIF build.prop properties ────────────────────────────────────
echo ""
echo "--- PIF (Play Integrity Fix) properties ---"
DMK="$APEX/rom-overlays/device/apex_device.mk"
if [ -f "$DMK" ]; then
  # Check for PIF-related build props
  for prop in "ro.build.fingerprint" "ro.bootimage.build.fingerprint" "ro.build.description" "ro.product.build.fingerprint"; do
    if grep -q "$prop" "$DMK"; then
      ok "  $prop in device.mk"
    else
      warn "  $prop not in device.mk"
    fi
  done
  # Check release-keys
  if grep -q 'release-keys' "$DMK"; then
    ok "  release-keys tag present"
  else
    fail "  release-keys tag missing"
  fi
  # Check security patch date
  if grep -q 'ro.build.version.security_patch' "$DMK"; then
    ok "  security patch date present"
  else
    warn "  security patch date not in device.mk"
  fi
else
  fail "device.mk not found"
fi

# ── 5. Init.d module install trigger ────────────────────────────────
echo ""
echo "--- Boot-time module install ---"
MODULES_RC="$APEX/rom-overlays/init.d/apex_modules.rc"
if [ -f "$MODULES_RC" ]; then
  ok "apex_modules.rc present"
  if grep -q 'install_modules.sh' "$MODULES_RC"; then
    ok "  references install_modules.sh"
  else
    fail "  does not reference install_modules.sh"
  fi
  if grep -q 'on property:' "$MODULES_RC"; then
    ok "  has property trigger"
  else
    warn "  no property trigger (may use on boot)"
  fi
else
  fail "apex_modules.rc not found"
fi

# ── 6. SELinux for hiding ───────────────────────────────────────────
echo ""
echo "--- SELinux considerations ---"
# Hiding stack operates in KSU/zygisk context, not custom SELinux domain
# But check that no hiding-related neverallow conflicts exist
if grep -r 'neverallow.*zygisk' "$APEX/agent/sepolicy/" 2>/dev/null; then
  warn "neverallow on zygisk in agent sepolicy — may conflict with Shamiko"
else
  ok "no zygisk neverallow in agent sepolicy"
fi

# ── 7. Hidden packages list ─────────────────────────────────────────
echo ""
echo "--- Hidden packages ---"
if grep -q 'hidden_packages' "$DMK" 2>/dev/null; then
  ok "hidden_packages referenced in device.mk"
else
  warn "hidden_packages not in device.mk"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Hiding stack verification complete ==="
echo "  Passed:    $PASS"
echo "  Warnings:  $WARN"
echo "  Failures:  $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Result: FAIL"
  exit 1
fi
echo "  Result: PASS"
exit 0
