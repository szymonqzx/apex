#!/usr/bin/env bash
# apply.sh — fix base-tree defects that break the build with -Werror.
#
# These are upstream/Zepharo tree bugs, not APEX features: collected here so
# a clean checkout builds identically.
#
# Idempotent: each fix checks its marker before applying.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"

# 1. drivers/soc/qcom/minidump_log.c: 'static md_align_offset;' is missing
#    its type (breaks -Werror=implicit-int with clang).
F="$KERNEL/drivers/soc/qcom/minidump_log.c"
if grep -q '^static md_align_offset;' "$F"; then
  sed -i 's/^static md_align_offset;$/static int md_align_offset;/' "$F"
  echo "  apex-base-fixes: minidump_log.c md_align_offset type"
fi

# 2. net/qrtr/ns.c: struct uses struct work_struct but the code calls the
#    kthread_work API (kthread_queue_work/init_worker/init_work/kthread_run).
#    Add the missing kthread_worker/task members and fix teardown.
F="$KERNEL/net/qrtr/ns.c"
if ! grep -q 'struct kthread_worker kworker;' "$F"; then
  python3 - "$F" << 'PYEOF2'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	struct workqueue_struct *workqueue;
	struct work_struct work;
	void (*saved_data_ready)(struct sock *sk);"""
new = """	struct workqueue_struct *workqueue;
	struct kthread_worker kworker;
	struct kthread_work work;
	struct task_struct *task;
	void (*saved_data_ready)(struct sock *sk);"""
if old in s:
    s = s.replace(old, new, 1)
old2 = """	cancel_work_sync(&qrtr_ns.work);
	synchronize_net();"""
new2 = """	kthread_flush_work(&qrtr_ns.work);
	kthread_stop(qrtr_ns.task);
	synchronize_net();"""
if old2 in s:
    s = s.replace(old2, new2, 1)
open(p, 'w').write(s)
PYEOF2
  echo "  apex-base-fixes: qrtr/ns.c kthread_work API"
fi

# 3. net/ipv4/tcp_output.c: export tcp_current_mss so tcp_bbr3 (=m) links
F="$KERNEL/net/ipv4/tcp_output.c"
if ! grep -q "EXPORT_SYMBOL(tcp_current_mss);" "$F"; then
  python3 - "$F" << 'PYEOF3'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "unsigned int tcp_current_mss(struct sock *sk)"
idx = s.index(anchor)
rest = s[idx:]
brace = 0; i = 0; started = False
while i < len(rest):
    c = rest[i]
    if c == '{':
        brace += 1; started = True
    elif c == '}':
        brace -= 1
        if started and brace == 0:
            break
    i += 1
end = idx + i + 1
if "EXPORT_SYMBOL(tcp_current_mss);" not in s:
    s = s[:end] + "\nEXPORT_SYMBOL(tcp_current_mss);\n" + s[end:]
open(p, 'w').write(s)
PYEOF3
  echo "  apex-base-fixes: tcp_current_mss export"
fi

echo "  apex-base-fixes: done"
