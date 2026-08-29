// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/apex/apex_immortal.c
 *
 * apex OOM-immortal task whitelist (Redmi Note 12 4G, SM6225-AD)
 *
 * Provides apex_oom_immortal() which checks task->comm against a whitelist
 * of critical task names. Tasks on this list are never selected as OOM
 * victims by the kernel's OOM killer.
 *
 * The whitelist includes:
 *   - desk clock (com.android.deskclock -> task->comm "com.android.de")
 *   - poweroff alarm (com.qualcomm.qti.poweroffalarm -> "com.qualcomm.q")
 *   - apex-bridge (userspace daemon -> "apex-bridge")
 *   - apex-alarmkeeper (RTC alarm keeper -> "alarmkeeper")
 *   - apex-control (Apex Control app -> "apex-control")
 *
 * NOTE: Android sets task->comm to the process name, which is typically
 * the package name truncated to 15 chars (TASK_COMM_LEN=16 including NUL).
 * The built-in entries below use the actual truncated values that will
 * appear in task->comm, not the full package names.
 *
 * The mm/oom_kill.c patch (apex-immortal/apply.sh) calls apex_oom_immortal()
 * during OOM victim selection. If it returns true, the task is skipped.
 *
 * A sysctl knob (kernel.apex_oom_whitelist) allows runtime additions.
 * Writing to the sysctl replaces the entire runtime list (clear + add).
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": "

#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/sysctl.h>
#include <linux/uaccess.h>

#define APEX_IMMORTAL_MAX_ENTRIES	16
#define APEX_COMM_LEN			16	/* TASK_COMM_LEN */

struct apex_immortal_entry {
	char comm[APEX_COMM_LEN];
	struct list_head list;
};

static LIST_HEAD(apex_immortal_list);
static DEFINE_SPINLOCK(apex_immortal_lock);
static unsigned int apex_immortal_count;

/* Built-in whitelist: critical tasks that must never be OOM-killed.
 * task->comm is truncated to 15 chars (16 including NUL), so we use
 * the actual truncated process name that Android assigns.
 *
 * Android process naming: the zygote sets the process name to the
 * package name (or :subprocess) via prctl(PR_SET_NAME), truncated to
 * 15 chars. So com.android.deskclock becomes "com.android.de" (15 chars).
 *
 * Native daemons (apex-bridge, apex-control) set their own comm via
 * prctl or the argv[0] name, so they use their short names directly. */
static const char * const apex_immortal_builtin[] = {
	"com.android.de",	/* com.android.deskclock (truncated) */
	"com.qualcomm.q",	/* com.qualcomm.qti.poweroffalarm (truncated) */
	"apex-bridge",		/* userspace daemon (native, short name) */
	"alarmkeeper",		/* apex-alarmkeeper (native, short name) */
	"apex-control",		/* Apex Control app (native, short name) */
};

/* ---- core API: called by mm/oom_kill.c ---- */

bool apex_oom_immortal(struct task_struct *task)
{
	struct apex_immortal_entry *entry;
	const char *comm;
	bool found = false;
	int i;

	if (!task)
		return false;

	comm = task->comm;
	if (!comm[0])
		return false;

	/* Check built-in whitelist (fast path, no lock needed for reads
	 * since the array is const and never modified at runtime) */
	for (i = 0; i < ARRAY_SIZE(apex_immortal_builtin); i++) {
		if (strncmp(comm, apex_immortal_builtin[i],
			    APEX_COMM_LEN) == 0)
			return true;
	}

	/* Check runtime-added entries */
	spin_lock(&apex_immortal_lock);
	list_for_each_entry(entry, &apex_immortal_list, list) {
		if (strncmp(comm, entry->comm, APEX_COMM_LEN) == 0) {
			found = true;
			break;
		}
	}
	spin_unlock(&apex_immortal_lock);

	return found;
}
EXPORT_SYMBOL_GPL(apex_oom_immortal);

/* ---- sysctl: runtime replace entries ---- */

static char apex_oom_whitelist_buf[256];

static int apex_oom_whitelist_handler(struct ctl_table *table, int write,
				      void *buffer, size_t *lenp, loff_t *ppos)
{
	int ret;

	ret = proc_dostring(table, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;

	/* Parse the buffer: each line is a task comm name.
	 * Writing replaces the entire runtime list (clear + add). */
	{
		char *line = apex_oom_whitelist_buf;
		char *p;
		struct apex_immortal_entry *entry, *tmp;
		LIST_HEAD(new_list);
		unsigned int new_count = 0;

		/* Clear existing runtime list */
		spin_lock(&apex_immortal_lock);
		list_for_each_entry_safe(entry, tmp, &apex_immortal_list, list) {
			list_del(&entry->list);
			kfree(entry);
		}
		apex_immortal_count = 0;
		spin_unlock(&apex_immortal_lock);

		/* Parse and add new entries */
		while ((p = strsep(&line, "\n")) != NULL) {
			char *name = strim(p);

			if (!name[0] || name[0] == '#')
				continue;

			if (new_count >= APEX_IMMORTAL_MAX_ENTRIES) {
				pr_warn("OOM whitelist full, ignoring '%s'\n", name);
				break;
			}

			entry = kzalloc(sizeof(*entry), GFP_KERNEL);
			if (!entry)
				break;

			strscpy(entry->comm, name, APEX_COMM_LEN);
			spin_lock(&apex_immortal_lock);
			list_add_tail(&entry->list, &apex_immortal_list);
			apex_immortal_count++;
			spin_unlock(&apex_immortal_lock);
			new_count++;
			pr_info("added OOM-immortal task: '%s'\n", name);
		}
	}

	return 0;
}

static struct ctl_table apex_immortal_sysctl[] = {
	{
		.procname	= "apex_oom_whitelist",
		.data		= apex_oom_whitelist_buf,
		.maxlen		= sizeof(apex_oom_whitelist_buf),
		.mode		= 0644,
		.proc_handler	= apex_oom_whitelist_handler,
	},
	{ }
};

static struct ctl_table_header *apex_immortal_sysctl_hdr;

/* ---- init/exit ---- */

static int __init apex_immortal_init(void)
{
	apex_immortal_sysctl_hdr = register_sysctl("kernel",
						   apex_immortal_sysctl);
	if (!apex_immortal_sysctl_hdr)
		pr_warn("failed to register sysctl\n");

	pr_info("apex OOM-immortal whitelist: %zu built-in entries\n",
		ARRAY_SIZE(apex_immortal_builtin));
	return 0;
}

static void __exit apex_immortal_exit(void)
{
	struct apex_immortal_entry *entry, *tmp;

	if (apex_immortal_sysctl_hdr)
		unregister_sysctl_table(apex_immortal_sysctl_hdr);

	spin_lock(&apex_immortal_lock);
	list_for_each_entry_safe(entry, tmp, &apex_immortal_list, list) {
		list_del(&entry->list);
		kfree(entry);
	}
	apex_immortal_count = 0;
	spin_unlock(&apex_immortal_lock);
}

module_init(apex_immortal_init);
module_exit(apex_immortal_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex OOM-immortal task whitelist");
MODULE_LICENSE("GPL v2");
