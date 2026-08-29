// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/staging/android/apex_simple_lmk.c
 *
 * apex Simple LMK — replacement for Android's default lowmemorykiller.
 *
 * Architecture adapted from Sultan Alsawaf's Simple LMK (kerneltoast/simple_lmk),
 * with the following key improvements over the previous APEX LMK:
 *
 *   1. Adj-bucketed victim selection: tasks are sorted into buckets by
 *      oom_score_adj, then iterated from highest adj (least important) to
 *      lowest. This is O(n) instead of O(n^2) and naturally prioritizes
 *      the least important processes.
 *
 *   2. Size-sorted killing: within each adj bucket, victims are sorted by
 *      memory footprint (total mm pages). Larger victims are killed first
 *      to minimize the total number of kills needed to reclaim memory.
 *
 *   3. Dedicated reaper thread: a separate kthread reaps anonymous pages
 *      from killed victims using __oom_reap_task_mm(), accelerating memory
 *      reclaim without blocking the kill thread.
 *
 *   4. RT priority: the reclaim thread runs at MAX_RT_PRIO-1 and the reaper
 *      at MAX_RT_PRIO-2, ensuring kills happen even under heavy CPU load.
 *
 *   5. Completion-based timeout: the kill thread waits for victims to die
 *      with a configurable timeout, preventing indefinite hangs.
 *
 *   6. Two-pass victim minimization: if more pages were found than needed,
 *      a second sort+select pass reduces the number of victims by preferring
 *      larger victims with lower adj over smaller victims with higher adj.
 *
 * On a 4GB device like the Redmi Note 12 4G, memory pressure is the primary
 * cause of UI jank. This LMK is designed to kill fast, kill the right
 * processes, and reclaim memory immediately.
 *
 * Source: kerneltoast/simple_lmk (linux-5.10 branch)
 *   https://github.com/kerneltoast/simple_lmk
 *
 * Thresholds (configurable via sysctl):
 *   - min_free_pages: minimum free pages before kill (default: 6 pages = ~24MB)
 *   - cache_bonus_pages: pages of file cache counted as "free" (default: 32)
 *   - timeout_ms: reclaim timeout in milliseconds (default: 3000)
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": "

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/oom.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/sched/rt.h>
#include <linux/sysctl.h>
#include <linux/vmpressure.h>
#include <linux/swap.h>
#include <linux/fs.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/atomic.h>
#include <linux/cgroup.h>
#include <linux/css.h>
#include <linux/kthread.h>
#include <linux/freezer.h>
#include <linux/sort.h>
#include <linux/completion.h>
#include <linux/sched/cputime.h>
#include <uapi/linux/sched/types.h>

/* From apex_immortal — don't kill critical tasks */
extern bool apex_oom_immortal(struct task_struct *task);

/* ---- Configuration ---- */

#define APEX_LMK_MIN_FREE_DEFAULT	6	/* pages (~24MB on 4KB pages) */
#define APEX_LMK_CACHE_BONUS_DEFAULT	32	/* pages (~128MB) */
#define APEX_LMK_TIMEOUT_DEFAULT	3000	/* ms */
#define APEX_LMK_MAX_VICTIMS		128	/* max victims per reclaim */

/* ---- Per-victim info ---- */

struct apex_victim {
	struct task_struct *tsk;
	struct mm_struct *mm;
	unsigned long size;	/* total mm pages at selection time */
};

/* ---- State ---- */

static struct apex_victim victims[APEX_LMK_MAX_VICTIMS] __cacheline_aligned_in_smp;

/* Task buckets indexed by oom_score_adj (0..1000) */
static struct task_struct *task_bucket[1001] __cacheline_aligned;

static DECLARE_WAIT_QUEUE_HEAD(oom_waitq);
static DECLARE_WAIT_QUEUE_HEAD(reaper_waitq);
static DECLARE_COMPLETION(reclaim_done);
static DEFINE_RWLOCK(mm_free_lock);

static atomic_t needs_reclaim = ATOMIC_INIT(0);
static atomic_t needs_reap = ATOMIC_INIT(0);
static atomic_t nr_killed = ATOMIC_INIT(0);
static int nr_victims;
static bool reclaim_active;

struct apex_lmk_state {
	atomic_t min_free_pages;
	atomic_t cache_bonus_pages;
	atomic_t timeout_ms;
	atomic_t kill_count;
	atomic_t skip_count;
};

