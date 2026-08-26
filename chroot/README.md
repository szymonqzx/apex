# Arch Linux ARM chroot

On-demand pentest toolbox, mounted but idle. **Nothing is built yet.**

## Plan

| Path | Purpose |
| :--- | :--- |
| `rootfs/` | Pre-baked Arch Linux ARM aarch64 rootfs (not yet downloaded) |
| `bridge/apex-bridge.c` | Android-side Binder + HAL bridge source |
| `bridge/apex-bridge` | Compiled Android binary (will live at /vendor/bin) |
| `bridge/protocol.md` | Line-delimited JSON protocol spec |
| `pkglist/00-base.pkglist` | Base packages (vim, git, base-devel) |
| `pkglist/10-pentest.pkglist` | aircrack-ng, can-utils, mfoc, mfcuk, crapto1, gqrx, rtl-sdr, sox |
| `pkglist/20-re.pkglist` | Reverse engineering tools |
| `pkglist/30-net.pkglist` | nmap, masscan, scapy |

## Status

Empty. Theory only. The rootfs tarball will be downloaded in step 7 of the
build plan, which has not started.
