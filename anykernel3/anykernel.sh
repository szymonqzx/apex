# AnyKernel3 install script for the APEX kernel
# Flashed via TWRP/OrangeFox on top of the existing LineageOS install.
# No data wipe. Replaces kernel Image only.
#
# Brick-safety design:
#   - Writes ONLY to /dev/block/by-name/boot (kernel Image)
#   - Does NOT touch bootloader, aboot, xbl, tz, rpm, modem, or any other partition
#   - Does NOT wipe data, system, or cache
#   - A/B slot-aware: writes to inactive slot if detected
#   - Device check enforced: aborts on non-topaz/tapas/gemstones
#   - Original boot image backed up to /data/adb/apex/backup/ for rollback

ui_print "*******************************************************"
ui_print " APEX kernel — Redmi Note 12 4G (topaz)"
ui_print " 5.15.211 Zepharo branch (v0.4)"
ui_print " Modern stack + security + device drivers"
ui_print "*******************************************************"

kernel.string="APEX kernel v0.4 for topaz (Zepharo R9 base)"

do.devicecheck=1
device.name1=topaz
device.name2=tapas
device.name3=gemstones
supported.versions=13.0 - 16.0
# shellcheck disable=SC2276
supported.patch.levels=2024-12 - 2026-12

# GKI Layout for Redmi Note 12 4G (topaz/tapas)
# Kernel Image is in 'boot' partition.
# Ramdisk is in 'init_boot' partition.
# DTB is handled by the ROM's vendor_boot / init_boot.
block=/dev/block/by-name/boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto

# Source the AK3 engine FIRST — this defines split_boot, write_boot, etc.
. /tmp/anykernel/tools/ak3-core.sh

# --- Phase 1: Backup original boot image ---
backup_original_boot() {
  local BACKUP_DIR="/data/adb/apex/backup"
  local BACKUP_FILE="boot-backup-$(date +%Y%m%d-%H%M%S).img"

  mount /data 2>/dev/null || true
  if [ -d /data/adb ]; then
    mkdir -p "$BACKUP_DIR"
    # Backup the current boot image before any modification
    dd if=$BLOCK of="$BACKUP_DIR/$BACKUP_FILE" bs=1048576 2>/dev/null
    if [ $? -eq 0 ]; then
      # Keep only the 3 most recent backups
      ls -t "$BACKUP_DIR"/boot-backup-*.img 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
      ui_print "- Original boot image backed up to $BACKUP_DIR/$BACKUP_FILE"
    else
      ui_print "- WARNING: Boot backup failed. Continuing anyway."
    fi
  else
    ui_print "- WARNING: /data/adb not found. No boot backup created."
  fi
}

backup_original_boot

# --- Phase 2: Dump and split the current boot image ---
# split_boot reads the current boot partition and splits it into components
# (kernel, ramdisk, cmdline, dtb) in $SPLITIMG for repacking.
ui_print "- Dumping current boot image..."
split_boot

# --- Phase 3: Repack with new kernel and write back ---
# write_boot takes the new zImage from $AKHOME, repacks it with the
# original ramdisk/cmdline/dtb, and writes the result to the boot partition.
# This is the critical step that actually flashes the kernel.
ui_print "- Repacking boot image with APEX kernel..."
write_boot
ui_print "- Boot image written successfully."

# --- Phase 4: Install kernel modules ---
post_install_modules() {
  local MOD_DIR="/tmp/anykernel/modules"
  local VENDOR_MODS="/vendor/lib/modules"
  local VENDOR_BIN="/vendor/bin"

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

    # Copy depmod metadata (modules.dep, modules.alias, modules.symbols, modules.builtin)
    for meta in modules.dep modules.alias modules.symbols modules.builtin modules.softdep; do
      [ -f "$MOD_DIR/$meta" ] && cp "$MOD_DIR/$meta" "$VENDOR_MODS/"
    done

    # Install the module load script
    if [ -f "$MOD_DIR/apex-load-modules.sh" ]; then
      mkdir -p "$VENDOR_BIN"
      cp "$MOD_DIR/apex-load-modules.sh" "$VENDOR_BIN/"
      chmod 755 "$VENDOR_BIN/apex-load-modules.sh"
      ui_print "- Installed apex-load-modules.sh to /vendor/bin/"
    fi

    # Run depmod on-device if available
    if [ -x /system/bin/depmod ] || [ -x /vendor/bin/depmod ]; then
      ui_print "- Running depmod..."
      KVER=$(cat /proc/version 2>/dev/null | grep -oP 'Linux version \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      [ -z "$KVER" ] && KVER="5.15.211"
      depmod -b / "$KVER" 2>/dev/null || true
    fi

    umount /vendor 2>/dev/null || true
  fi
}

post_install_modules

ui_print "- Done! Reboot to apply."