static struct apex_lmk_state lmk_state = {
	.min_free_pages = ATOMIC_INIT(APEX_LMK_MIN_FREE_DEFAULT),
	.cache_bonus_pages = ATOMIC_INIT(APEX_LMK_CACHE_BONUS_DEFAULT),
	.timeout_ms = ATOMIC_INIT(APEX_LMK_TIMEOUT_DEFAULT),
	.kill_count = ATOMIC_INIT(0),
	.skip_count = ATOMIC_INIT(0),
};

static struct notifier_block lmk_vmpressure_nb;

/* ---- Helpers ---- */

static void set_task_rt_prio(struct task_struct *tsk, int priority)
{
	const struct sched_param rt_prio = {
		.sched_priority = priority
	};

	sched_setscheduler_nocheck(tsk, SCHED_RR, &rt_prio);
}

static unsigned long get_total_mm_pages(struct mm_struct *mm)
{
	unsigned long pages = 0;
	int i;

	for (i = 0; i < NR_MM_COUNTERS; i++)
		pages += get_mm_counter(mm, i);

	return pages;
}

/* Calculate effective free pages: free + reclaimable cache (capped) */
static unsigned long apex_lmk_effective_free(void)
{
	struct sysinfo si;
	unsigned long free_pages;
	unsigned long cache_pages;

	si_meminfo(&si);
	free_pages = si.freeram;
	/* Use global_node_page_state for file-backed page cache.
	 * struct sysinfo does not have a filepage field in Linux 5.15.
	 * NR_FILE_PAGES counts all file-backed pages (page cache). */
	cache_pages = min(global_node_page_state(NR_FILE_PAGES),
			  (unsigned long)atomic_read(&lmk_state.cache_bonus_pages));

	return free_pages + cache_pages;
}

/* ---- Victim selection (Sultan's adj-bucketed approach) ---- */

static int victim_cmp(const void *lhs_ptr, const void *rhs_ptr)
{
	const struct apex_victim *lhs = (typeof(lhs))lhs_ptr;
	const struct apex_victim *rhs = (typeof(rhs))rhs_ptr;

	return rhs->size - lhs->size;	/* descending: largest first */
}

static void victim_swap(void *lhs_ptr, void *rhs_ptr, int size)
{
	struct apex_victim *lhs = (typeof(lhs))lhs_ptr;
	struct apex_victim *rhs = (typeof(rhs))rhs_ptr;

	swap(*lhs, *rhs);
}

static unsigned long find_victims(int *vindex)
{
	short i, min_adj = SHRT_MAX, max_adj = 0;
	unsigned long pages_found = 0;
	struct task_struct *tsk;
	int min_free_pages = atomic_read(&lmk_state.min_free_pages);

	rcu_read_lock();
	for_each_process(tsk) {
		struct signal_struct *sig;
		short adj;

		/* Skip self and init */
		if (tsk == current || tsk == init_task)
			continue;

		/* Skip kernel threads */
		if (tsk->mm == NULL)
			continue;

		/* Skip apex OOM-immortal tasks */
		if (apex_oom_immortal(tsk))
			continue;

		sig = tsk->signal;
		adj = READ_ONCE(sig->oom_score_adj);

		/* Only target tasks with positive adj (background) */
		if (adj < 0 ||
		    sig->flags & (SIGNAL_GROUP_EXIT | SIGNAL_GROUP_COREDUMP) ||
		    (thread_group_empty(tsk) && tsk->flags & PF_EXITING))
			continue;

		/* Store in adj bucket */
		tsk->simple_lmk_next = task_bucket[adj];
		task_bucket[adj] = tsk;

		if (adj > max_adj)
			max_adj = adj;
		if (adj < min_adj)
			min_adj = adj;
	}

	/* Search from highest adj (least important) to lowest */
	for (i = max_adj; i >= min_adj; i--) {
		int old_vindex;

		tsk = task_bucket[i];
		if (!tsk)
			continue;

		/* Clear bucket for next reclaim */
		task_bucket[i] = NULL;

		old_vindex = *vindex;
		do {
			struct task_struct *vtsk;

			vtsk = find_lock_task_mm(tsk);
			if (!vtsk)
				continue;

			victims[*vindex].tsk = vtsk;
			victims[*vindex].mm = vtsk->mm;
			victims[*vindex].size = get_total_mm_pages(vtsk->mm);

			pages_found += victims[*vindex].size;

			if (++*vindex == APEX_LMK_MAX_VICTIMS)
				break;
		} while ((tsk = tsk->simple_lmk_next));

		if (*vindex == old_vindex)
			continue;

		/* Sort victims in this bucket by size (largest first) */
		sort(&victims[old_vindex], *vindex - old_vindex,
		     sizeof(*victims), victim_cmp, victim_swap);

		/* Stop if we have enough pages or hit the limit */
		if (*vindex == APEX_LMK_MAX_VICTIMS ||
		    pages_found >= (unsigned long)min_free_pages) {
			if (i > min_adj)
				memset(&task_bucket[min_adj], 0,
				       (i - min_adj) * sizeof(*task_bucket));
			break;
		}
	}
	rcu_read_unlock();

	return pages_found;
}

