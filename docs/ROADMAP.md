# APEX Development Roadmap

**Version**: 1.2 — 2026-09-07 (v1.1 added Phase 1b — kernel feature bounty;
v1.2 adds Phase 2b — the ROM feature bounty)
**Branch**: feat/zepharo-rebase
**Device**: Redmi Note 12 4G (topaz/tapas), SM6225-AD
**Scope**: **KERNEL + ROM + agent ecosystem** — APEX is a full custom-ROM
project, not a kernel-only project. Kernel (Phases 0/1/1b) and ROM
(Phases 2/2b) are co-equal halves of the same product; the agent ecosystem
(Phase 3) ships inside the ROM.
**Companion docs**: `BOIL_THE_SEA_PLAN_V2.md` (implementation plan, gap table),
`TOOLING.md` (ecosystem + build recipe), `DESIGN.md` (architecture),
`FLASH_SESSION_2026-09-07.md` (device session log), `UPDATE_ARCHITECTURE.md`
(OTA decision).

This roadmap is the forward plan. It supersedes the plan-only framing of
BOIL_THE_SEA_PLAN_V2 by adding hardware-first gating: **nothing counts until
it boots on the phone.** The repo is statically strong; device validation is
the currency that makes it real.

## Principles

1. **Hardware-first**: every phase gates on on-device evidence (boot, logs,
   user-visible function). Static green (compile/tests) is necessary, not
   sufficient.
2. **Kernel + ROM are one product**: features are scoped to both halves —
   kernel features (Phase 1b) and ROM features (Phase 2b) are planned,
   governed, and released together. A kernel feature with no ROM surface
   (or a ROM feature with no kernel support) is half-done.
3. **Proven-recipe alignment**: the XDA research (2026-09-07,
   `docs/TOOLING.md` "Kernel ecosystem on XDA") showed every kernel that
   boots this device is built on the ACK/GKI recipe with AOSP prebuilt clang.
   Deviations are only allowed with a documented reason.
4. **Surgical + verified**: patch series only (never edit `kernel/` in
   place), `defconfig/apex_defconfig` as single source of truth, PEV loop on
   every change, CI parity locally (shellcheck/shfmt/pytest).
5. **GBrain sync**: durable facts/decisions written back per session (Iron
   Law), so the roadmap's assumptions stay auditable.

## State snapshot (verified 2026-09-07)

| Area | Status | Evidence |
|---|---|---|
| Kernel base | Zepharo branch, 5.15.211, `kernel/` = TNF clone @ 7bc9793d9 | `kernel/.apex-base`, `git -C kernel log` |
| Patch series | 11 patches (9 APEX + thermald-cores + vendor-kmsg), all applied + idempotent | `apply-patches.sh --check` |
| Tests | `make test` 97 passed / 2 skipped; `make verify` 121 PASS / 0 warn | runs 2026-09-07 |
| Toolchain | CI pinned AOSP clang r547379; local auto-prefers `~/.apex-toolchain` when fetched (not yet — distro clang 22.1.8 fallback) | `tools/build-kernel.sh` |
| Packaging | AnyKernel3 zip; `APEX_NO_MODULES=1` flag added (default 491 .ko) | `tools/package-anykernel3.sh` |
| ROM | LOS 23.2 (A16) base chosen; overlays/init/sepolicy written; **no LOS sync, no full build** | BOIL_THE_SEA_PLAN_V2 gaps G1/G2 |
| Agent/apps | Spine, ApexControl, NFCForge, PTK-TUI, models packaged; **no device test** | BOIL_THE_SEA_PLAN_V2 (G13) |
| **On-device boot** | **NEVER — kernel hangs at Xiaomi logo; bisection in progress; R9 image flash-ready** | `FLASH_SESSION_2026-09-07.md` |

Open gaps inherited from BOIL_THE_SEA_PLAN_V2: G1 (LOS source sync), G2 (full
ROM build), G7 (touch pipeline), G8 (AutoFDO profile), G13 (WM/Desktop/
Lindroid device validation).

---

## Phase 0 — Boot: get APEX on hardware (CRITICAL PATH)

**Goal**: an APEX-built kernel boots to Android on the device, reproducibly.

