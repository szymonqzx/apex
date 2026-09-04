#!/usr/bin/env bash
# patches/apex-governor/apply.sh — install the apex governor into the kernel tree.
# Idempotent: refuses to re-copy over an existing identical file.
#
# CRITICAL: The CPU_FREQ_DEFAULT_GOV_APEX choice option must be inserted
# INSIDE the choice block (before endchoice), not appended at the end.
# The CPU_FREQ_GOV_APEX tristate goes after endchoice (like other governors).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$HERE/../../kernel}"

SRC="$HERE/src/cpufreq_apex.c"
DST_DIR="$KERNEL/drivers/cpufreq"
DST="$DST_DIR/cpufreq_apex.c"
KCONFIG="$DST_DIR/Kconfig"
MAKEFILE="$DST_DIR/Makefile"

[ -d "$KERNEL" ] || {
  echo "kernel tree not found: $KERNEL" >&2
  exit 1
}

# 1. Source file
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "cpufreq_apex.c already installed"
else
  cp "$SRC" "$DST"
  echo "installed $DST"
fi

# 2. Kconfig: insert choice option before endchoice, append governor def after
if ! grep -q "config CPU_FREQ_GOV_APEX" "$KCONFIG"; then
  # Choice option block (goes inside choice...endchoice)
  CHOICE_BLOCK='config CPU_FREQ_DEFAULT_GOV_APEX
	bool "apex"
	depends on CPU_FREQ
	select CPU_FREQ_GOV_APEX
	help
	  Use the '"'"'apex'"'"' governor as the default.'

  # Governor definition block (goes after endchoice)
  GOV_BLOCK='config CPU_FREQ_GOV_APEX
	tristate "apex cpufreq policy governor"
	depends on CPU_FREQ
	select CPU_FREQ_GOV_COMMON
	help
	  apex - per-cluster governor for A73/A53 with non-linear power curve,
	  iowait boost, hysteresis, fast_switch, and gaming mode.'

  # Insert choice option before endchoice using a temp file
  TMP=$(mktemp)
  AWK_INSERTED=0
  while IFS= read -r line; do
    if [ "$AWK_INSERTED" -eq 0 ] && [ "$line" = "endchoice" ]; then
      printf '%s\n\n' "$CHOICE_BLOCK" >>"$TMP"
      AWK_INSERTED=1
    fi
    printf '%s\n' "$line" >>"$TMP"
  done <"$KCONFIG"
  mv "$TMP" "$KCONFIG"

  # Append governor definition at end of file
  printf '\n%s\n' "$GOV_BLOCK" >>"$KCONFIG"

  echo "inserted CPU_FREQ_DEFAULT_GOV_APEX before endchoice"
  echo "appended CPU_FREQ_GOV_APEX governor definition"
else
  echo "Kconfig already patched"
fi

# 3. Makefile
if ! grep -q "cpufreq_apex" "$MAKEFILE"; then
  printf '\nobj-$(CONFIG_CPU_FREQ_GOV_APEX) += cpufreq_apex.o\n' >>"$MAKEFILE"
  echo "appended cpufreq_apex.o to drivers/cpufreq/Makefile"
else
  echo "Makefile already patched"
fi