static int process_victims(int vlen)
{
	unsigned long pages_found = 0;
	int i, nr_to_kill = 0;
	int min_free_pages = atomic_read(&lmk_state.min_free_pages);

	for (i = 0; i < vlen; i++) {
		struct apex_victim *victim = &victims[i];
		struct task_struct *vtsk = victim->tsk;

		if (pages_found >= (unsigned long)min_free_pages) {
			task_unlock(vtsk);
		} else {
			pages_found += victim->size;
			nr_to_kill++;
		}
	}

	return nr_to_kill;
}

/* ---- Kill and reap ---- */

static void scan_and_kill(void)
{
	int i, nr_to_kill, nr_found = 0;
	unsigned long pages_found;
	int timeout_ms = atomic_read(&lmk_state.timeout_ms);

	write_lock(&mm_free_lock);
	nr_victims = 0;
	write_unlock(&mm_free_lock);

	pages_found = find_victims(&nr_found);
	if (unlikely(!nr_found)) {
		pr_err_ratelimited("No processes available to kill!\n");
		atomic_inc(&lmk_state.skip_count);
		return;
	}

	if (pages_found > (unsigned long)atomic_read(&lmk_state.min_free_pages)) {
		/* First pass: weed out unneeded victims */
		nr_to_kill = process_victims(nr_found);

		/* Sort chosen victims by size to minimize kills */
		sort(victims, nr_to_kill, sizeof(*victims),
		     victim_cmp, victim_swap);

		/* Second pass: final selection */
		nr_to_kill = process_victims(nr_to_kill);
	} else {
		nr_to_kill = nr_found;
	}

	write_lock(&mm_free_lock);
	nr_victims = nr_to_kill;
	reclaim_active = true;
	write_unlock(&mm_free_lock);

	/* Kill the victims */
	for (i = 0; i < nr_to_kill; i++) {
		struct apex_victim *victim = &victims[i];
		struct task_struct *t, *vtsk = victim->tsk;
		struct mm_struct *mm = victim->mm;

		pr_info("Killing %s with adj %d to free %lu KiB\n", vtsk->comm,
			vtsk->signal->oom_score_adj,
			victim->size << (PAGE_SHIFT - 10));

		/* Mark for anon-first reclaim in exit_mmap() */
		set_bit(MMF_OOM_VICTIM, &mm->flags);

		/* Force kill signal */
		do_send_sig_info(SIGKILL, SEND_SIG_PRIV, vtsk, PIDTYPE_TGID);

		/* Elevate victim threads to SCHED_RR min priority so
		 * exit_mmap() completes quickly regardless of which
		 * thread holds the final mm reference */
		rcu_read_lock();
		for_each_thread(vtsk, t)
			set_tsk_thread_flag(t, TIF_MEMDIE);
		for_each_thread(vtsk, t)
			set_task_rt_prio(t, 1);
		rcu_read_unlock();

		/* Allow victim to run on any CPU */
		set_cpus_allowed_ptr(vtsk, cpu_all_mask);

		/* Thaw if frozen (signals can't wake frozen tasks) */
		__thaw_task(vtsk);

		/* Store anon page count for reaper prioritization */
		victim->size = get_mm_counter(mm, MM_ANONPAGES);

		task_unlock(vtsk);
	}

	/* Sort by anon pages for reaper (largest first) */
	write_lock(&mm_free_lock);
	sort(victims, nr_to_kill, sizeof(*victims), victim_cmp, victim_swap);
	atomic_set(&needs_reap, 1);
	write_unlock(&mm_free_lock);
	if (waitqueue_active(&reaper_waitq))
		wake_up(&reaper_waitq);

	/* Wait for victims to die or timeout */
	if (!wait_for_completion_timeout(&reclaim_done,
					 msecs_to_jiffies(timeout_ms)))
		pr_info("Timeout hit waiting for victims to die, proceeding\n");

	write_lock(&mm_free_lock);
	reinit_completion(&reclaim_done);
	reclaim_active = false;
	nr_killed = (atomic_t)ATOMIC_INIT(0);
	write_unlock(&mm_free_lock);

	atomic_add(nr_to_kill, &lmk_state.kill_count);
}

