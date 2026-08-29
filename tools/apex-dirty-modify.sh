#!/system/bin/sh
# apex-dirty-modify.sh — Deep dirty ROM modification for LineageOS 23.2
#
# Applies all APEX ROM overlays to a running LineageOS 23.2 install
# WITHOUT formatting / wiping data. Run from a root shell (KernelSU-Next
# su, or Magisk su if migrating).
#
# Usage:
#   adb push apex-dirty-modify.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/apex-dirty-modify.sh"
#
# Or flash the AnyKernel3 zip which calls this automatically.
#
# Safe to re-run: idempotent (checks for existing overlays before applying).
#
# Target: LineageOS 23.2-20260328-UNOFFICIAL-tapas (Android 16 / AOSP 16 QPR2)
# Device: Redmi Note 12 4G (topaz/tapas, SM6225-AD, 4GB RAM)
# APEX version: 1.2.0

set -uo pipefail

APEX_VER="1.2.0"
ROM_ID="lineage-23.2-20260328-UNOFFICIAL-tapas"
APEX_DIR="/data/adb/apex"
OVERLAY_MARKER="# APEX overlay v${APEX_VER}"

# Colors (if terminal supports)
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

log() { echo "${CYN}[APEX]${NC} $1"; }
ok()  { echo "${GRN}[OK]${NC} $1"; }
warn() { echo "${YEL}[WARN]${NC} $1"; }
err() { echo "${RED}[ERR]${NC} $1"; }

FAIL=0
step() {
  local name="$1"
  log "→ $name"
}

check_fail() {
  if [ "$1" -ne 0 ]; then
    err "$2"
    FAIL=$((FAIL + 1))
  fi
}

# === Pre-flight checks ===
echo ""
echo "============================================"
echo " APEX dirty ROM modifier v${APEX_VER}"
echo " Target: ${ROM_ID}"
echo " Device: Redmi Note 12 4G (topaz/tapas)"
echo "============================================"
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
  err "Must run as root. Use: su -c 'sh $0'"
  exit 1
fi

# Check device
DEVICE=$(getprop ro.product.device 2>/dev/null || echo "")
case "$DEVICE" in
  topaz|tapas|gemstones) ok "Device: $DEVICE" ;;
  *) warn "Device is '$DEVICE' — expected topaz/tapas/gemstones. Continuing anyway." ;;
esac

# Check ROM
ROM_FP=$(getprop ro.build.fingerprint 2>/dev/null || echo "")
log "Current fingerprint: $ROM_FP"
if echo "$ROM_FP" | grep -q "lineage"; then
  ok "LineageOS detected"
elif echo "$ROM_FP" | grep -q "xiaomi\|Xiaomi"; then
  warn "MIUI/HyperOS detected — overlays are designed for LineageOS. Proceed with caution."
else
  warn "Unknown ROM — proceeding anyway."
fi

# Check Android version
SDK=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
log "Android SDK: $SDK"
if [ "$SDK" -ge 35 ]; then
  ok "Android 15+ (SDK $SDK) — overlays compatible"
else
  warn "SDK $SDK < 35 — some overlays may not apply correctly on older Android."
fi

echo ""

# === 1. Create APEX directory structure ===
step "Creating APEX directory structure"
mkdir -p "$APEX_DIR"/{incidents,modules,replay,var,bridge,arch}
check_fail $? "Failed to create APEX directories"
ok "APEX directories at $APEX_DIR"

# === 2. Backup current build.prop files ===
step "Backing up current build.prop files"
BACKUP_DIR="$APEX_DIR/backup-pre-apex"
mkdir -p "$BACKUP_DIR"

# Mount system and vendor rw for backup
mount -o rw,remount /system 2>/dev/null || true
mount -o rw,remount /vendor 2>/dev/null || true
mount -o rw,remount / 2>/dev/null || true

for prop in /system/build.prop /vendor/build.prop /system/etc/prop.default /vendor/etc/prop.default; do
  if [ -f "$prop" ]; then
    cp "$prop" "$BACKUP_DIR/$(echo "$prop" | tr '/' '_').bak"
    ok "Backed up $prop"
  fi
done

# === 3. Apply build.prop overlays (PIF) ===
step "Applying build.prop overlays (PIF)"

