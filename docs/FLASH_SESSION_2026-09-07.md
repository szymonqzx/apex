# APEX Flash Session Post-Mortem — 2026-09-07

First physical-device flash attempt of the APEX kernel on the user's topaz
(Redmi Note 12 4G, model 23021RAA2Y, serial 2860a48f). Outcome: the APEX
kernel does not boot on this device yet (hangs at the Xiaomi logo). This
document records every finding so future sessions (and the Hermes agent)
start from verified ground truth.

## Current device state (as of end of session)

| Item | State |
|---|---|
| Active slot | `b` — original Ecstasy kernel (5.15.202-Ecstasy-v1.0+), working, data intact |
| Slot `a` boot | **HAS the FULL APEX kernel (0.4.0) flashed from the failed trial — KNOWN NON-BOOTING.** Re-flash before any slot-a trial |
| Root | APatch (me.bmax.apatch / apd v11224) — active on slot b |
| ROM | AOSP 16 (BP4A.251205.006 release-keys), security patch 2026-03-01 |
| Bootloader | **UNLOCKED** (fastboot: `unlocked:yes`) — runtime props report locked (stale; fastboot is authoritative) |
| USB | Link physically degraded (see below) |

## Findings

### 1. The APEX kernel hangs at the Xiaomi logo (no boot)

- Full APEX 0.4.0 (Sep 7 build #2, 5.15.211-g7bc9793d909f) flashed to slot a
  → stuck at logo, no adb, pstore empty.
- pstore/ramoops IS active (ramoops@5D000000, console at 0.47s) but captured
  nothing → the failure is a **hang or a panic before the ramoops dump**,
  not a capturable panic.
- Suspects (all APEX-only features, absent from the working Ecstasy kernel):
  KernelSU-Next + SUSFS hooks, Baseband Guard LSM, apex-thermal built-in,
  HZ=300 (Ecstasy uses HZ=250), CONFIG_CMDLINE differences.
- **Bisection in progress**: a "plain Zepharo" variant (KSU/SUSFS/BBG/
  APEX_THERMAL all disabled) was built (build #3) and a boot image prepared
  (`backups/device-2026-09-07/new-boot-plain.img`) — **NOT yet persistently
  tested** (the RAM `fastboot boot` trial was inconclusive; a persistent
  slot-a flash + user kernel check in Settings→About is the next step).
- The defconfig is currently in the BISECTION state (features disabled;
  backup at `/tmp/apex_defconfig.bak`) — restore before committing.
- Old Sep 5 build is unrecoverable (releases zip overwritten, out/ rebuilt).

### 2. Device / ROM facts (verified)

- GKI header v4 boot images, **kernel-only (RAMDISK_SZ=0; ramdisk lives in
  init_boot)** — kernel swaps are clean, no ramdisk surgery needed.
- 128MB boot partitions; boot_a (47MB kernel) ≠ boot_b (42MB kernel).
- vbmeta flags=0 (AVB verification enabled in vbmeta), verifiedbootstate
  green, bootloader locked at the time — yet the device booted a
  KernelPatch-modified kernel ⇒ **the bootloader does not enforce the boot
  partition hash**. (Now unlocked anyway.)
- Ecstasy config (via /proc/config.gz): ThinLTO+CFI, HZ=250, PREEMPT,
  MODULE_SIG=y + MODULE_SIG_PROTECT=y (SHA1), CMDLINE
  `stack_depot_disable=on kasan.stacktrace=off kvm-arm.mode=protected
  cgroup_disable=pressure`. NO KernelSU, NO BBG.
- APEX config: HZ=300, CMDLINE `cgroup_disable=pressure`, KSU+SUSFS+BBG+
  APEX_THERMAL on. MODULE_SIG status not yet compared (vendor modules are
  sig-protected on this ROM — a key mismatch would kill WiFi etc., not the
  logo hang, but still matters).
- USB IDs: adb=18d1:4ee2, fastboot=18d1:d00d, recovery-ish=18d1:4e11.

### 3. Environment / tooling gaps (why this took so long)

- **USB link physically degraded**: EMI drops (`usb 1-1: disabled by hub
  (EMI?)`), re-enumerations, hung fastboot transfers (needed kill+retry),
  finally `error -71` descriptor failures (full-speed fallback, no
  enumeration). Cable/port is marginal; keep a known-good cable.
- **USB debugging drops intermittently on the ROM** (user-reported) —
  screen-lock/USB-mode-flip related; keep screen awake during transfers.
- `fastboot set_active` failed once with "Device does not support slots"
  (link casualty) — retry works.
- `adb reboot bootloader` sometimes lost to the dying link — manual
  Vol-Down+Power entry is 100% reliable.
- No serial console, no reliable panic capture → boot failures are hard to
  diagnose on-device; bisection-by-rebuild is the practical method.
- Fastboot protocol is far more tolerant than adb on this link.

### 4. What worked

- magiskboot for x86_64 (extracted from Magisk-v30.7.apk
  `lib/x86_64/libmagiskboot.so`) → full boot-image surgery on the laptop.
- One-slot-at-a-time A/B trials with slot b as the untouched safety net —
  recovery was trivial (`fastboot set_active b`).
- fastboot flash + set_active with kill+retry on stuck transfers.

## Next steps (when flashing resumes)

1. Restore the canonical defconfig (git checkout) after bisection completes.
2. Persistent plain-kernel slot-a trial → user reads kernel in
   Settings→About. 5.15.211 ⇒ feature bisection (KSU → SUSFS → BBG →
   APEX_THERMAL → HZ/CMDLINE); logo-stuck ⇒ base-kernel issue.
3. If a feature is the culprit: fix or gate it, then re-run the full flash.
4. Only after the kernel boots: install KernelSU-Next manager + APEX KSU
   module stack (root migration off APatch was the user's chosen path).

## Artifacts

- Backups: `backups/device-2026-09-07/{boot_a,boot_b,ori}.img`
- Boot images built: `new-boot.img` (full APEX), `new-boot-plain.img`
  (bisection variant) — in the same backups dir
- Repackaged release: `releases/apex-kernel-0.4.0-zepharo-anykernel3.zip`
  (236M, 491 modules — contains the Sep 7 build, NOT the stale Sep 5 one)
