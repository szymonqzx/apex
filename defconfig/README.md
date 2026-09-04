# defconfig

The kernel configuration uses a single hand-crafted `apex_defconfig` as the
source of truth. This file is tracked in git at `defconfig/apex_defconfig`
(`kernel/` itself is not in git — it is the Zepharo `zepharo` branch base,
Linux 5.15.211, fetched separately). The build script syncs this file into
`kernel/arch/arm64/configs/apex_defconfig` before configuring, so a clean
checkout builds identically.

All modern stack, security hardening, device driver, and performance settings
are baked directly into the defconfig — no fragment merging.

## Profile variants

There are **no compile-time profile fragments**. Profile switching
(battery / balanced / performance) is handled at runtime by
`rom-overlays/init.d/apex_profiles.rc`, which adjusts sysfs tunables
(schedutil rate limits, WALT migration thresholds, GPU clocks, thermal
trips, charge limits) on property change.

## Build

```bash
# Standard build (uses defconfig/apex_defconfig)
./tools/build-kernel.sh

# Clean build
./tools/build-kernel.sh --clean
```

## Validation

```bash
# Structural + dependency checks against the tracked defconfig
python3 tools/check-configs.py

# Full build-output verification
./tools/verify.sh
```

## Key features in apex_defconfig

1. **ThinLTO**: Clang ThinLTO with LLD for smaller binary and faster boot
2. **Compiler**: -O3 (`CC_OPTIMIZE_FOR_PERFORMANCE_O3`, un-ARC-gated) — the
   ChicKernel-proven optimization level for this SoC
3. **Scheduler**: WALT (built-in) + EAS + UCLAMP + PREEMPT + HZ=300
   (120 Hz-display aligned), Schedhorizon as the DEFAULT governor
4. **ZRAM**: built-in, ZSTD compression + writeback
5. **TCP**: BBR congestion control (module), cubic default
6. **Security**: CFI, KASLR, Shadow Call Stack, SLAB hardening, lockdown LSM
7. **I/O**: SSG (Samsung Generic) as the DEFAULT scheduler + BFQ available
8. **BPF**: JIT always on, unprivileged BPF disabled
9. **Debug**: DWARF5 + compressed, function tracer, dynamic ftrace
10. **Device drivers**: Fingerprint, charger ICs, MI thermal, ANT check, battery auth
11. **APEX modules**: sysfs control plane + charge control
12. **Root**: KernelSU-Next (native root) + SUSFS (root hiding)
13. **Baseband guard**: partition write-protection LSM (CONFIG_BBG)
