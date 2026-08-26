# defconfig fragments

This directory will hold the kernel defconfig fragments that get merged into
`bengal_apex_defconfig`. The full config is documented in
`docs/DESIGN.md` §5.

## Files (to be created)

- `root.config`        — Root engine: KernelSU-Next, SuSFS, KERNELSU_HIDE_PID
- `scheduler.config`   — PREEMPT_DYNAMIC, HZ=200, EAS, WALT, PSI
- `governor.config`    — apex per-cluster governor
- `pentest.config`     — All NetHunter drivers =m
- `hardening.config`   — STRICT_DEVMEM, kptr_restrict, BTI, PAC
- `zram.config`        — ZRAM + ZSTD

## Status

Empty. Theory only.