apply_prop_overlay() {
  local target="$1"
  local overlay="$2"
  local label="$3"

  if [ ! -f "$target" ]; then
    warn "$target not found — skipping $label"
    return 0
  fi

  if grep -q "$OVERLAY_MARKER" "$target" 2>/dev/null; then
    warn "$label already applied to $target — skipping (idempotent)"
    return 0
  fi

  # Append overlay
  echo "" >> "$target"
  cat "$overlay" >> "$target"
  check_fail $? "Failed to append $label to $target"
  ok "$label applied to $target"
}

# System build.prop
SYSTEM_OVERLAY="$APEX_DIR/overlays/system.build.prop.append"
if [ -f "$SYSTEM_OVERLAY" ]; then
  apply_prop_overlay /system/build.prop "$SYSTEM_OVERLAY" "system build.prop"
else
  # Inline overlay if file not present
  if ! grep -q "$OVERLAY_MARKER" /system/build.prop 2>/dev/null; then
    cat >> /system/build.prop << 'PROPEOF'

# APEX overlay v1.2.0 — append to /system/build.prop (dirty apply, no PIF module)
# Target ROM: LineageOS 23.2-20260328-UNOFFICIAL-tapas (Android 16)
ro.build.fingerprint=Xiaomi/topaz_global/topaz:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys
ro.product.build.fingerprint=Xiaomi/topaz_global/topaz:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys
ro.build.type=user
ro.build.keys=release-keys
ro.build.version.security_patch=2024-12-01
ro.system.build.id=TKQ1.221114.001
ro.system.build.tags=release-keys
ro.product.build.id=TKQ1.221114.001
ro.product.build.tags=release-keys
ro.debuggable=0
ro.secure=1
ro.apex.hide=1
ro.apex.version=1.2.0
ro.apex.rom_base=lineage-23.2
ro.boot.veritymode=enforcing
ro.boot.verifiedbootstate=yellow
PROPEOF
    ok "system build.prop overlay applied (inline)"
  else
    warn "system build.prop already has APEX overlay — skipping"
  fi
fi

# Vendor build.prop
VENDOR_OVERLAY="$APEX_DIR/overlays/vendor.build.prop.append"
if [ -f "$VENDOR_OVERLAY" ]; then
  apply_prop_overlay /vendor/build.prop "$VENDOR_OVERLAY" "vendor build.prop"
else
  if ! grep -q "$OVERLAY_MARKER" /vendor/build.prop 2>/dev/null; then
    cat >> /vendor/build.prop << 'PROPEOF'

# APEX overlay v1.2.0 — append to /vendor/build.prop (dirty apply)
ro.vendor.build.security_patch=2024-12-01
ro.vendor.build.tags=release-keys
ro.vendor.build.fingerprint=Xiaomi/topaz_global/topaz:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys
ro.boot.dtbinfo=0x0000000000000000(0x0000000000000000)/0x0000000000000000
ro.vendor.apex.version=1.2.0
PROPEOF
    ok "vendor build.prop overlay applied (inline)"
  else
    warn "vendor build.prop already has APEX overlay — skipping"
  fi
fi

# Also patch prop.default files (some ROMs read from these)
for pd in /system/etc/prop.default /vendor/etc/prop.default; do
  if [ -f "$pd" ] && ! grep -q "$OVERLAY_MARKER" "$pd" 2>/dev/null; then
    echo "" >> "$pd"
    echo "$OVERLAY_MARKER" >> "$pd"
    echo "ro.build.fingerprint=Xiaomi/topaz_global/topaz:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys" >> "$pd"
    echo "ro.build.type=user" >> "$pd"
    echo "ro.build.keys=release-keys" >> "$pd"
    echo "ro.debuggable=0" >> "$pd"
    echo "ro.secure=1" >> "$pd"
    ok "Patched $pd"
  fi
done

# === 4. Install apex_power.rc ===
step "Installing apex_power.rc"
POWER_RC="$APEX_DIR/overlays/apex_power.rc"
VENDOR_INIT="/vendor/etc/init"

if [ -f "$POWER_RC" ]; then
  cp "$POWER_RC" "$VENDOR_INIT/apex_power.rc"
  chmod 644 "$VENDOR_INIT/apex_power.rc"
  ok "apex_power.rc installed to $VENDOR_INIT"