static int apex_lmk_reclaim_thread(void *data)
{
	/* Maximum RT priority — kills must happen even under load */
	set_task_rt_prio(current, MAX_RT_PRIO - 1);
	set_freezable();

	while (1) {
		wait_event_freezable(oom_waitq, atomic_read(&needs_reclaim));
		scan_and_kill();
		atomic_set(&needs_reclaim, 0);
	}

	return 0;
}

/* ---- Reaper thread (Sultan's approach) ---- */

static struct mm_struct *next_reap_victim(void)
{
	struct mm_struct *mm = NULL;
	bool should_retry = false;
	int i;

	write_lock(&mm_free_lock);
	for (i = 0; i < nr_victims; i++, mm = NULL) {
		mm = victims[i].mm;
		if (!mm || test_bit(MMF_OOM_SKIP, &mm->flags))
			continue;

		if (!mmap_read_trylock(mm)) {
			should_retry = true;
			continue;
		}

		if (!test_bit(MMF_OOM_SKIP, &mm->flags))
			break;
		mmap_read_unlock(mm);
	}

	if (!mm) {
		if (should_retry)
			mm = ERR_PTR(-EAGAIN);
		else if (!reclaim_active)
			nr_victims = 0;
	}
	write_unlock(&mm_free_lock);

	return mm;
}

static void reap_victims(void)
{
	struct mm_struct *mm;

	while ((mm = next_reap_victim())) {
		if (IS_ERR(mm)) {
			schedule_timeout_uninterruptible(1);
			continue;
		}

		if (__oom_reap_task_mm(mm)) {
			clear_bit(MMF_OOM_VICTIM, &mm->flags);
			set_bit(MMF_OOM_SKIP, &mm->flags);
		}
		mmap_read_unlock(mm);
	}
}

static int apex_lmk_reaper_thread(void *data)
{
	/* Lower priority than reclaim thread */
	set_task_rt_prio(current, MAX_RT_PRIO - 2);
	set_freezable();

	while (1) {
		wait_event_freezable(reaper_waitq,
				     atomic_cmpxchg_relaxed(&needs_reap, 1, 0));
		reap_victims();
	}

	return 0;
}

/* Called when a victim's mm is freed via exit_mmap() */
void apex_lmk_mm_freed(struct mm_struct *mm)
{
	int i;

	if (!test_bit(MMF_OOM_SKIP, &mm->flags))
		return;

	read_lock(&mm_free_lock);
	for (i = 0; i < nr_victims; i++) {
		if (victims[i].mm == mm) {
			victims[i].mm = NULL;
			if (reclaim_active &&
			    atomic_inc_return_relaxed(&nr_killed) == nr_victims)
				complete(&reclaim_done);
			break;
		}
	}
	read_unlock(&mm_free_lock);
}

/* ---- vmpressure callback ---- */

static int apex_lmk_vmpressure_cb(struct notifier_block *nb,
				  unsigned long pressure, void *data)
{
	if (pressure == 100) {
		atomic_set(&needs_reclaim, 1);
		smp_mb__after_atomic();
		if (waitqueue_active(&oom_waitq))
			wake_up(&oom_waitq);
	}

	return NOTIFY_OK;
}

/* ---- Sysctl interface ---- */

