# APEX Development Roadmap

**Version**: 1.0 — 2026-09-07
**Branch**: feat/zepharo-rebase
**Device**: Redmi Note 12 4G (topaz/tapas), SM6225-AD
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
2. **Proven-recipe alignment**: the XDA research (2026-09-07,
   `docs/TOOLING.md` "Kernel ecosystem on XDA") showed every kernel that
   boots this device is built on the ACK/GKI recipe with AOSP prebuilt clang.
   Deviations are only allowed with a documented reason.
3. **Surgical + verified**: patch series only (never edit `kernel/` in
   place), `defconfig/apex_defconfig` as single source of truth, PEV loop on
   every change, CI parity locally (shellcheck/shfmt/pytest).
4. **GBrain sync**: durable facts/decisions written back per session (Iron
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

## Phase 1 — Kernel stabilization + root/hiding parity

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
5. **Performance/upstream** — LTO=thin local default; AutoFDO profile (G8);
   touch pipeline research (G7); benchmark vs Ecstasy 5.15.202 baseline
   (Geekbench, battery drain, thermals).

### Exit criteria

- 7-day daily-driver soak: no random reboot, sane battery/thermals, deep
  sleep working
- Play Integrity STRONG; all 5 banking apps function
- `make verify`/`make test` green at every commit; CI matrix
  (plain/ksu/susfs/bbg/thermal/full) green

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
Phase 0 (boot) ──► Phase 1 (stabilize) ──► Phase 2 (ROM) ──► Phase 4 (release)
                        │                       ▲
                        └── Phase 3 (agent) ────┘   (agent apps can start
                                                      in parallel; kernel
                                                      root needed for device)
```

Phase 3's app-side work can begin before Phase 1 completes (static dev +
emulator), but device validation needs a booting kernel. Phase 4 gates on
Phase 1 (stability is the release currency).

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

## References

- `docs/BOIL_THE_SEA_PLAN_V2.md` — gap table (G1-G15) and per-component status
- `docs/TOOLING.md` — "Kernel ecosystem on XDA" (recipe, P0 quirks, DTB/module strategy)
- `docs/DESIGN.md`, `docs/UPDATE_ARCHITECTURE.md`, `docs/DIRTY_FLASH_UPGRADE_SPEC.md`
- `docs/FLASH_SESSION_2026-09-07.md` — device session log (boot hang, toolset fixes)
- GBrain: `apex-xda-research-2026-09-07`, `apex-r9-recipe-investigation-2026-09-07`,
  `apex-topaz-device-flash-session-2026-09-07`, `apex-rom-completion-state-2026-09-07`