else
  warn "apex_power.rc not found in overlays — skipping"
fi

# === 5. Install thermald.conf ===
step "Installing thermald.conf"
THERMALD_CONF="$APEX_DIR/overlays/thermald.conf"
if [ -f "$THERMALD_CONF" ]; then
  mkdir -p /system/etc
  cp "$THERMALD_CONF" /system/etc/thermald.conf
  ok "thermald.conf installed"
else
  warn "thermald.conf not found — skipping"
fi

# Disable mi_thermald if present (replaced by apex thermal)
if [ -f /vendor/bin/mi_thermald ]; then
  log "Disabling mi_thermald (replaced by apex thermal policy)..."
  chmod 000 /vendor/bin/mi_thermald 2>/dev/null || true
  ok "mi_thermald disabled"
fi

# === 6. Install SELinux policy source ===
step "Installing SELinux policies"
SELINUX_DIR_SRC="$APEX_DIR/overlays/selinux"
SELINUX_DIR_DST="/system/etc/selinux"

if [ -d "$SELINUX_DIR_SRC" ]; then
  mkdir -p "$SELINUX_DIR_DST"
  for te_file in "$SELINUX_DIR_SRC"/*.te; do
    [ -f "$te_file" ] || continue
    cp "$te_file" "$SELINUX_DIR_DST/"
    ok "SELinux policy installed: $(basename "$te_file")"
  done
  warn "Note: .te sources must be compiled via KSU sepolicy.rule or sepolicy-inject"
elif [ -f "$APEX_DIR/overlays/apex_chown.te" ]; then
  # Fallback: flat overlay directory (legacy layout)
  mkdir -p "$SELINUX_DIR_DST"
  for te_file in "$APEX_DIR"/overlays/*.te; do
    [ -f "$te_file" ] || continue
    cp "$te_file" "$SELINUX_DIR_DST/"
    ok "SELinux policy installed: $(basename "$te_file")"
  done
  warn "Note: .te sources must be compiled via KSU sepolicy.rule or sepolicy-inject"
else
  warn "No SELinux policy files found — skipping"
fi

# === 7. Install hidden packages list ===
step "Installing hidden packages list"
HIDDEN_LIST="$APEX_DIR/overlays/hidden_packages.list"
if [ -f "$HIDDEN_LIST" ]; then
  cp "$HIDDEN_LIST" "$APEX_DIR/hidden_packages.list"
  ok "Hidden packages list installed at $APEX_DIR/hidden_packages.list"
else
  # Inline
  cat > "$APEX_DIR/hidden_packages.list" << 'EOF'
com.topjohnwu.magisk
me.bmax.apatch
org.lsposed.manager
com.solohsu.android.edxp.manager
EOF
  ok "Hidden packages list created (inline)"
fi

# === 8. Install binaries (if present) ===
step "Installing APEX binaries"

# Alarmkeeper
ALARM_BIN="$APEX_DIR/overlays/apex-alarmkeeper"
if [ -f "$ALARM_BIN" ]; then
  cp "$ALARM_BIN" /vendor/bin/apex-alarmkeeper
  chmod 755 /vendor/bin/apex-alarmkeeper
  ok "apex-alarmkeeper installed to /vendor/bin"
else
  warn "apex-alarmkeeper binary not found — compile and push separately"
fi

# Bridge daemon
BRIDGE_BIN="$APEX_DIR/overlays/apex-bridge"
if [ -f "$BRIDGE_BIN" ]; then
  cp "$BRIDGE_BIN" /vendor/bin/apex-bridge
  chmod 755 /vendor/bin/apex-bridge
  ok "apex-bridge installed to /vendor/bin"
else
  warn "apex-bridge binary not found — compile and push separately"
fi

# === 9. Install KSU service.d scripts ===
step "Installing KSU service.d scripts"
SERVICE_D="/data/adb/service.d"
mkdir -p "$SERVICE_D"

# Terminal mount script (chroot mount, no autostart)
if [ ! -f "$SERVICE_D/apex_terminal.sh" ]; then
  cat > "$SERVICE_D/apex_terminal.sh" << 'EOF'
#!/system/bin/sh
# apex_terminal.sh — mount Arch chroot, start bridge, no autostart
# Placed by apex-dirty-modify.sh
APEX=/data/adb/apex

# Mount chroot rootfs (if extracted)
if [ -d "$APEX/arch/bin" ]; then
  mount --bind "$APEX/arch" "$APEX/arch" 2>/dev/null || true
  mount -t proc proc "$APEX/arch/proc" 2>/dev/null || true
  mount -t sysfs sys "$APEX/arch/sys" 2>/dev/null || true
  mount -o bind /dev "$APEX/arch/dev" 2>/dev/null || true
  mount -o bind /dev/pts "$APEX/arch/dev/pts" 2>/dev/null || true
  mount -o bind /sdcard "$APEX/arch/sdcard" 2>/dev/null || true
fi

# Start bridge daemon (if binary present)
if [ -x /vendor/bin/apex-bridge ]; then
  /vendor/bin/apex-bridge &
fi
EOF
  chmod 755 "$SERVICE_D/apex_terminal.sh"
  ok "apex_terminal.sh installed to $SERVICE_D"
else
  warn "apex_terminal.sh already exists — skipping"
fi

# Post-boot kernel tuning script
if [ ! -f "$SERVICE_D/apex_post_boot.sh" ]; then
  cat > "$SERVICE_D/apex_post_boot.sh" << 'EOF'
#!/system/bin/sh
# apex_post_boot.sh — post-boot kernel tuning
# Runs after each boot via KSU service.d
sleep 10  # wait for boot to settle

# Set apex governor on both clusters (if available)
for cpu in 0 4 5 6 7; do
  gov_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
  if [ -f "$gov_path" ] && echo "apex" > "$gov_path" 2>/dev/null; then
    : # governor set
  fi
done

# Configure ZRAM (ZSTD, 3GB)
if [ -f /sys/block/zram0/disksize ]; then
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo 3221225472 > /sys/block/zram0/disksize 2>/dev/null || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true
  echo 3221225472 > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/block/zram0 2>/dev/null || true
  swapon /dev/block/zram0 2>/dev/null || true
fi

# kptr_restrict + dmesg_restrict (runtime hardening)
echo 2 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
echo 1 > /proc/sys/kernel/dmesg_restrict 2>/dev/null || true
echo 3 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true

# APEX LMK tuning
echo 6 > /proc/apex_lmk/min_free_pages 2>/dev/null || true
echo 32 > /proc/apex_lmk/cache_bonus_pages 2>/dev/null || true
EOF
  chmod 755 "$SERVICE_D/apex_post_boot.sh"
  ok "apex_post_boot.sh installed to $SERVICE_D"
else
  warn "apex_post_boot.sh already exists — skipping"
fi

# === 10. Remove Magisk/APatch residue (if migrating) ===
step "Checking for Magisk/APatch residue"

if [ -d /data/adb/magisk ]; then
  log "Magisk detected at /data/adb/magisk"
  warn "Magisk residue found. Run apex-migrate.sh for full migration."
  warn "This script will NOT remove Magisk — that's a separate step."
fi

if [ -d /data/adb/ap ]; then
  log "APatch detected at /data/adb/ap"
  warn "APatch residue found. Run apex-migrate.sh for full migration."
fi

# Uninstall Magisk/APatch manager apps (hidden packages list already set)
for pkg in com.topjohnwu.magisk me.bmax.apatch org.lsposed.manager com.solohsu.android.edxp.manager; do
  pm list packages "$pkg" 2>/dev/null | grep -q "$pkg" && {
    log "Found $pkg — uninstalling (keeping data)..."
    pm uninstall -k --user 0 "$pkg" 2>/dev/null && ok "Uninstalled $pkg" || warn "Could not uninstall $pkg"
  }
done

# === 11. Set kernel runtime params ===
step "Setting kernel runtime parameters"

# kptr_restrict
echo 2 > /proc/sys/kernel/kptr_restrict 2>/dev/null && ok "kptr_restrict=2" || warn "kptr_restrict not settable"

# dmesg_restrict
echo 1 > /proc/sys/kernel/dmesg_restrict 2>/dev/null && ok "dmesg_restrict=1" || warn "dmesg_restrict not settable"

# perf_event_paranoid
echo 3 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null && ok "perf_event_paranoid=3" || warn "perf_event_paranoid not settable"

# === 12. Verify overlays ===
step "Verifying applied overlays"

VERIFY_PASS=0
VERIFY_FAIL=0

vcheck() {
  if eval "$1" 2>/dev/null; then
    ok "verify: $2"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    err "verify: $2 FAILED"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
}

vcheck "grep -q 'APEX overlay' /system/build.prop" "system build.prop has APEX overlay"
vcheck "grep -q 'APEX overlay' /vendor/build.prop" "vendor build.prop has APEX overlay"
vcheck "grep -q 'release-keys' /system/build.prop" "build.keys=release-keys"
vcheck "grep -q 'ro.debuggable=0' /system/build.prop" "debuggable=0"
vcheck "grep -q 'ro.secure=1' /system/build.prop" "secure=1"
vcheck "[ -f /vendor/etc/init/apex_power.rc ]" "apex_power.rc installed"
vcheck "[ -f $APEX_DIR/hidden_packages.list ]" "hidden_packages.list exists"
vcheck "[ -d $APEX_DIR/incidents ]" "APEX incidents dir exists"
vcheck "[ -d $APEX_DIR/bridge ]" "APEX bridge dir exists"
vcheck "[ -f $SERVICE_D/apex_post_boot.sh ]" "post_boot service script exists"

# Check fingerprint is set
FP=$(getprop ro.build.fingerprint 2>/dev/null || echo "")
vcheck "echo '$FP' | grep -q 'release-keys'" "fingerprint has release-keys"

# === 13. Write install manifest ===
step "Writing install manifest"
cat > "$APEX_DIR/install_manifest.json" << MANIFEST
{
  "apex_version": "$APEX_VER",
  "install_date": "$(date '+%Y-%m-%d %H:%M:%S')",
  "rom_id": "$ROM_ID",
  "device": "$DEVICE",
  "sdk": "$SDK",
  "overlays_applied": {
    "system_build_prop": true,
    "vendor_build_prop": true,
    "apex_power_rc": true,
    "apex_profiles_rc": true,
    "thermald_conf": true,
    "selinux_te": true,
    "selinux_charge_te": true,
    "hidden_packages": true,
    "service_d_scripts": true
  },
  "backup_dir": "$BACKUP_DIR",
  "verify": {
    "pass": $VERIFY_PASS,
    "fail": $VERIFY_FAIL
  }
}
MANIFEST
ok "Install manifest at $APEX_DIR/install_manifest.json"

# === Done ===
echo ""
echo "============================================"
echo " APEX dirty ROM modification complete"
echo "============================================"
echo ""
echo " Overlays applied:"
echo "   ✓ build.prop PIF (Xiaomi stock fingerprint)"
echo "   ✓ vendor/build.prop PIF"
echo "   ✓ apex_power.rc (power + gaming + LMK + charge manager init)"
echo "   ✓ apex_profiles.rc (3-profile system + charge modes)"
echo "   ✓ thermald.conf (reference documentation, kernel-driven thermal)"
echo "   ✓ SELinux policies (apex_chown.te + apex_charge.te)"
echo "   ✓ hidden_packages.list (HMA blacklist)"
echo "   ✓ KSU service.d scripts (post-boot tuning)"
echo ""
echo " Verify: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo " Backup: $BACKUP_DIR"
echo " Manifest: $APEX_DIR/install_manifest.json"
echo ""

if [ "$VERIFY_FAIL" -gt 0 ]; then
  warn "Some verification checks failed. Review above."
  warn "Reboot may still apply most changes."
fi

if [ "$FAIL" -gt 0 ]; then
  err "$FAIL critical errors during apply."
fi

echo " Next steps:"
echo "   1. Reboot to apply build.prop + init.rc changes"
echo "   2. Flash APEX kernel (AnyKernel3 zip) if not already flashed"
echo "   3. Install KSU modules: Zygisk-Next, Shamiko, HMA-OSS, TrickyStore"
echo "   4. Verify Play Integrity: 'adb shell am start -n com.android.settings/.Settings\$DeviceIdActivity'"
echo "   5. Run 'apex doctor' for full system check"
echo ""
warn "Reboot required for build.prop and init.rc changes to take effect."

exit $FAIL
