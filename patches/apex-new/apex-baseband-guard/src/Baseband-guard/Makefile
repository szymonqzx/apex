# Baseband-guard — simplified Makefile pinned for Linux 5.15 (Zepharo R9).
# Upstream (vc-teahouse/Baseband-guard @ a54e0dc) generates flask.h and
# introspects git; both are unnecessary here: security/selinux builds before
# drivers/, so the generated flask.h already exists in the objtree.

bbg-objs += baseband_guard.o
bbg-objs += tracing/tracing.o
bbg-objs += blkdev_helper.o

ccflags-y += -I$(srctree)/security/selinux -I$(srctree)/security/selinux/include
ccflags-y += -I$(objtree)/security/selinux -I$(srctree)/block

# 5.15 feature probes (verified against this tree):
#   lsm_hook_defs.h has file_ioctl_compat
ccflags-y += -DBB_HAS_IOCTL_COMPAT
#   security/selinux/include/security.h has selinux_state
ccflags-y += -DBB_HAS_SELINUX_STATE
#   include/linux/genhd.h has no disk_get_part (modern block API)
ccflags-y += -DBBG_COMPAT_HAS_BLOCK_DEVICE_API
#   include/linux/lsm_hooks.h has DEFINE_LSM -> use the standard LSM blob
ccflags-y += -DBBG_USE_DEFINE_LSM

ccflags-y += -DBBG_VERSION=\"apex-0.3.0\"
ccflags-y += -DBBG_REPO=\"vc-teahouse/Baseband-guard\"

obj-$(CONFIG_BBG) += bbg.o
