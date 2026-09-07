# APEX device toolset — resilient kernel/ROM flashing & debugging

Built from the 2026-09-07 first-device flash session. Every script encodes a
lesson learned that day (flaky USB links, dying adb, hung fastboot
transfers, no serial console, A/B slot safety).

## Design rules

1. **A/B safety always**: trials flash the INACTIVE slot; the known-good
   slot is never touched until a trial passes. Rollback is one command.
2. **Retry everything**: every adb/fastboot call goes through a retry
   wrapper that also kills stuck transfers (a hung 128MB flash on a bad
   link never completes — kill and retry instead).
3. **Verify after write**: flashed partitions are hash-checked against the
   local image when possible.
4. **Machine-readable**: `--json` on the verification tools, distinct exit
   codes everywhere (0 ok / 2 timeout / 3 mismatch / 4 panic) — so Hermes
   or any agent can drive the loop.
5. **Start from truth**: `device-state.sh` is the first command of any
   session (the 2026-09-07 session burned 30 minutes rediscovering state).

## Tools

| Tool | Purpose |
|---|---|
| `device-state.sh` | One-shot state snapshot (kernel/slot/ROM/root/battery/USB). Run first. |
| `adb-retry.sh` | Retry wrapper for short adb shell commands. |
| `fastboot-retry.sh` | Retry + stuck-transfer-kill wrapper for fastboot. |
| `boot-image.sh` | Boot-image factory: reference boot + kernel Image → flashable img (magiskboot), verified. |
| `flash-boot.sh` | Safety-first flasher: inactive slot by default, post-write hash verify, explicit `--activate`. |
| `slot.sh` | A/B slot current/other/set/list. |
| `boot-test.sh` | Boot verification loop: waits for adb, checks kernel version / APEX sysfs / boot_completed / pstore panics. |
| `bisect-kernel.sh` | Feature bisection: plain-kernel → add features one stage at a time, flash+boot-test each, rollback on failure. |
| `collect-boot-log.sh` | pstore/ramoops + dmesg + logcat collection (the only kernel-side breadcrumbs without a serial console). |
| `config-compare.sh` | Diff local .config vs the running kernel's /proc/config.gz — finds fatal deltas (HZ, MODULE_SIG, missing drivers). |

## Workflow

```bash
# 0. Snapshot
tools/device/device-state.sh --json

# 1. Build a boot image (kernel Image from out/ + a reference boot)
tools/device/boot-image.sh backups/device-2026-09-07/boot_b.img \
    out/arch/arm64/boot/Image out/trial.img \
    FEATURE_STRINGS=apex_thermal

# 2. Trial on the inactive slot (slot b stays untouched)
tools/device/flash-boot.sh out/trial.img --activate
tools/device/boot-test.sh --expect 5.15.211 --expect-apex --timeout 240
# on failure: tools/device/slot.sh set b && fastboot reboot   (rollback)

# 3. When boot failures need isolation
tools/device/config-compare.sh
tools/device/bisect-kernel.sh tools/device/stages-apex.txt --boot-ref <ref-boot>
```

## State notes (2026-09-07)

- Device: topaz, bootloader UNLOCKED, slot b = Ecstasy (working), slot a
  holds a KNOWN-NON-BOOTING APEX kernel — re-flash before any slot-a trial.
- The APEX kernel (5.15.211) hangs at the Xiaomi logo; plain Zepharo
  variant built and ready for a persistent trial (`new-boot-plain.img` in
  `backups/device-2026-09-07/`).
- Full post-mortem: `docs/FLASH_SESSION_2026-09-07.md`.
