#!/usr/bin/env bash
# patches/apex-memfreq/apply.sh — apply memory DEVFREQ driver patch
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$(cd "$HERE/../../.." && pwd)/kernel}"

echo ">>> Applying apex-memfreq (memory DEVFREQ) patch..."

mkdir -p "$KERNEL/drivers/devfreq/apex"
cp "$HERE/src/apex_memfreq.c" "$KERNEL/drivers/devfreq/apex/apex_memfreq.c"

# Add Kconfig entry
KCONFIG="$KERNEL/drivers/devfreq/Kconfig"
if ! grep -q "APEX_MEMFREQ" "$KCONFIG" 2>/dev/null; then
    sed -i '/^endmenu/i\
config APEX_MEMFREQ\
\ttristate "APEX memory bandwidth DEVFREQ driver"\
\tdepends on DEVFREQ && INTERCONNECT\
\tdefault n\
\thelp\
\t  Monitors CPU utilization and votes for memory bandwidth through\
\t  the interconnect framework. Saves idle battery by reducing\
\t  LPDDR4X bandwidth when CPU/GPU are idle. Inspired by Sultan\
\t  Kernel Tensor AIO DEVFREQ driver.' "$KCONFIG"
fi

# Add Makefile entry
MAKEFILE="$KERNEL/drivers/devfreq/Makefile"
if ! grep -q "apex_memfreq" "$MAKEFILE" 2>/dev/null; then
    echo 'obj-$(CONFIG_APEX_MEMFREQ) += apex/apex_memfreq.o' >> "$MAKEFILE"
fi

echo "    apex-memfreq patch applied"
echo "    Enable with CONFIG_APEX_MEMFREQ=y in defconfig"
echo "    NOTE: Needs platform-specific interconnect path names from SM6225 DT"
