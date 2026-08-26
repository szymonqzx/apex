# APEX — Redmi Note 12 4G (topaz)

Private repository for the Apex system: a custom kernel, ROM overlays, Arch Linux
ARM chroot, and custom apps for the Redmi Note 12 4G (Snapdragon 685, SM6225-AD,
LineageOS 21/22 with real GApps).

**Theory only at this stage.** No kernel source is cloned, no patches are applied,
no overlays are flashed, no chroot is built, and no apps are compiled. The
repository currently holds the design spec, the build plan, and empty stubs
describing what will eventually live in each file.

## Layout

```
apex/
├── docs/
│   ├── DESIGN.md            # Full system design (15 sections)
│   └── BUILD_PLAN.md        # Step-by-step build (9 steps)
├── defconfig/               # Kernel defconfig fragments
├── patches/                 # Kernel patches, one directory per patch
├── kernel/                  # Placeholder for kernel source clone
├── rom-overlays/            # Dirty-applied ROM overlays
│   ├── build.prop/          # ro.build.* spoofing for PIF
│   ├── init.d/              # apex_power.rc
│   ├── thermald/            # thermald.conf
│   ├── selinux/             # apex_chown.te
│   └── bin/                 # apex-alarmkeeper
├── anykernel3/              # AnyKernel3 zip layout
├── chroot/                  # Arch Linux ARM chroot
│   ├── rootfs/              # Pre-baked rootfs tarball
│   ├── bridge/              # apex-bridge protocol + Android app
│   └── pkglist/             # Pentest package list
├── apps/                    # Custom apps
│   ├── apex-control/        # Compose app (primary cockpit)
│   ├── nfcforge/            # NFC attack module
│   └── ptk-tui/             # Terminal TUI module
├── tools/                   # Build scripts
└── migration/               # Magisk → KernelSU-Next migration
```

## Status

Theory only. No flashing, no applying, no building. This repo is the source of
truth for the design; the actual code lands here as each component is drafted.