**Blocking everything** — no kernel feature, ROM, or agent work is real until
this passes. The current hang (stuck at Xiaomi logo, kernel dies pre-display,
no panic record) is being bisected; the decisive experiment is already built.

### Steps

1. **Flash the R9 image** — `new-boot-r9.img` (zepharo tree + `gki_defconfig`
   + AOSP clang r547379, ThinLTO) via `tools/device/flash-boot.sh` with
   `STUCK_KILL_AFTER≈240`, slot a, slot b untouched. Fastboot manual entry
   (Vol-Down+Power) is the reliable path; use `fastboot-retry.sh`.
2. **Read the result** — Settings→About kernel (5.15.211 ⇒ booted), plus
   `boot-test.sh --json`, `collect-boot-log.sh` (pstore/ramoops + dmesg),
   bootreason.
3. **Branch A — R9 boots**: run the feature bisection (`stages-gki.txt`):
   plain → +KernelSU-Next → +SUSFS → +BBG → +APEX thermal. First stage that
   hangs is the culprit; fix (config-gate or patch) rather than carry a
   silent breaker.
4. **Branch B — R9 logo-stuck**: DTB triage first — dump the device DTB from
   the running boot image, verify ramoops placement (Ecstasy relocates it to
   9ff00000; our failed boots had empty pstore at 5D000000), try
   Ecstasy-style patched DTBs (`fixup-dtbs.sh` pattern). Then
   toolchain/config deltas, then source-level triage of the zepharo ACK+CLO
   merge.
5. **First recovery-flash** — once booting, validate the AnyKernel3 zip path
   via TWRP/OrangeFox (this is how testers will install it).

### Exit criteria

- 3 consecutive clean boots on slot a with data intact
- `boot-test.sh --json` exit 0; dmesg free of critical errors
- APEX sysfs present (`/sys/class/apex/`); KSU/SUSFS/BBG/thermal modules
  confirmed in kernel strings + runtime
- pstore captures a real boot log (ramoops placement resolved)

### Risks

| Risk | Mitigation |
|---|---|
| Flaky USB link (EMI, adb dies) | fastboot-retry + STUCK_KILL_AFTER≈240; manual fastboot entry; keep screen awake |
| LTO-full OOM (15G RAM + 16G swap) | ThinLTO locally; LTO-full only in CI with 10GB+ swap (TNF pattern) |
| Empty pstore on hang | Verify DTB ramoops placement; Ecstasy relocates to 9ff00000 |
| R9 not actually representative (CLO zepharo ≠ ACK) | Escalate to ACK `android13-5.15-lts` + `vendor/bengal_GKI.config` base (Ecstasy recipe) |

---

## Phase 1 — Kernel stabilization (the stable core)

**Goal**: APEX kernel is a daily driver: stable, fully featured, hiding stack
works against the user's banking stack.

### Steps

1. **Vendor module compatibility** — WiFi/BT/sensors/camera/audio modules
   must load (KMI/MODVERSIONS + signature policy already match gki_defconfig;
   verify empirically). Decide the zip module default on evidence:
   `APEX_NO_MODULES=1` (ROM dlkm) vs shipping ours.
2. **Root + hiding on-device** — KSU-Next root; SUSFS hiding (path/mount/
   kstat/maps); Play Integrity STRONG via TrickyStore + keybox + yurikey +
   zygisk_next + HMA + lineage-hider (`hiding/`, `releases/
   apex-hiding-stack-1.1.0.zip`). Target apps: Revolut, PayPal, Crédit
   Agricole, Paysafecard, Google Wallet.
3. **Feature validation matrix** — BBG (dd to boot block must be blocked),
   charge limit (brake at threshold, `apex-charge`), thermal learner,
   PMIC WDT + safe-mode, apex-control app round-trip.
4. **Defconfig strategy decision (D1)** — keep `apex_defconfig` or move to
   GKI-style (`gki_defconfig` + delta fragment) per the research. Either way
   HZ=250, PREEMPT, CMDLINE already aligned; validate KMI preservation.
5. **Performance/upstream baseline** — LTO=thin local default; benchmark vs
   Ecstasy 5.15.202 baseline (Geekbench, battery drain, thermals, app
   cold-start); AutoFDO profile collection (G8).

### Exit criteria

