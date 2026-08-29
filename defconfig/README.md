# defconfig fragments

Kernel defconfig fragments that get merged into the final `bengal_apex_defconfig`.

## Files

| File | Purpose |
| :--- | :--- |
| `display.config` | KCAL color calibration, BLX backlight dimmer |
| `filesystems.config` | exFAT, NTFS3, F2FS compression, EROFS (USB OTG + flash storage) |
| `governor.config` | apex governor, schedutil fallback, EPSS, CPU boost, thermal uclamp |
| `hardening.config` | CFI, KASLR, no USERFAULTFD, module signing, FORTIFY_SOURCE |
| `pentest.config` | NetHunter-compatible drivers as modules, WireGuard VPN |
| `performance.config` | interconnect, DCVS, BFQ, TCP BBR+Westwood, FQ scheduler |
| `root.config` | KernelSU-Next + SuSFS |
| `scheduler.config` | PREEMPT, HZ=250, WALT, CASS, EAS, PSI, CPU idle, power-efficient workqueues, lazy RCU |
| `toolchain.config` | Clang 22 + LLD + ThinLTO + BPF JIT |
| `version.config` | Localversion string |
| `zram.config` | ZRAM + ZSTD + writeback, KSM, transparent huge pages, MGLRU |

## Merge

The `build-kernel.sh` script merges all fragments using
`scripts/kconfig/merge_config.sh` after loading the base defconfig.
Fragments are applied alphabetically.

```bash
# Check for conflicts before building
python3 tools/check-configs.py

# Build with all fragments
./tools/build-kernel.sh chickernel_defconfig ksun
```

## Key optimizations vs stock

1. **Governor**: apex (non-linear power curve) replaces performance
2. **Scheduler**: CASS + WALT replaces stock PELT-only
3. **HZ**: 250 (4ms tick — balanced for 120Hz display + battery)
4. **CPU idle**: multiple drivers + MENU governor + TEO governor + PSCI domain power-down
5. **ZRAM**: ZSTD + writeback (vs stock LZO-RLE, no writeback)
6. **MGLRU**: Multi-Gen LRU for improved page reclaim (if backported to CAF 5.15)
7. **KSM**: enabled (stock disabled)
8. **Security**: CFI, KASLR, no USERFAULTFD, FORTIFY_SOURCE, module signing
9. **I/O**: BFQ + MQ_DEADLINE for low-latency UFS access
10. **Networking**: TCP BBR (default) + Westwood (switchable) + FQ scheduler
11. **Build**: ThinLTO with Clang 22 + LLD
12. **Power**: Power-efficient workqueues + forced lazy RCU for idle savings
13. **VPN**: WireGuard built-in
14. **Storage**: exFAT + NTFS3 for USB OTG
15. **Display**: KCAL RGB gain calibration
