#!/usr/bin/env bash
# patches/apex-autoload/apply.sh — USB VID:PID module autoloader.
#
# Installs apex_autoload.c into drivers/usb/core/ and patches hub.c to
# call apex_usb_autoload() from usb_new_device().
#
# Idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

SRC="$HERE/src/apex_autoload.c"
DST_DIR="$KERNEL/drivers/usb/core"
DST="$DST_DIR/apex_autoload.c"

[ -d "$KERNEL" ] || {
  echo "kernel tree not found: $KERNEL" >&2
  exit 1
}

# 1. Source file
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "apex_autoload.c already installed"
else
  cp "$SRC" "$DST"
  echo "installed $DST"
fi

# 2. Makefile: add apex_autoload.o to drivers/usb/core/Makefile
if ! grep -q "apex_autoload" "$DST_DIR/Makefile"; then
  printf '\nobj-$(CONFIG_APEX_USB_AUTOLOAD) += apex_autoload.o\n' >>"$DST_DIR/Makefile"
  echo "appended apex_autoload.o to drivers/usb/core/Makefile"
else
  echo "apex_autoload Makefile already present"
fi

# 3. Kconfig: add config entry to drivers/usb/core/Kconfig
if ! grep -q "APEX_USB_AUTOLOAD" "$DST_DIR/Kconfig"; then
  cat >>"$DST_DIR/Kconfig" <<'EOF'

config APEX_USB_AUTOLOAD
	bool "apex USB VID:PID module autoloader"
	depends on USB
	help
	  Autoloads kernel modules for known USB adapters (Wi-Fi monitor,
	  SDR, CAN, UART/SPI/JTAG bridges, IR) when they are plugged in.
	  Uses request_module() from usb_new_device() context.
EOF
  echo "appended APEX_USB_AUTOLOAD to drivers/usb/core/Kconfig"
else
  echo "APEX_USB_AUTOLOAD Kconfig already present"
fi

# 4. Patch hub.c to call apex_usb_autoload() from usb_new_device()
HUB_FILE="$DST_DIR/hub.c"
if [ -f "$HUB_FILE" ] && ! grep -q "apex_usb_autoload" "$HUB_FILE"; then
  python3 - "$HUB_FILE" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add extern declaration after the last #include line
lines = content.split('\n')
last_include = 0
for i, line in enumerate(lines):
    if line.startswith('#include'):
        last_include = i
lines.insert(last_include + 1, 'extern void apex_usb_autoload(struct usb_device *udev);')
content = '\n'.join(lines)

# Insert call in usb_new_device() after the device is registered.
# We look for the end of usb_new_device() where the device is announced.
# The function typically ends with a call to usb_detect_quirks(udev) or
# similar. We insert the autoload call right before the final return.
#
# We search for the pattern in usb_new_device where the device has been
# fully initialized. The safest insertion point is right after the
# successful usb_create_sysfs_intf_entries or similar, but the most
# reliable anchor is the "/* Register the device" comment or the
# device_add() call. We use device_add() as the anchor since it's
# present in all kernel versions.

old = '\tretval = device_add(&udev->dev);'
new = '\tretval = device_add(&udev->dev);\n\n\t/* apex: autoload module for known USB adapters */\n\tapex_usb_autoload(udev);'

if old in content:
    content = content.replace(old, new, 1)
    with open(filepath, 'w') as f:
        f.write(content)
    print("patched hub.c with apex_usb_autoload() call")
else:
    # Fallback: try to insert before the final return in usb_new_device
    print("WARNING: could not find device_add() in hub.c — manual patching required")
PYEOF
else
  echo "hub.c already patched (or file not found)"
fi
