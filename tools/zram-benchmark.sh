#!/usr/bin/env bash
# tools/zram-benchmark.sh — A/B benchmark zRAM compression algorithms
#
# APEX uses ZSTD for zRAM. Optimistic Kernel updated zstd/lz crypto.
# This script benchmarks ZSTD vs LZ4 to verify ZSTD is the right choice
# for the A73/A53 cores on SM6225.
#
# On a 4GB device, compression ratio matters more than decompression
# speed, so ZSTD is likely correct. This benchmark confirms it.
#
# Run on-device (requires root):
#   adb shell su -c 'sh /sdcard/zram-benchmark.sh'
set -euo pipefail

ZRAM_DEV="/dev/block/zram0"
ITERATIONS=5
TEST_SIZE="512M"

echo "=== APEX zRAM Compression Benchmark ==="
echo "  Device: $(uname -a)"
echo "  Iterations: $ITERATIONS"
echo "  Test size: $TEST_SIZE"
echo ""

# Check if zram is available
if [ ! -e "$ZRAM_DEV" ]; then
  echo "ERROR: $ZRAM_DEV not found. Load zram module first."
  exit 1
fi

benchmark_compressor() {
  local comp="$1"
  echo "--- Testing: $comp ---"

  # Reset zram
  echo 1 > /sys/block/zram0/reset

  # Set compression algorithm
  echo "$comp" > /sys/block/zram0/comp_algorithm

  # Set disksize
  echo "$TEST_SIZE" > /sys/block/zram0/disksize

  # Make swap
  mkswap "$ZRAM_DEV" >/dev/null 2>&1
  swapon "$ZRAM_DEV" >/dev/null 2>&1

  # Generate test data (compressible — typical Android memory pages)
  local tmpfile="/tmp/zram-bench-$comp.data"
  dd if=/dev/urandom of="$tmpfile" bs=1M count=64 2>/dev/null
  # Mix with zeros (simulates zero pages)
  dd if=/dev/zero of="$tmpfile" bs=1M count=64 conv=notrunc oflag=append 2>/dev/null

  # Write data to swap (forces compression)
  local start_time=$(date +%s%N)
  cat "$tmpfile" > /dev/null &
  local pid=$!
  # Force pages into swap
  for i in $(seq 1 10); do
    dd if=/dev/urandom of="/tmp/pressure-$i" bs=1M count=32 2>/dev/null
  done
  wait $pid 2>/dev/null || true
  local end_time=$(date +%s%N)
  local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

  # Read compression stats
  local compr_data_size=$(cat /sys/block/zram0/mm_stat 2>/dev/null | awk '{print $2}')
  local orig_data_size=$(cat /sys/block/zram0/mm_stat 2>/dev/null | awk '{print $1}')
  local mem_used_total=$(cat /sys/block/zram0/mm_stat 2>/dev/null | awk '{print $3}')

  local ratio="N/A"
  if [ "$compr_data_size" -gt 0 ] 2>/dev/null; then
    ratio=$((orig_data_size * 100 / compr_data_size))
  fi

  echo "  Original size:    $((orig_data_size / 1024 / 1024)) MB"
  echo "  Compressed size:  $((compr_data_size / 1024 / 1024)) MB"
  echo "  Compression ratio: ${ratio}%"
  echo "  Memory used:      $((mem_used_total / 1024 / 1024)) MB"
  echo "  Write time:       ${elapsed_ms}ms"
  echo ""

  # Cleanup
  swapoff "$ZRAM_DEV" >/dev/null 2>&1
  echo 1 > /sys/block/zram0/reset
  rm -f "$tmpfile" /tmp/pressure-* 2>/dev/null
}

# Run benchmarks
for comp in zstd lz4 lzo; do
  # Check if algorithm is supported
  if grep -q "\b$comp\b" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    benchmark_compressor "$comp"
  else
    echo "--- $comp: not supported by this zram module ---"
    echo ""
  fi
done

echo "=== Benchmark complete ==="
echo ""
echo "  Compare compression ratios and write times."
echo "  Higher ratio = more memory saved."
echo "  Lower write time = less CPU overhead."
echo "  On 4GB devices, ratio usually matters more than speed."
