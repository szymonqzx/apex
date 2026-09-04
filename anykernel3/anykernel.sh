# AnyKernel3 install script for the APEX kernel
# Flashed via TWRP/OrangeFox on top of the existing LineageOS install.
# No data wipe. Replaces kernel Image only.

ui_print "*******************************************************"
ui_print " APEX kernel — Redmi Note 12 4G (topaz)"
ui_print " 5.15.170 Zepharo R9 base (v0.1)"
ui_print " Bare base — no APEX patches yet"
ui_print "*******************************************************"

kernel.string="APEX kernel v0.1 for topaz (Zepharo R9 base)"

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

# Run post-install hooks
post_install_modules

ui_print "- Done! Reboot to apply."