static int apex_lmk_min_free_handler(struct ctl_table *table, int write,
				     void *buffer, size_t *lenp, loff_t *ppos)
{
	int val = atomic_read(&lmk_state.min_free_pages);
	int ret;

	table->data = &val;
	ret = proc_dointvec(table, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;

	if (val < 1)
		val = 1;
	if (val > 256)
		val = 256;
	atomic_set(&lmk_state.min_free_pages, val);
	return 0;
}

static int apex_lmk_cache_bonus_handler(struct ctl_table *table, int write,
					void *buffer, size_t *lenp, loff_t *ppos)
{
	int val = atomic_read(&lmk_state.cache_bonus_pages);
	int ret;

	table->data = &val;
	ret = proc_dointvec(table, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;

	if (val < 0)
		val = 0;
	if (val > 256)
		val = 256;
	atomic_set(&lmk_state.cache_bonus_pages, val);
	return 0;
}

static int apex_lmk_timeout_handler(struct ctl_table *table, int write,
				    void *buffer, size_t *lenp, loff_t *ppos)
{
	int val = atomic_read(&lmk_state.timeout_ms);
	int ret;

	table->data = &val;
	ret = proc_dointvec(table, write, buffer, lenp, ppos);
	if (ret || !write)
		return ret;

	if (val < 100)
		val = 100;
	if (val > 30000)
		val = 30000;
	atomic_set(&lmk_state.timeout_ms, val);
	return 0;
}

static struct ctl_table apex_lmk_sysctl[] = {
	{
		.procname	= "apex_lmk_min_free_pages",
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= apex_lmk_min_free_handler,
	},
	{
		.procname	= "apex_lmk_cache_bonus_pages",
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= apex_lmk_cache_bonus_handler,
	},
	{
		.procname	= "apex_lmk_timeout_ms",
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= apex_lmk_timeout_handler,
	},
	{ }
};

static struct ctl_table_header *apex_lmk_sysctl_hdr;

/* ---- /proc/apex/lmk status ---- */

static int apex_lmk_status_show(struct seq_file *m, void *v)
{
	seq_printf(m, "min_free_pages: %d\n", atomic_read(&lmk_state.min_free_pages));
	seq_printf(m, "cache_bonus_pages: %d\n", atomic_read(&lmk_state.cache_bonus_pages));
	seq_printf(m, "timeout_ms: %d\n", atomic_read(&lmk_state.timeout_ms));
	seq_printf(m, "kill_count: %d\n", atomic_read(&lmk_state.kill_count));
	seq_printf(m, "skip_count: %d\n", atomic_read(&lmk_state.skip_count));
	seq_printf(m, "reclaim_active: %d\n", reclaim_active);
	seq_printf(m, "nr_victims: %d\n", nr_victims);
	return 0;
}

static int apex_lmk_status_open(struct inode *inode, struct file *file)
{
	return single_open(file, apex_lmk_status_show, NULL);
}

static const struct proc_ops apex_lmk_fops = {
	.proc_open		= apex_lmk_status_open,
	.proc_read		= seq_read,
	.proc_release		= single_release,
};

extern struct proc_dir_entry *apex_get_proc_dir(void);

static int __init apex_lmk_init(void)
{
	struct proc_dir_entry *apex_dir;
	struct task_struct *thread;

	apex_lmk_sysctl_hdr = register_sysctl("kernel", apex_lmk_sysctl);
	if (!apex_lmk_sysctl_hdr)
		pr_warn("failed to register LMK sysctl\n");

	/* Register vmpressure notifier */
	lmk_vmpressure_nb.notifier_call = apex_lmk_vmpressure_cb;
	lmk_vmpressure_nb.priority = INT_MAX;
	if (vmpressure_register_notifier(&lmk_vmpressure_nb))
		pr_warn("failed to register vmpressure notifier\n");

	/* Start reaper thread (lower priority than reclaim) */
	thread = kthread_run(apex_lmk_reaper_thread, NULL, "apex_lmkd_reaper");
	if (IS_ERR(thread)) {
		pr_err("failed to start reaper thread\n");
		return PTR_ERR(thread);
	}

	/* Start reclaim thread (max RT priority) */
	thread = kthread_run(apex_lmk_reclaim_thread, NULL, "apex_lmkd");
	if (IS_ERR(thread)) {
		pr_err("failed to start reclaim thread\n");
		return PTR_ERR(thread);
	}

	/* Create /proc/apex/lmk */
	apex_dir = apex_get_proc_dir();
	if (apex_dir)
		proc_create("lmk", 0444, apex_dir, &apex_lmk_fops);

	pr_info("apex Simple LMK loaded (min_free=%d pages, cache_bonus=%d pages, timeout=%d ms)\n",
		atomic_read(&lmk_state.min_free_pages),
		atomic_read(&lmk_state.cache_bonus_pages),
		atomic_read(&lmk_state.timeout_ms));
	return 0;
}

static void __exit apex_lmk_exit(void)
{
	vmpressure_unregister_notifier(&lmk_vmpressure_nb);

	if (apex_lmk_sysctl_hdr)
		unregister_sysctl_table(apex_lmk_sysctl_hdr);

	/* Remove /proc/apex/lmk (removed with /proc/apex/ by apex.ko) */
}

module_init(apex_lmk_init);
module_exit(apex_lmk_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex Simple LMK — adj-bucketed memory pressure killer with reaper thread");
MODULE_LICENSE("GPL v2");
