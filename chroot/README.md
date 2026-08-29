# chroot

APEX chroot environment for running Linux tools on Android without
modifying the host system.

## Files

| File | Purpose |
| :--- | :--- |
| `bridge/apex-bridge.c` | Userspace daemon: bridges Android framework to kernel /proc/apex/* |
| `apex-term.sh` | Wrapper script for entering the chroot |
| `apex-bridge.rc` | init.rc service definition for apex-bridge daemon |

## apex-bridge

The bridge daemon listens on `/dev/socket/apex-bridge` for JSON commands
from the Apex Control app or other privileged clients. It also monitors
display state via sysfs and writes the corresponding commands to
`/proc/apex/policy`.

Build: `cc -o apex-bridge apex-bridge.c -ljson-c -lpthread`
Install: push to `/system/bin/apex-bridge`, install `apex-bridge.rc` to
`/vendor/etc/init/`.

## apex-term

Usage: `apex-term [command...]`

- No args: interactive shell in the chroot
- With args: run command and exit

The chroot rootfs is expected at `/data/adb/apex/chroot`. The script
bind-mounts /dev, /proc, /sys, /dev/socket, /proc/apex, and /sdcard
into the chroot before entering.
