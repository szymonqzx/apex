# apex-baseband-guard

Anti-hard-brick protection: an LSM that blocks write access to critical
partitions (boot, init_boot, vendor_boot, dtbo, vbmeta*, userdata, cache,
metadata, misc, recovery) from untrusted processes (su/magisk/ksu domains).

- **Source**: vendored from `vc-teahouse/Baseband-guard` at commit
  `a54e0dc` (2026-07-26), GPL-2.0. LICENSED file preserved.
- **Adaptations**: the upstream Makefile introspects git and generates
  flask.h; replaced with a static 5.15-pinned Makefile (the kernel's own
  selinux build provides flask.h before drivers/ compile). `CONFIG_BBG=y`
  is set in `defconfig/apex_defconfig`, and `baseband_guard` is appended
  to `CONFIG_LSM`.
- **Not included**: the OPPO/realme "efisp exploit" allowlist extension —
  topaz has no efisp partition, and the toggle is cmdline-gated to OPPO
  bootloaders.
- **Integration**: registered via `DEFINE_LSM` with its own cred blob
  (`BBG_USE_DEFINE_LSM`); no SELinux objsec patching required.

## Config

- `CONFIG_BBG` — enable (default y in apex_defconfig)
- `CONFIG_BBG_BLOCK_BOOT` — also protect boot/init_boot (n by default)
- `CONFIG_BBG_BLOCK_RECOVERY` — also protect recovery (n by default)
