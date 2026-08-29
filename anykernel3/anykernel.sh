# AnyKernel3 install script for the APEX kernel
# Flashed via TWRP/OrangeFox on top of the existing LineageOS install.
# No data wipe. Replaces kernel Image only.

ui_print "*******************************************************"
ui_print " APEX kernel — Redmi Note 12 4G (topaz)"
ui_print " 5.15.189 + KernelSU-Next + SuSFS + apex"
ui_print " Governor: apex (non-linear power curve + iowait boost)"
ui_print " Scheduler: CASS + WALT + schedutil fallback"
ui_print "*******************************************************"

kernel.string="APEX kernel for topaz (Redmi Note 12 4G)"

do.devicecheck=1
device.name1=topaz
device.name2=tapas
device.name3=gemstones
supported.versions=13.0 - 16.0
supported.patchlevels=2024-12 - 2026-12

# GKI Layout for Redmi Note 12 4G (topaz/tapas)
# Kernel Image is in 'boot' partition.
# Ramdisk is in 'init_boot' partition.
# DTB is handled by the ROM's vendor_boot / init_boot.
block=/dev/block/by-name/boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto

# --- BBG efisp exploit menu (volume key selection) ---
# If the device uses the efisp exploit, the user can whitelist abl/efisp
# partitions for flashing by pressing VOL+. Default (VOL-) keeps full BBG.
ui_print " "
ui_print "=========================================="
ui_print " Baseband Guard: efisp exploit mode?     "
ui_print "------------------------------------------"
ui_print "  [VOL+] - Yes: whitelist abl + efisp    "
ui_print "  [VOL-] - No:  full BBG security        "
ui_print "=========================================="
ui_print " "
handle_input
KEY_RESULT=$(cat /tmp/ak3_key_result 2>/dev/null)
case "$KEY_RESULT" in
  "KEY_VOLUMEUP")
    ui_print "  -> BBG: efisp exploit mode (abl/efisp whitelisted)"
    patch_cmdline "oplusboot.secure_user_mode" "oplusboot.secure_user_mode=0"
    ;;
  "KEY_VOLUMEDOWN"|"TIMEOUT"|*)
    ui_print "  -> BBG: full security mode"
    patch_cmdline "oplusboot.secure_user_mode" ""
    ;;
esac

# Use split_boot to replace only the kernel Image in the boot partition.
# This skips the ramdisk unpack/repack cycle, which is critical for GKI.
# We do NOT provide a custom DTB; we use the ROM's original DTB/DTBO.
split_boot

# Run official AK3 engine
. /tmp/anykernel/tools/ak3-core.sh

# --- Post-install: push modules ---
post_install_modules() {
  local MOD_DIR="/tmp/anykernel/modules"
  local VENDOR_MODS="/vendor/lib/modules"

  if [ -d "$MOD_DIR" ]; then
    ui_print "- Installing kernel modules..."
    mount /vendor 2>/dev/null || true
    mkdir -p "$VENDOR_MODS"

    local count=0
    for ko in "$MOD_DIR"/*.ko; do
      [ -f "$ko" ] || continue
      cp "$ko" "$VENDOR_MODS/"
      chmod 644 "$VENDOR_MODS/$(basename "$ko")"
      count=$((count + 1))
    done
    ui_print "- Installed $count kernel modules"
    umount /vendor 2>/dev/null || true
  fi
}

# --- Post-install: push ROM overlays ---
post_install_overlays() {
  local OVERLAY_DIR="/tmp/anykernel/overlays"
  [ -d "$OVERLAY_DIR" ] || return 0

  ui_print "- Installing ROM overlays..."

  # Mount partitions rw
  mount /system 2>/dev/null || true
  mount /vendor 2>/dev/null || true

  # build.prop overlays (PIF)
  if [ -f "$OVERLAY_DIR/system.build.prop.append" ]; then
    ui_print "- Appending system build.prop overlay..."
    cat "$OVERLAY_DIR/system.build.prop.append" >> /system/build.prop
  fi

  if [ -f "$OVERLAY_DIR/vendor.build.prop.append" ]; then
    ui_print "- Appending vendor build.prop overlay..."
    cat "$OVERLAY_DIR/vendor.build.prop.append" >> /vendor/build.prop
  fi

  # init.rc (power management)
  if [ -f "$OVERLAY_DIR/apex_power.rc" ]; then
    ui_print "- Installing apex_power.rc..."
    cp "$OVERLAY_DIR/apex_power.rc" /vendor/etc/init/
    chmod 644 /vendor/etc/init/apex_power.rc
  fi

  # profiles.rc (three-switchable-profile system)
  if [ -f "$OVERLAY_DIR/apex_profiles.rc" ]; then
    ui_print "- Installing apex_profiles.rc..."
    cp "$OVERLAY_DIR/apex_profiles.rc" /vendor/etc/init/
    chmod 644 /vendor/etc/init/apex_profiles.rc
  fi

  # thermald config
  if [ -f "$OVERLAY_DIR/thermald.conf" ]; then
    ui_print "- Installing thermald.conf..."
    mkdir -p /system/etc/
    cp "$OVERLAY_DIR/thermald.conf" /system/etc/
  fi

  # SELinux policy (source .te — compiled via KSU module or sepolicy-inject)
  # Install all .te policy files from the overlay directory
  for te_file in "$OVERLAY_DIR"/*.te; do
    [ -f "$te_file" ] || continue
    ui_print "- Installing SELinux policy: $(basename "$te_file")"
    mkdir -p /system/etc/selinux/
    cp "$te_file" /system/etc/selinux/
  done

  # Hidden packages list (consumed by HMA-OSS)
  if [ -f "$OVERLAY_DIR/hidden_packages.list" ]; then
    ui_print "- Installing hidden packages list..."
    mkdir -p /data/adb/apex/
    cp "$OVERLAY_DIR/hidden_packages.list" /data/adb/apex/
  fi

  # Alarmkeeper binary (if pre-compiled for aarch64)
  if [ -f "$OVERLAY_DIR/apex-alarmkeeper" ]; then
    ui_print "- Installing alarmkeeper binary..."
    cp "$OVERLAY_DIR/apex-alarmkeeper" /vendor/bin/
    chmod 755 /vendor/bin/apex-alarmkeeper
  fi

  # Bridge binary (if pre-compiled for aarch64)
  if [ -f "$OVERLAY_DIR/apex-bridge" ]; then
    ui_print "- Installing bridge daemon binary..."
    cp "$OVERLAY_DIR/apex-bridge" /vendor/bin/
    chmod 755 /vendor/bin/apex-bridge
  fi

  # APEX directory structure
  mkdir -p /data/adb/apex/{incidents,modules,replay,var,bridge,arch}

  # Unmount
  umount /system 2>/dev/null || true
  umount /vendor 2>/dev/null || true

  ui_print "- ROM overlays installed"
}

# Run post-install hooks
post_install_modules
post_install_overlays

ui_print "- Done! Reboot to apply."
