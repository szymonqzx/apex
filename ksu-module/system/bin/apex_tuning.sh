#!/system/bin/sh
# apex_tuning.sh — applies runtime kernel parameters after boot
#
# Sets kptr_restrict, dmesg_restrict, and other hardening + performance
# parameters that need to be applied at runtime (not defconfig).

# ── Kernel hardening ──────────────────────────────────────────────
echo 2 > /proc/sys/kernel/kptr_restrict 2>/dev/null
echo 1 > /proc/sys/kernel/dmesg_restrict 2>/dev/null
echo 1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null

# ── Memory management ─────────────────────────────────────────────
# ZRAM swap
echo 100 > /proc/sys/vm/swappiness 2>/dev/null

# LMK tuning — aggressive enough to keep system_server alive
# but reclaim background apps under memory pressure
echo "18432,23040,27648,32256,40960,48640" > /sys/module/lowmemorykiller/parameters/minfree 2>/dev/null

# ── CPU governor (if APEX kernel supports EAS) ────────────────────
# Set schedutil governor on all cores
for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
  if [ -f "$cpu/scaling_governor" ]; then
    echo "schedutil" > "$cpu/scaling_governor" 2>/dev/null
  fi
done

# ── GPU governor ──────────────────────────────────────────────────
GPU_GOV=/sys/class/kgsl/kgsl-3d0/devfreq/governor
if [ -f "$GPU_GOV" ]; then
  echo "msm-adreno-tz" > "$GPU_GOV" 2>/dev/null
fi

# ── I/O scheduler ─────────────────────────────────────────────────
for dev in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler; do
  if [ -f "$dev" ]; then
    echo "maple" > "$dev" 2>/dev/null || echo "cfq" > "$dev" 2>/dev/null
  fi
done

# ── Network tuning ────────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/tcp_low_latency 2>/dev/null

echo "APEX ROM: Runtime kernel tuning applied."