- 7-day daily-driver soak: no random reboot, sane battery/thermals, deep
  sleep working
- Play Integrity STRONG; all 5 banking apps function
- `make verify`/`make test` green at every commit; CI matrix
  (plain/ksu/susfs/bbg/thermal/full) green
- **Baseline benchmarks captured** — every feature added in Phase 1b must
  beat (or tie) this baseline; regressions block the merge

---

## Phase 1b — Kernel feature bounty (the plentiful kernel)

**Goal**: APEX becomes the most feature-rich kernel for the device family —
without losing the "cleanest engineering" crown. Features are
config-guarded so every one can be bisected independently
(`stages-features.txt` extends `stages-gki.txt`).

**Governance**: each feature needs (a) a `check-configs.py` entry, (b) a
`verify.sh` check, (c) a cert test where testable, (d) a benchmark or
measurement against the Phase 1 baseline, (e) a docs/FEATURES.md row.
Status legend: **HAVE** (in apex_defconfig/base already), **PORT**
(port from an ecosystem kernel with a source), **NEW** (APEX-original),
**RESEARCH** (investigate before committing — may not pan out on SM6225).

### 1. Scheduler & CPU

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| WALT scheduler | HAVE | — | — | `apex-walt-scheddebug` guards SCHED_DEBUG |
| Schedhorizon governor | HAVE | — | — | In zepharo base (`CONFIG_CPU_FREQ_GOV_SCHEDHORIZON=y`) |
| EAS + energy model | HAVE | — | — | `CONFIG_ENERGY_MODEL=y` |
| schedutil tuning | PORT | P1 | S | Tune up/down thresholds, rate limits |
| CPU input boost / touch boost | PORT | P1 | S | From Zephyr-lineage kernels; validate with touch pipeline (G7) |
| E-cores/P-cores affinity policy | NEW | P2 | M | `apex-thermald-cores` groundwork; per-foreground-app affinity via apex sysfs |
| Forced lazy RCU | PORT | P2 | S | ChicKernel |
| Power-efficient workqueues | PORT | P2 | S | ChicKernel |
| Boeffla wakelock blocker | PORT | P2 | M | ChicKernel; sysfs list |
| Devfreq governor tuning (DDR/GPU) | PORT | P2 | M | Validate on khaje devfreq nodes |
| HMP/energy-aware placement tuning | PORT | P3 | M | Measured against baseline |

### 2. Memory & reclaim

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| MGLRU | HAVE | — | — | `CONFIG_LRU_GEN` + ENABLED |
| KSM | HAVE | — | — | + ksmd tuning for 4GB |
| ZRAM zstd + writeback | HAVE | — | — | `CONFIG_ZRAM_WRITEBACK`; add a sysfs policy (NEW) |
| DAMON reclaim | HAVE | — | — | `CONFIG_DAMON_RECLAIM`; wire to apex sysfs (NEW) |
| 4GB LMK/psi tuning | PORT | P1 | M | ChicKernel "tuned memory management for 4GB" + PSI thresholds |
| VMA/slab micro-opts | PORT | P3 | M | Only with measured gains |
| zswap (alternative to zram) | RESEARCH | P3 | S | Compare vs ZRAM on this SoC |

### 3. I/O & filesystems

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| F2FS compression suites | HAVE | — | — | lz4/lz4hc/lzo/zstd + DIO opts in base |
| EROFS | HAVE | — | — | For future read-only partitions |
| exFAT | HAVE | — | — | Native driver |
| SSG I/O scheduler | PORT | P1 | M | ChicKernel default; bench vs mq-deadline |
| I/O latency QoS tuning | PORT | P2 | M | blk-mq + qcom blk crypto |
| Readahead / reclaim-governed IO | PORT | P3 | S | Bench cold-start |

### 4. Network & netfilter

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| BBRv3 + tcp_plb | HAVE | — | — | In zepharo base |
| WireGuard | HAVE | — | — | Built-in |
| Westwood default TCP | PORT | P2 | S | ChicKernel default; keep BBR selectable |
| **nftables** | NEW | P1 | M | **GAP: not enabled** (only legacy iptables/xtables today) — enable `CONFIG_NFT_*` for modern firewall apps |
| TUN | HAVE | — | — | VPN clients |
| MPTCP | RESEARCH | P3 | L | Nebula has it; heavy, needs kernel 5.15 MPTCP backport + validation |
| Netfilter extras (owner/mark/socket) | HAVE | — | — | Xtables set is already extensive |

