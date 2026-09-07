### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## APEX kernel — proper AK3 layout (2026-09-08 rebuild)
## Mirrors the proven TNF R9 AK3 structure: modern properties(), relative
## ak3-core.sh source, init_boot-aware boot install, no modules shipped.

### AnyKernel setup
# global properties
properties() { '
kernel.string=APEX kernel 0.4 for Redmi Note 12 4G (topaz/tapas) — Zepharo 5.15.211 base
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=topaz
device.name2=tapas
device.name3=gemstones
supported.versions=13-16
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# import functions/variables and setup patching — see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# --- Brick-safety: back up the original boot image before touching anything ---
# Only reads the boot partition; never writes to bootloader/aboot/xbl/tz/rpm/
# modem or partition tables.
backup_original_boot() {
  local BACKUP_DIR="/data/adb/apex/backup"
  local BACKUP_FILE="boot-backup-$(date +%Y%m%d-%H%M%S).img"
  local count
  if [ -d /data/adb ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
    dd if="$BLOCK" of="$BACKUP_DIR/$BACKUP_FILE" bs=1048576 2>/dev/null
    if [ $? -eq 0 ]; then
      count=$(ls -t "$BACKUP_DIR"/boot-backup-*.img 2>/dev/null | tail -n +4 | wc -l)
      [ "$count" -gt 0 ] && ls -t "$BACKUP_DIR"/boot-backup-*.img 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
      ui_print "- Original boot backed up to $BACKUP_DIR/$BACKUP_FILE"
    else
      ui_print "- WARNING: boot backup failed, continuing"
    fi
  fi
}

backup_original_boot

# --- Boot install (GKI 2.0 aware) ---
# topaz has a separate init_boot (ramdisk lives there, boot is kernel-only):
# with init_boot present we split the current boot and flash_boot (writes
# boot without touching init_boot's ramdisk); otherwise dump_boot + write_boot.
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o -L "/dev/block/by-name/init_boot_a" ]; then
  ui_print "- init_boot device detected, flashing boot only"
  split_boot
  flash_boot
else
  dump_boot
  write_boot
fi
## end boot install
