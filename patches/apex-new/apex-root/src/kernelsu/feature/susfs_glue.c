// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_glue.c — SUSFS command dispatch for KernelSU-Next
 *
 * KernelSU-Next has no prctl hook (classic KernelSU's ksu_handle_prctl).
 * The ksu_susfs userspace tool talks to the kernel via
 * prctl(KERNEL_SU_OPTION, CMD_SUSFS_*, arg3, arg4, &error), so we register
 * a prctl syscall hook with the KernelSU-Next dispatcher and route SUSFS
 * commands to fs/susfs.c.
 *
 * All other prctl calls pass through to the original handler.
 */

#include <linux/susfs.h>
#include <linux/uaccess.h>
#include <linux/uidgid.h>
#include "hook/syscall_hook.h"
#include "arch.h"
#include "klog.h"

#define KERNEL_SU_OPTION 0xDEADBEEF

static long ksu_handle_susfs_prctl(int orig_nr, const struct pt_regs *regs)
{
	unsigned long option = PT_REGS_PARM1(regs);
	unsigned long arg2 = PT_REGS_PARM2(regs);
	unsigned long arg3 = PT_REGS_PARM3(regs);
	unsigned long arg5 = PT_REGS_PARM5(regs);
	int error = 0;

	if (option != KERNEL_SU_OPTION)
		return ksu_syscall_table[orig_nr](regs);
	if (current_uid().val != 0)
		return ksu_syscall_table[orig_nr](regs);

	switch (arg2) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case CMD_SUSFS_ADD_SUS_PATH:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_path)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_path((struct st_susfs_sus_path __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_PATH -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case CMD_SUSFS_ADD_SUS_MOUNT:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_mount)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_MOUNT -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case CMD_SUSFS_ADD_SUS_KSTAT:
	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_kstat)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_KSTAT -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
	case CMD_SUSFS_UPDATE_SUS_KSTAT:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_kstat)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
		pr_info("susfs: CMD_SUSFS_UPDATE_SUS_KSTAT -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAPS
	case CMD_SUSFS_ADD_SUS_MAPS:
	case CMD_SUSFS_ADD_SUS_MAPS_STATICALLY:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_maps)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_maps((struct st_susfs_sus_maps __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_MAPS -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
	case CMD_SUSFS_UPDATE_SUS_MAPS:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_maps)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_update_sus_maps((struct st_susfs_sus_maps __user *)arg3);
		pr_info("susfs: CMD_SUSFS_UPDATE_SUS_MAPS -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_PROC_FD_LINK
	case CMD_SUSFS_ADD_SUS_PROC_FD_LINK:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_proc_fd_link)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_proc_fd_link((struct st_susfs_sus_proc_fd_link __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_PROC_FD_LINK -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MEMFD
	case CMD_SUSFS_ADD_SUS_MEMFD:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_sus_memfd)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_sus_memfd((struct st_susfs_sus_memfd __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_SUS_MEMFD -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	case CMD_SUSFS_ADD_TRY_UMOUNT:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_try_umount)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_add_try_umount((struct st_susfs_try_umount __user *)arg3);
		pr_info("susfs: CMD_SUSFS_ADD_TRY_UMOUNT -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case CMD_SUSFS_SET_UNAME:
		if (!access_ok((void __user *)arg3,
			       sizeof(struct st_susfs_uname)) ||
		    !access_ok((void __user *)arg5, sizeof(error)))
			return 0;
		error = susfs_set_uname((struct st_susfs_uname __user *)arg3);
		pr_info("susfs: CMD_SUSFS_SET_UNAME -> ret: %d\n", error);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case CMD_SUSFS_ENABLE_LOG:
		if (arg3 != 0 && arg3 != 1)
			return 0;
		susfs_set_log(arg3);
		copy_to_user((void __user *)arg5, &error, sizeof(error));
		return 0;
#endif
	default:
		return ksu_syscall_table[orig_nr](regs);
	}
}

void __init ksu_susfs_glue_init(void)
{
	int ret = ksu_register_syscall_hook(__NR_prctl, ksu_handle_susfs_prctl);

	pr_info("susfs_glue: prctl hook registration: %d\n", ret);
}