### 5. Power, battery & thermal

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| Charge limit (bq2589x) | HAVE | — | — | `apex-charge`, CHARGE_CONTROL_END_THRESHOLD |
| Fuel gauge sm5602 | HAVE | — | — | Native in base (io-channel fixed) |
| Battery auth (ds28e16) | HAVE | — | — | In `apex-device-backports` |
| Thermal learner | HAVE | — | — | History ring + tunable trips |
| mi_thermald P-core redirect | HAVE | — | — | `apex-thermald-cores` |
| PMIC WDT + safe mode | HAVE | — | — | `apex-wdt` |
| Charge/thermal power dashboard sysfs | NEW | P1 | M | APEX-original: unified `/sys/class/apex/power/*` |
| Battery idle mode (charging pause/resume) | NEW | P2 | M | Extend bq2589x with idle + pulse charging policy |
| USB fast-charge policy control | NEW | P2 | M | tcpm/bq2589x sysfs policy |
| Devfreq thermal governors | PORT | P3 | M | Align with thermal learner |

### 6. Display, GPU & audio

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| KCAL color control | PORT | P2 | M | Port from MSM display lineage; needs driver support check (RESEARCH first) |
| HBM (high-brightness mode) | PORT | P3 | M | Panel/backlight driver support check |
| Adreno/GPU DVFS tuning | PORT | P2 | M | kgsl devfreq; validate on khaje |
| Panel refresh/backlight curve | PORT | P3 | S | DSI panel tuning |
| Audio gain control | RESEARCH | P3 | M | Mostly userspace (mixer paths); skip if HAL covers it |

### 7. Security & hardening (APEX DNA)

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| CFI + SCS | HAVE | — | — | + shadow call stack |
| Stack protector strong | HAVE | — | — | |
| Lockdown LSM | HAVE | — | — | Not force-enabled; decide policy (D8) |
| Baseband guard (BBG) | HAVE | — | — | `apex-baseband-guard` |
| KMI protection (MODVERSIONS) | HAVE | — | — | Matches gki_defconfig |
| Module signing | HAVE | — | — | SIG + SIG_PROTECT, SHA1 |
| KVM | HAVE | — | — | `CONFIG_KVM=y` — explore on-device VMs (RESEARCH) |
| Hardened usercopy / refcount | PORT | P2 | S | Upstream hardening backports |
| SELinux strict (ROM side) | HAVE | — | — | Neverallow audits in Phase 2 |
| IMA / fs-verity | RESEARCH | P3 | L | Heavy; fs-verity more tractable for ROM |

### 8. Root & hiding

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| KernelSU-Next | HAVE | — | — | `apex-root` |
| SUSFS (path/mount/kstat/maps/cmdline) | HAVE | — | — | Cmdline spoof in hiding stack v1.1.0 |
| TrickyStore + yurikey + zygisk_next + HMA | HAVE | — | — | `releases/apex-hiding-stack-1.1.0.zip` |
| lineage-hider (Xposed) | HAVE | — | — | |
| Play Integrity STRONG | P0 target | — | — | Phase 1a gate |
| ReSukiSU alternative | RESEARCH | P3 | M | Zepharo lineage uses it; evaluate vs KSU-Next |
| KSU module manager (in-kernel) | NEW | P2 | M | Signed-module gate for KSU modules (APEX-original) |

### 9. Diagnostics & tooling

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| pstore/ramoops (placement fix) | P0 | — | — | Phase 0 gate; Ecstasy moves to 9ff00000 |
| PMIC WDT bootreason | HAVE | — | — | safe-mode basis |
| KPROBES/FTRACE | HAVE | — | — | Dev builds |
| Boot-time tracing (bootconfig) | NEW | P2 | S | `bootconfig` initramfs support |
| drgn/vmcore analysis | PORT | P2 | M | osandov/drgn on pstore dumps |
| Apex sysfs + thermal history | HAVE | — | — | |

