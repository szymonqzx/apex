#!/usr/bin/env bash
# apply.sh — guard walt_init()'s sched_feat_names reference behind
# CONFIG_SCHED_DEBUG (the arrays only exist when SCHED_DEBUG=y).
#
# Without this, building with CONFIG_SCHED_DEBUG=n (production default)
# fails: undeclared 'sched_feat_names' / 'sched_feat_keys'.
#
# Idempotent: skips when the #ifdef guard is already present.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"
F="$KERNEL/kernel/sched/walt/walt.c"

if grep -q "#ifdef CONFIG_SCHED_DEBUG" "$F"; then
  echo "  apex-walt-scheddebug: already applied"
  exit 0
fi

python3 - "$F" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	waltgov_register();

	i = match_string(sched_feat_names, __SCHED_FEAT_NR, "TTWU_QUEUE");
	if (i >= 0) {
		static_key_disable(&sched_feat_keys[i]);
		sysctl_sched_features &= ~(1UL << i);
	}
"""
new = """	waltgov_register();

#ifdef CONFIG_SCHED_DEBUG
	i = match_string(sched_feat_names, __SCHED_FEAT_NR, "TTWU_QUEUE");
	if (i >= 0) {
		static_key_disable(&sched_feat_keys[i]);
		sysctl_sched_features &= ~(1UL << i);
	}
#endif
"""
if old not in s:
    sys.exit("pattern not found in " + p)
s = s.replace(old, new, 1)
old_decl = "\tint i;\n\n\tmight_sleep();"
if old_decl in s:
    s = s.replace(old_decl, "\tint i __maybe_unused;\n\n\tmight_sleep();", 1)
open(p, 'w').write(s)
PYEOF

echo "  apex-walt-scheddebug: installed"
