#!/usr/bin/env bash
# tools/build-preflight.sh — fast structural checks for the kernel source tree.
# Fails before the long build if the base tree has known corruptions.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../kernel}"
[ -d "$KERNEL" ] || { echo "kernel tree not found: $KERNEL" >&2; exit 1; }

ERRORS=0

fail() {
    echo "  PREFLIGHT FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

echo "=== APEX kernel build preflight ==="
echo "  kernel: $KERNEL"

# 1. power/process.c — freeze_timeout_msecs must be one declaration.
if [ "$(grep -c '^unsigned int __read_mostly freeze_timeout_msecs' "$KERNEL/kernel/power/process.c")" -ne 1 ]; then
    fail "kernel/power/process.c: freeze_timeout_msecs declaration is split or duplicated"
fi

# 2. fs/notify/mark.c — must not reference missing iter_info->current_group.
if grep -q 'iter_info->current_group' "$KERNEL/fs/notify/mark.c"; then
    fail "fs/notify/mark.c: uses iter_info->current_group which is not in struct fsnotify_iter_info"
fi

# 3. sched/features.h — CACHE_HOT_BUDDY must be a real feature, not inside a comment.
if ! grep -q '^SCHED_FEAT(CACHE_HOT_BUDDY' "$KERNEL/kernel/sched/features.h"; then
    fail "kernel/sched/features.h: SCHED_FEAT(CACHE_HOT_BUDDY) missing or inside an unclosed comment"
fi

# 4. sched/rt.c — the fallback any-distribute block must not have a stray continue.
if awk '/cpu = cpumask_any_distribute\(lowest_mask\)/{s=1} s && /^\s*continue\s*;/{found=1; exit} s && /^\s*return /{exit}' "$KERNEL/kernel/sched/rt.c" | grep -q 'continue'; then
    fail "kernel/sched/rt.c: stray continue in find_lowest_rq fallback path"
fi

# 5. pci/pci.c — pci_pme_device struct must be closed before the next definition.
if ! awk '/struct pci_pme_device \{/{s=1} s && /^\};/{found=1; exit} END{exit !found}' "$KERNEL/drivers/pci/pci.c"; then
    fail "drivers/pci/pci.c: struct pci_pme_device is not closed with '};'"
fi

# 6. timer.c — no duplicate __timer_delete_sync definitions.
cnt=$(grep -c '^__timer_delete_sync' "$KERNEL/kernel/time/timer.c" 2>/dev/null || true)
[ -z "$cnt" ] && cnt=0
if [ "$cnt" -gt 1 ]; then
    fail "kernel/time/timer.c: multiple definitions of __timer_delete_sync"
fi

# 7. devpts/inode.c — ksu hook must have a proper prototype.
if grep -q 'int ksu_handle_devpts' "$KERNEL/fs/devpts/inode.c" && ! grep -q 'int ksu_handle_devpts(struct inode' "$KERNEL/fs/devpts/inode.c"; then
    fail "fs/devpts/inode.c: ksu_handle_devpts has malformed prototype"
fi

# 8. blk-cgroup.c — blkg_policy_data must have an 'online' member.
if grep -q 'p->online' "$KERNEL/block/blk-cgroup.c" && ! grep -q 'bool online' "$KERNEL/include/linux/blk-cgroup.h"; then
    fail "block/blk-cgroup.c: uses blkg_policy_data->online which does not exist in blk-cgroup.h"
fi

# 9. apex_blx.c — backlight_properties.name must exist before use.
if [ -f "$KERNEL/drivers/video/backlight/apex_blx.c" ] && grep -q 'props.name' "$KERNEL/drivers/video/backlight/apex_blx.c"; then
    if ! grep -q 'char.*name' "$KERNEL/include/linux/backlight.h"; then
        fail "drivers/video/backlight/apex_blx.c: references backlight_properties.name that the header does not define"
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo ">>> $ERRORS preflight failure(s). Do not start a full build — the kernel source tree is corrupted." >&2
    echo "    Fix the listed files or re-clone a clean ChicKernel/stock base." >&2
    exit 1
fi

echo "  preflight passed"
