#!/usr/bin/env bash
# patches/apex-lmk/apply.sh — apply Simple LMK patch
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-$(cd "$HERE/../../.." && pwd)/kernel}"

echo ">>> Applying apex-lmk (Simple LMK) patch..."

# Copy the Simple LMK source into the kernel tree
mkdir -p "$KERNEL/drivers/staging/android/apex"
cp "$HERE/src/apex_simple_lmk.c" "$KERNEL/drivers/staging/android/apex/apex_simple_lmk.c"

# Add Kconfig entry
KCONFIG="$KERNEL/drivers/staging/android/Kconfig"
if ! grep -q "APEX_SIMPLE_LMK" "$KCONFIG" 2>/dev/null; then
    sed -i '/^endmenu/i\
config APEX_SIMPLE_LMK\
\ttristate "APEX Simple LMK — memory pressure killer"\
\tdepends on VMPRESSURE\
\tdefault n\
\thelp\
\t  Replacement for Android default LMK. Uses vmpressure notifier\
\t  and single-threshold kill based on free memory + file cache.\
\t  More aggressive and accurate than the 6-level Android LMK.' "$KCONFIG"
fi

# Add Makefile entry
MAKEFILE="$KERNEL/drivers/staging/android/Makefile"
if ! grep -q "apex_simple_lmk" "$MAKEFILE" 2>/dev/null; then
    echo 'obj-$(CONFIG_APEX_SIMPLE_LMK) += apex/apex_simple_lmk.o' >> "$MAKEFILE"
fi

echo "    apex-lmk patch applied"
echo "    Enable with CONFIG_APEX_SIMPLE_LMK=y in defconfig"