### 10. Novel APEX features (differentiators)

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| `/sys/class/apex/*` control plane | HAVE | — | — | Version/base/features nodes |
| Unified power dashboard sysfs | NEW | P1 | M | charge+thermal+battery in one tree |
| Feature-flags sysfs (runtime toggles) | NEW | P1 | M | Gate features at runtime for bisection on-device |
| KSU module signing | NEW | P2 | M | Above (8) |
| Boot-profile system (per-mode kernel profiles) | NEW | P2 | L | Performance/battery/balanced sysfs profiles |
| `apex_thermal_learner.sh` (+/-2C) | HAVE | — | — | |

### Phase 1b acceptance

- All P0/P1 features shipped with docs/FEATURES.md rows, verify checks, and
  baseline-beating measurements
- Feature matrix CI job: every config-guarded feature compiles in its own
  stage (extends the WildKernels-style matrix)
- No regressions: cert suite grows past 150; 7-day soak repeats after the
  bounty lands
- Every RESEARCH item either promoted (with evidence) or explicitly dropped
  with the reason recorded

### Phase 1b risks

| Risk | Mitigation |
|---|---|
| Feature bloat destabilizes the kernel | Config-guard everything; bisection stages; one feature per merge |
| Ports from other SoCs don't apply to khaje | RESEARCH gate: driver-support check before PORT |
| Benchmark noise on a 4GB device | Controlled runs (same ROM, same ambient), 3-run median |
| MPTCP/KVM/LRNG soak time | Keep P3/RESEARCH; no deadline pressure |

---

## Phase 2 — APEX ROM (kernel + LOS 23.2 + overlays)

**Goal**: a unified APEX ROM — LineageOS 23.2 base with the APEX kernel,
overlays, hiding stack, and agent services integrated.

### Steps

1. **LOS source sync (G1)** — `docker-lineage-cicd` containerized build
   (preferred; avoids manual ~80GB sync). Disk planning first.
2. **Device bring-up** — SM6225-Android-Playground device tree +
   proprietary vendor blobs (LOS 23.2 uses these); kernel override via
   `TARGET_KERNEL_SOURCE`/`TARGET_KERNEL_CONFIG`.
3. **Overlay integration** — `rom-overlays/` (22 init scripts, thermald,
   SELinux, `device.mk`), hiding stack, agent services; cherry-picks from
   EvoX/RisingOS/AxionOS (all LOS-compatible) as wanted.
4. **Build + flash (G2)** — full ROM build; clean + dirty flash paths
   documented (`DIRTY_FLASH_UPGRADE_SPEC.md`); update architecture decision
   (D3, `UPDATE_ARCHITECTURE.md`: Virtual A/B vs OTA).
5. **OTA + AVB** — `android_packages_apps_Updater` / Evolution-X/OTA; avbroot
   / Android_boot_image_editor for vbmeta-clean builds (locked-bootloader
   users).

### Exit criteria

- Reproducible ROM build (same inputs → same hash)
- APEX ROM daily-drivable; kernel-required ROM (APEX kernel is a dependency)
- Update path works without data loss; brick-safety verified

---

## Phase 2b — ROM feature bounty (the full product)

**Goal**: the ROM half of APEX is as feature-rich as the kernel half. Same
governance as Phase 1b: each feature = config/overlay-guarded, verify-checked,
benchmarked or measured, docs/FEATURES.md row, one feature per merge.
Status legend: **HAVE** (already in `rom-overlays/`/apps/repo), **PORT**
(from an ecosystem ROM with a source), **NEW** (APEX-original), **RESEARCH**
(investigate before committing). Every row notes its kernel dependency
(which Phase 1b kernel feature it needs, if any).

### 1. Base & platform

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| LOS 23.2 (A16 QPR2) base | HAVE | — | — | — | Chosen base (landscape research) |
| APEX kernel as ROM requirement | HAVE | — | — | Phase 0/1 | `TARGET_KERNEL_SOURCE/CONFIG` override |
| docker-lineage-cicd builds | HAVE (tool) | P0 | M | — | G1: containerized, reproducible |
| SM6225-Android-Playground device tree + vendor blobs | HAVE | — | — | — | LOS 23.2 uses these |
| Firmware bundle (OS.2.0.204.0.VMGMIXM) | PORT | P1 | S | — | Ship verified firmware in install docs |
| Reproducible-build manifests (version-sync) | HAVE | — | — | — | `version-sync.sh` pattern |

