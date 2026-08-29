#!/usr/bin/env bash
# tools/irq-balance-check.sh — review IRQ distribution on SM6225-AD
#
# Sultan Kernel found and fixed a severe bug in the IRQ balancer (SBalance)
# on Pixel devices. This script reviews IRQ distribution on the SM6225
# to detect similar issues.
#
# Run on-device (requires root):
#   adb shell su -c 'sh /sdcard/irq-balance-check.sh'
set -euo pipefail

echo "=== APEX IRQ Balance Review ==="
echo ""

# 1. Show IRQ distribution per CPU
echo "--- IRQ count per CPU ---"
cat /proc/interrupts | head -1
echo ""

# 2. Show top IRQ sources
echo "--- Top 20 IRQ sources by count ---"
awk 'NR>1 {
  total=0;
  for (i=2; i<=NF-2; i++) total+=$i;
  printf "%8d  %s\n", total, $NF
}' /proc/interrupts | sort -rn | head -20
echo ""

# 3. Check if IRQs are balanced across clusters
echo "--- IRQ distribution by cluster ---"
BIG_CPUS="0 1 2 3"
LITTLE_CPUS="4 5 6 7"
BIG_TOTAL=0
LITTLE_TOTAL=0

for cpu in $BIG_CPUS; do
  col=$((cpu + 2))
  val=$(awk "NR==2{print \$$col}" /proc/interrupts 2>/dev/null || echo 0)
  BIG_TOTAL=$((BIG_TOTAL + val))
done
for cpu in $LITTLE_CPUS; do
  col=$((cpu + 2))
  val=$(awk "NR==2{print \$$col}" /proc/interrupts 2>/dev/null || echo 0)
  LITTLE_TOTAL=$((LITTLE_TOTAL + val))
done

echo "  Big cluster (A73, cpu 0-3):    $BIG_TOTAL IRQs"
echo "  Little cluster (A53, cpu 4-7): $LITTLE_TOTAL IRQs"
echo ""

# 4. Check smp_affinity for key IRQs
echo "--- SMP affinity for key IRQs ---"
for irq_name in "msm_gpio" "kgsl_3d0" "ufshcd" "dsi" "pdc"; do
  irq_num=$(grep -i "$irq_name" /proc/interrupts | head -1 | awk '{print $1}' | tr -d ':')
  if [ -n "$irq_num" ]; then
    affinity=$(cat "/proc/irq/$irq_num/smp_affinity_list" 2>/dev/null || echo "N/A")
    echo "  IRQ $irq_num ($irq_name): affinity=$affinity"
  fi
done
echo ""

# 5. Check if IRQ daemon is running
echo "--- IRQ balance daemon ---"
if pgrep -x irqbalance >/dev/null 2>&1; then
  echo "  irqbalance: running (pid=$(pgrep -x irqbalance))"
else
  echo "  irqbalance: not running"
fi
echo ""

# 6. Recommendations
echo "--- Analysis ---"
if [ "$BIG_TOTAL" -gt 0 ] && [ "$LITTLE_TOTAL" -gt 0 ]; then
  RATIO=$((BIG_TOTAL * 100 / LITTLE_TOTAL))
  if [ "$RATIO" -gt 200 ]; then
    echo "  WARNING: Big cluster handling ${RATIO}% more IRQs than little cluster."
    echo "  Consider pinning network/storage IRQs to little cluster."
  elif [ "$RATIO" -lt 50 ]; then
    echo "  NOTE: Little cluster handling more IRQs — may cause latency on background tasks."
  else
    echo "  IRQ distribution looks balanced."
  fi
else
  echo "  Insufficient data for analysis."
fi

echo ""
echo "=== IRQ Balance Review complete ==="
