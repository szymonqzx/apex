### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=APEX kernel 0.4 for topaz (Zepharo R9 base)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=topaz
device.name2=tapas
device.name3=sapphiren
device.name4=sapphire
device.name5=xun
device.name6=creek
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

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# Kernel selection function
choose_kernel() {
  ui_print " "
  ui_print "Kernel Version Selection:"
  ui_print " "
  ui_print "  VOL + : non-KSU"
  ui_print "  VOL - : KSU"
  ui_print " "
  ui_print "Waiting for input... "
  ui_print " "
  ui_print " "

  while true; do
    input=$(getevent -qlc 1 2>/dev/null | grep -E "KEY_VOLUME(UP|DOWN)")
    case "$input" in
      *KEY_VOLUMEUP*)
        return 1
        ;;
      *KEY_VOLUMEDOWN*)
        return 2
        ;;
    esac
    sleep 0.1
  done
}

# Handle kernel selection
if [ -f "$AKHOME/Image.ksu" ] && [ -f "$AKHOME/Image.noksu" ]; then
  choose_kernel
  case $? in
    1)
      ui_print " "
      ui_print "Selected: non-KSU Kernel"
      mv -f "$AKHOME/Image.noksu" "$AKHOME/Image"
      ;;
    2)
      ui_print " "
      ui_print "Selected: KSU Kernel"
      mv -f "$AKHOME/Image.ksu" "$AKHOME/Image"
      ;;
  esac
elif [ -f "$AKHOME/Image" ]; then
  ui_print " "
  ui_print "Single image kernel found, flashing it"
  mv -f "$AKHOME/Image.ksu" "$AKHOME/Image"
elif [ -f "$AKHOME/Image.ksu" ]; then
  ui_print " "
  ui_print "Only KernelSU version found, flashing it"
  mv -f "$AKHOME/Image.ksu" "$AKHOME/Image"
elif [ -f "$AKHOME/Image.noksu" ]; then
  ui_print " "
  ui_print "Only Standard version found, flashing it"
  mv -f "$AKHOME/Image.noksu" "$AKHOME/Image"
fi

# boot install
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o -L "/dev/block/by-name/init_boot_a" ]; then
    split_boot # for devices with init_boot ramdisk
    flash_boot # for devices with init_boot ramdisk
else
    dump_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk
    write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
fi
## end boot install