### 2. UI & device parts

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| XiaomiParts-style device parts app | PORT | P1 | M | — | dt2w, audio jack, Bluetooth audio, brightness (RisingOS imports it from sdm845-common) |
| Blur + status-bar overlays | HAVE | — | — | — | LOS changelog: blur, status bar padding, reduce-blur a11y toggle |
| MiuiCamera | HAVE | — | — | — | LOS 23.2 ships it |
| FM Radio | RESEARCH | P2 | M | — | topaz has FM hardware; verify HAL/app support (user asked on XDA) |
| Sensors MultiHAL | HAVE | — | — | — | LOS migrated to Xiaomi Common Sensor MultiHAL |
| Headset button fix | PORT | P2 | S | — | XDA bug thread 4798775 — wired headset buttons broken on custom ROMs |
| Audio stutter fix | PORT | P2 | M | — | PixelOS users report stutter on topaz; fix via HAL/policy |
| NFC stack (topaz) + NFCForge | HAVE | — | — | — | `apps/nfcforge`; NFC is topaz-only |

### 3. Audio & media

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| Dolby Atmos (SM6225-AD) | PORT | P1 | M | — | org has `android_hardware_dolby`; crDroid ships Dolby on topaz |
| Dirac sound | PORT | P2 | M | — | Alternative to Dolby |
| Audio HAL tuning (AGC, speaker gains) | PORT | P2 | M | — | Also covers the PixelOS stutter |
| MiuiCamera extras (48MP, night) | PORT | P3 | M | — | Blob/config work |

### 4. Performance

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| ProtonAOSP opts (AxionOS lineage) | PORT | P1 | M | — | Cherry-pickable into LOS |
| ScrollOptimizer | PORT | P2 | S | — | AxionOS |
| ART/dex tuning for 4GB | PORT | P2 | M | — | Heap/GC profiles |
| Lightweight GApps choice (vanilla/microG/nano) | HAVE | — | — | — | LOS vanilla + MindTheGapps + microG option (lineageos4microg) |
| Boot profile integration (kernel profiles → ROM policy) | NEW | P2 | L | Phase 1b §10 | apex sysfs profiles drive ROM perf modes |

### 5. Privacy & security

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| Hiding stack in-ROM (SUSFS + LSPosed + TrickyStore) | HAVE | — | — | Phase 1b §8 | `hiding/` + `releases/apex-hiding-stack-1.1.0.zip` |
| SELinux strict + neverallow audit | HAVE (base) | P1 | M | — | Device + platform policies |
| Default firewall (nftables userspace) | NEW | P1 | M | Phase 1b §4 (nftables) | AFWall+ or in-ROM policy; per-app rules |
| Privacy dashboard / permission hardening | PORT | P2 | M | — | AOSP privacy + LOS extras |
| microG variant | PORT | P2 | L | — | GMS-free APEX edition |

### 6. Agent ecosystem (Phase 3 surface)

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| ApexControl (cockpit app) | HAVE | — | — | — | 33 Kotlin files, 6 screens |
| Agent spine (AAOSP port to A16) | HAVE (code) | P1 | L | — | Port LlmManagerService + MCP + consent/audit (D4) |
| Models (Qwen 1.5B/3B + whisper) | HAVE | — | — | — | `releases/apex-agent-models-1.0.0.zip` |
| MCP tools (apex-charge, apex-tune) | NEW | P1 | M | Phase 1b §5/§10 | First system tools |
| Agent memory (FBE-encrypted vector store) | NEW | P2 | L | — | |

### 7. Desktop & Lindroid

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| Desktop mode (scrcpy) | HAVE | — | — | — | scrcpy-server v4.1 packaged |
| APEX WM (vxwm) | HAVE (code) | P2 | L | — | Device validation = G13 |
| Lindroid | HAVE (code) | P3 | L | — | Device validation = G13 |
| Arch chroot bridge | HAVE | — | — | — | `apex-bridge.c`, apex-term.sh |

