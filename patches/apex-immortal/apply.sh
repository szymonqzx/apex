#!/usr/bin/env bash
# patches/apex-immortal/apply.sh — kernel-enforced OOM pin for critical tasks.
#
# Two-part approach:
# 1. Install apex_immortal.c into drivers/apex/ (provides apex_oom_immortal())
# 2. Patch mm/oom_kill.c to call apex_oom_immortal() during victim selection
#
# Idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

SRC="$HERE/src/apex_immortal.c"
DST_DIR="$KERNEL/drivers/apex"
DST="$DST_DIR/apex_immortal.c"

[ -d "$KERNEL" ] || {
  echo "kernel tree not found: $KERNEL" >&2
  exit 1
}
mkdir -p "$DST_DIR"

# 1. Source file
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "apex_immortal.c already installed"
else
  cp "$SRC" "$DST"
  echo "installed $DST"
fi

# 2. Kconfig: append to drivers/apex/Kconfig
if [ -f "$DST_DIR/Kconfig" ] && ! grep -q "config APEX_IMMORTAL" "$DST_DIR/Kconfig"; then
  cat >>"$DST_DIR/Kconfig" <<'EOF'

config APEX_IMMORTAL
	bool "apex OOM-immortal task whitelist"
	depends on APEX
	help
	  Whitelist of critical task names (desk clock, poweroff alarm,
	  apex-bridge, alarmkeeper, apex-control) that are never selected
	  as OOM victims. Uses truncated task->comm values (15 chars).
	  Runtime additions via sysctl kernel.apex_oom_whitelist.
EOF
  echo "appended APEX_IMMORTAL to drivers/apex/Kconfig"
else
  echo "APEX_IMMORTAL Kconfig already present"
fi

# 3. Makefile
if ! grep -q "apex_immortal" "$DST_DIR/Makefile"; then
  printf '\nobj-$(CONFIG_APEX_IMMORTAL) += apex_immortal.o\n' >>"$DST_DIR/Makefile"
  echo "appended apex_immortal.o to drivers/apex/Makefile"
else
  echo "apex_immortal Makefile already present"
fi

# 4. Patch mm/oom_kill.c to call apex_oom_immortal()
OOM_FILE="$KERNEL/mm/oom_kill.c"
if [ -f "$OOM_FILE" ] && ! grep -q "apex_oom_immortal" "$OOM_FILE"; then
  python3 - "$OOM_FILE" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add extern declaration after the last #include line
lines = content.split('\n')
last_include = 0
for i, line in enumerate(lines):
    if line.startswith('#include'):
        last_include = i
lines.insert(last_include + 1, 'extern bool apex_oom_immortal(struct task_struct *task);')
content = '\n'.join(lines)

# In oom_badness(), insert the immortal check after the variable declarations.
# The function starts with: { \n long points; \n long adj; \n
# We insert after "long adj;" line.
old = '''long oom_badness(struct task_struct *p, unsigned long totalpages)
{
	long points;
	long adj;'''
new = '''long oom_badness(struct task_struct *p, unsigned long totalpages)
{
	long points;
	long adj;

	if (apex_oom_immortal(p))
		return LONG_MIN;'''
content = content.replace(old, new, 1)

with open(filepath, 'w') as f:
    f.write(content)
print("patched mm/oom_kill.c with apex_oom_immortal() check")
PYEOF
else
  echo "mm/oom_kill.c already patched (or file not found)"
fi