### 8. Updates & OTA

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| OTA (Updater / Evolution-X/OTA) | PORT | P1 | M | — | Phase 2.5 |
| Virtual A/B vs OTA decision (D3) | OPEN | P0 | — | — | `UPDATE_ARCHITECTURE.md` |
| Dirty-flash spec | HAVE | — | — | — | `DIRTY_FLASH_UPGRADE_SPEC.md` |
| AVB-clean builds (avbroot) | PORT | P2 | M | — | Locked-bootloader users |
| Incremental/ab-ota packages | RESEARCH | P3 | L | — | payload-dumper-go reference |

### 9. APEX first-party apps

| Feature | Status | Pri | Effort | Notes |
|---|---|---|---|---|
| apex-control (cockpit) | HAVE | — | — | Also: charge/thermal/power dashboard UI (NEW, P1) |
| nfcforge | HAVE | — | — | topaz NFC |
| ptk-tui | HAVE | — | — | |
| lineage-hider (Xposed) | HAVE | — | — | Hiding stack |
| Updater app (ROM-branded) | PORT | P2 | M | |

### 10. Novel APEX ROM features (differentiators)

| Feature | Status | Pri | Effort | Kernel dep | Notes |
|---|---|---|---|---|---|
| Power dashboard app (charge+thermal+battery) | NEW | P1 | M | Phase 1b §5 sysfs | UI over `/sys/class/apex/power/*` |
| Feature-flag app (runtime kernel toggles) | NEW | P1 | M | Phase 1b §10 sysfs | Companion to kernel feature toggles |
| Boot-profile UI (per-mode kernel profiles) | NEW | P2 | L | Phase 1b §10 | Performance/Battery/Balanced |
| Hiding-stack installer (one-tap) | HAVE | — | — | — | `configure_hiding.sh` → app |
| Agent-in-ROM deep links (ApexControl ↔ MCP) | NEW | P2 | M | — | |

### Phase 2b acceptance

- P0/P1 ROM features shipped in the first APEX ROM build with
  docs/FEATURES.md rows
- Every ROM feature has a verify.sh check (build-time) and, where possible,
  an on-device cert test
- Kernel↔ROM dependency pairs (nftables↔firewall, apex sysfs↔dashboard app,
  feature toggles↔flag app) are tracked together in FEATURES.md — neither
  half ships alone
- 7-day soak on the full ROM; dirty-flash + clean-flash both pass

---

## Phase 3 — Agent + desktop ecosystem (differentiators)

**Goal**: on-device AI agent + desktop environments, per the approved design
(`apex-rom-design-approved`).

### Steps

1. **Agent spine on A16** — AAOSP is A15-locked: real port of
   LlmManagerService + MCP registry + consent/audit. Decide daemon placement
   (D4): `apexagentd` native daemon vs system_server host.
2. **Models** — llama.cpp arm64 (cross-compile), Qwen 1.5B default / 3B
   opt-in (models already packaged: `releases/apex-agent-models-1.0.0.zip`);
   whisper.cpp STT + wake-word; vector store FBE-encrypted; debug log in
   Apex Control.
3. **Apex Control UX** — chat surface, model router, audit viewer, model
   download manager; consent UX spec (channel, screen-off, anti-phishing).
4. **WM/Desktop/Lindroid device validation (G13)** — scrcpy-server (packaged
   v4.1), vxwm, chroot bridge (`apex-bridge.c`), desktop + Lindroid modes.
   Note: USB-C DP is impossible on this device (FSA4480 mux) — scrcpy/
   Miracast only.

### Exit criteria

- "Call John" MCP flow works consent-gated + audit-logged; model tier
  switchable without reboot
- Agent crash cannot take down system_server (isolation proven)
- Desktop mode functional over scrcpy; WM stable

---

## Phase 4 — Release engineering + community

**Goal**: credible public v1.0 with users.

### Steps

1. **Release pipeline** — `make release` (tests + build + tag + manifest,
   `tools/release.sh`), version-sync, GitHub releases; repo visibility
   decision (D5).
2. **CI hardening** — WildKernels-style kernel matrix on every commit;
   ccache + AOSP clang caching (already in place); CI enforces
   shellcheck/shfmt/pytest.
3. **Security** — `SECURITY.md` disclosure path (7-day, private advisory),
   CODEOWNERS, gitleaks; never commit secrets.
4. **Community** — coordinate with Helios (feature twin, actively seeking
   testers — share the flash/bisection matrix); XDA thread + install docs;
   tester program on ≥2 devices (topaz + tapas for A/B coverage); A17
   target (PixelOS 17 compat) and firmware OS.2.0.204.0.VMGMIXM.

### Exit criteria

- v1.0 tagged; CI green; install docs complete
- ≥3 external testers daily-driving; bug reports flowing through the issue
  templates

---

## Cross-cutting (ongoing)

- **Toolchain**: run `tools/device/fetch-toolchain.sh` once (1.1GB) so local
  default builds use AOSP clang r547379.
- **GBrain**: write back every session's facts/decisions with sources
  (Iron Law); keep `apex-*` pages current.
- **Tests**: grow the cert suite past 150 (add on-device boot tests once
  Phase 0 lands); keep verify.sh fast (1.6s).
- **Docs**: keep ROADMAP/TOOLING/FLASH_SESSION current; log every device
  session.
- **Second device**: a tapas unit widens A/B coverage and protects the daily
  driver during flash experiments.

## Critical path

```
Phase 0 (boot) ──► Phase 1 (stabilize) ──► Phase 1b (kernel bounty)
        │                │                        │
        │                └──► Phase 2 (ROM) ──► Phase 2b (ROM bounty) ◄──┘
        │                        │                        │
        │                        └──► Phase 3 (agent) ────┘
        │                                │
        └──► Phase 4 (release) ◄──────────┘
```

Phase 3's app-side work can begin before Phase 1 completes (static dev +
emulator), but device validation needs a booting kernel. Phase 4 gates on
Phases 1 + 1b + 2b (stability and the kernel+ROM feature set are the release
currency). Phase 2 freezes on the Phase 1b P1 set; Phase 2b ships the ROM
bounty on top — kernel↔ROM feature pairs land together.

## Decisions needed (open, owner: user)

| # | Decision | Where it lands | Default/tilt |
|---|---|---|---|
| D1 | Defconfig strategy: `apex_defconfig` vs GKI-style config + delta | Phase 1.4 | GKI-style (research evidence) |
| D2 | Root philosophy: KSU-Next root shipped (decided) vs hardened no-root | Phase 1.2 | KSU-Next + SUSFS |
| D3 | Update architecture: Virtual A/B vs OTA | Phase 2.4 | `UPDATE_ARCHITECTURE.md` |
| D4 | Agent daemon placement: `apexagentd` vs system_server | Phase 3.1 | `apexagentd` (stability) |
| D5 | Repo visibility: private → public timeline | Phase 4.1 | private until v1.0 |
| D6 | Zip module default after on-device evidence | Phase 1.1 | APEX_NO_MODULES=1 if dlkm works |
| D7 | Helios coordination scope | Phase 4.4 | tester + patch exchange |
| D8 | Lockdown LSM policy (force-enable vs permissive) | Phase 1b §7 | permissive until ROM lands |
| D9 | Kernel-bounty scope for v1.0 (which P2/P3 rows ship) | Phase 1b | P0/P1 mandatory; P2 on evidence |
| D10 | ROM-bounty scope for v1.0 (which P2/P3 rows ship) | Phase 2b | P0/P1 mandatory; P2 on evidence |
| D11 | FM Radio: pursue or drop (HAL/app support check) | Phase 2b §2 | drop if HAL unsupported |
| D12 | Dolby vs Dirac vs neither | Phase 2b §3 | Dolby (org has android_hardware_dolby) |

## References

- `docs/BOIL_THE_SEA_PLAN_V2.md` — gap table (G1-G15) and per-component status
- `docs/TOOLING.md` — "Kernel ecosystem on XDA" (recipe, P0 quirks, DTB/module strategy)
- `docs/DESIGN.md`, `docs/UPDATE_ARCHITECTURE.md`, `docs/DIRTY_FLASH_UPGRADE_SPEC.md`
- `docs/FLASH_SESSION_2026-09-07.md` — device session log (boot hang, toolset fixes)
- GBrain: `apex-xda-research-2026-09-07`, `apex-r9-recipe-investigation-2026-09-07`,
  `apex-topaz-device-flash-session-2026-09-07`, `apex-rom-completion-state-2026-09-07`
