# APEX ROM — Boil-the-Sea Implementation Plan v2

**Generated**: 2026-09-06
**Branch**: feat/zepharo-rebase (HEAD: 4e91e83)
**Device**: Redmi Note 12 4G (topaz/tapas), SM6225-AD, 8GB RAM, 128GB UFS 2.2
**Base**: LineageOS 23.2 (Android 16 QPR2)
**Kernel**: APEX v0.4.2 (Linux 5.15.211, KernelSU-Next + SuSFS)
**Previous plan**: docs/BOIL_THE_SEA_PLAN.md (2026-09-05, 11 phases, 18 unimplemented items)
**Completeness at v1**: ~55%
**Completeness now**: ~65% (documentation complete, agent/apps/overlays solid, remaining work is LOS build + packaging + testing)
**Status update 2026-09-07**: Tracks A/B complete, C1 complete (4/4 drivers), D1/D2 implemented (kernel built + verify.sh green), E gates green. See gap table below for per-gap status.

---

## What's Done (verified 2026-09-06)

| Component | Status | Evidence |
|-----------|--------|----------|
| Kernel build | ✅ v0.4.0, 5.15.211, 239 modules | `releases/apex-kernel-0.4.0-zepharo-anykernel3.zip` (70MB) |
| AnyKernel3 flasher | ✅ Fixed (backup→split→write boot only) | verify-rom.sh 28/0/0 |
| Agent spine | ✅ 19 Java files, 3 AIDL, JNI stubs | agent/java/com/apex/agent/ |
| ApexControl app | ✅ 33 Kotlin files, 6 screens | apps/apex-control/ |
| SystemServices app | ✅ 31 Java files (agent+WM+desktop+Lindroid) | system-services/ |
| NFCForge app | ✅ 6 Kotlin files | apps/nfcforge/ |
| PTK TUI app | ✅ 5 Kotlin files | apps/ptk-tui/ |
| KSU module | ✅ 38 files, 17 RC, SELinux, build.prop | ksu-module/ |
| WM code | ✅ AIDL + Java + overlay + sepolicy | wm/ |
| Desktop code | ✅ AIDL + Java + sepolicy | desktop/ |
| Lindroid code | ✅ AIDL + Java + scripts + sepolicy | lindroid/ |
| Chroot bridge | ✅ apex-bridge.c (980 lines), apex-term.sh | chroot/ |
| ROM overlays | ✅ 22 init scripts, thermald, hidden pkgs | rom-overlays/ |
| Hiding stack scripts | ✅ configure_hiding.sh, denylist, install | hiding/ |
| Migration script | ✅ apex-migrate.sh | migration/ |
| Build tools | ✅ 26 scripts (build, package, verify) | tools/ |
| Test suite | ✅ 288 tests, 283 pass, 3 fail, 2 skip | tests/ |
| Documentation library | ✅ 24 files (README + 01-23) | docs/library/ |
| Release artifacts | ✅ 3 zips (70+92+22 MB) | releases/ |
| Kernel patches | ✅ Restructured into patches/apex-new/ (7 dirs) | patches/apex-new/ |
| KernelSU-Next | ✅ 81 .c/.h files in patches/apex-new/apex-root/ | patches/apex-new/apex-root/ |

## What's NOT Done (the remaining sea)

| # | Gap | Phase | Status (2026-09-07) | Impact | Effort |
|---|-----|-------|----------------------|--------|--------|
| G1 | LOS source tree not synced | P2 | OPEN (deferred — disk) | Blocks full ROM build | 1-2 days (I/O bound) |
| G2 | Full ROM build not attempted | P2 | OPEN (deferred — overlay design) | No system.img/vendor.img | 2-4h CPU |
| G3 | Hiding stack modules not packaged | P3 | ✅ CLOSED — `releases/apex-hiding-stack-1.0.0.zip` (ZygiskNext v1.5.0, Shamiko v1.2.5-414, HMA oss-166, TrickyStore v1.4.1, Yurikey v3.0.6), verified KSU modules, pinned URLs in `package-hiding-stack.sh` | 1 day |
| G4 | Out-of-tree pentest drivers not built | P4 | ✅ CLOSED — 8812au/8814au/88x2bu/8188eu built vs 5.15.211, `apex-pentest-modules-1.0.0.zip`; reproducible via `patch-drivers.sh` (IPX stub, cfg80211 5.15 port, extern-inline fix) | 2-3 days |
| G5 | 7-day thermal learner not implemented | P5 | ✅ CLOSED — `patches/apex-new/apex-thermal` (history ring buffer + trips), `apex_thermal_learner.sh` (+/-2C), built into kernel | 2 days |
| G6 | PMIC WDT + safe-mode not implemented | P5 | ✅ CLOSED — `patches/apex-new/apex-wdt` (PON WDT on pm8150/pm6125 compatibles, CONFIG_PM8916_WATCHDOG=m), safe-mode via bootreason + KSU module disable | 2 days |
| G7 | Touch processing pipeline | P5 | OPEN (device-gated) | Research only, no implementation | 3-5 days |
| G8 | AutoFDO profile data | P5 | OPEN (device-gated) | Script exists, no profile | 1 day |
| G9 | 3 test failures | P11 | ✅ CLOSED — 286 passed / 2 skipped | CI not green | 2h |
| G10 | verify-brick-safety.sh bug | P11 | ✅ CLOSED — exits 0; also hardened (size guard + .gradle skip → 16s) | Returns non-zero on pass | 1h |
| G11 | verify.sh timeout | P11 | ✅ CLOSED — Image strings cached + .config checks → **1.6s**, 119 checks, --strict PASS | 60s timeout too short | 30min |
| G12 | scrcpy-server not packaged | P8 | ✅ CLOSED — `desktop/prebuilt/scrcpy-server.jar` (v4.1), shipped in KSU module | Desktop mode non-functional | 1 day |
| G13 | WM/Desktop/Lindroid untested | P7-9 | OPEN (device-gated) — static verification green | Code written, no device test | Requires device |
| G14 | Agent models not packaged | P6 | ✅ CLOSED — `releases/apex-agent-models-1.0.0.zip` (qwen2.5 0.5b/1.5b/3b q4_k_m + whisper tiny.en), names match ModelManager | No GGUF models in release | 1 day |
| G15 | ROM build certification | P11 | PARTIAL — pipeline validated (verify-rom.sh 28/0/0, build-rom.sh dry-run), full LOS build deferred (disk) | No end-to-end build verification | 1 day |

---

## Execution Plan (priority-ordered)

### Track A: Fix What's Broken (immediate, 4h)

**A1. Fix 3 test failures** (2h)
- `test_no_lindroid_in_agent` / `test_no_wm_in_agent`: Update tests to allow MCP tool name registrations in McpRegistry.java while still verifying no implementation code. The tests check for substring "lindroid"/"windowmanager" anywhere in the file — change to check only outside comments and string literals, or better, check that no lindroid/wm *implementation* code exists (only Binder delegation calls).
- `test_verify_script_passes`: Fix verify-brick-safety.sh to return 0 when all checks pass. Debug the script to find which check is failing.

**A2. Fix verify.sh timeout** (30min)
- Increase timeout from 60s to 180s, or optimize the script to skip redundant checks.

**A3. Fix verify-brick-safety.sh** (1h)
- Debug why the script returns non-zero. Read the script, run it manually, identify the failing check.

### Track B: Package What Exists (1-2 days, parallel with Track A)

**B1. Package hiding stack modules** (1 day)
- Download or build: Zygisk-Next, Shamiko, HMA-OSS, TrickyStore
- Package each as a KSU module zip
- Create `apex-hiding-stack-1.0.0.zip` containing all 4 modules
- Update `hiding/install_modules.sh` to install from the zip
- Verify with verify-stealth.sh

**B2. Package agent models** (1 day, parallel with B1)
- Download pre-built GGUF models: qwen2.5-0.5b, qwen2.5-1.5b, qwen2.5-3b, whisper-tiny.en
- Create `apex-agent-models-1.0.0.zip` with models in `/data/adb/apex/models/`
- Add model download fallback in ApexControl (ModelDownloadManager.kt already exists)

**B3. Package scrcpy-server** (1 day, parallel with B1)
- Build scrcpy server jar from source (or download pre-built)
- Add to KSU module under `system/app/scrcpy-server/`
- Update desktop mode scripts to reference the packaged server

### Track C: Build What's Missing (2-5 days, after Track B)

**C1. Build out-of-tree pentest drivers** (2-3 days)
- Clone driver repos: rtl8812au (aircrack v5.6.4.2), rtl88x2bu (Morrown fork), rtl8188eus (monitor patched), rtl8814au
- Build each against APEX kernel headers (`out/`)
- Package as `apex-pentest-modules-1.0.0.zip`
- Verify VID:PID autoload works (requires device)

**C2. Sync LOS source tree** (1-2 days, I/O bound, can start early)
- `repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --depth=1`
- `repo sync -c -j8 --no-tags --no-clone-bundle` (shallow sync to save disk)
- Target: `~/los/` directory, ~80-100GB
- Disk check: 24GB free → need to clear space or use external drive
- **BLOCKER**: 24GB free is not enough for full LOS tree (~100GB). Options:
  - (a) Clean build artifacts (`out/` is ~15GB, `build/` is ~2GB) → frees ~17GB → 41GB total
  - (b) Use external USB drive for LOS tree
  - (c) Selective sync (only device + framework repos, skip unused)
  - **Recommended**: (a) + (c) — clean build artifacts and selective sync

**C3. Build ROM from LOS source** (2-4h CPU, after C2)
- Apply APEX overlays to LOS source tree
- `source build/envsetup.sh && lunch apex_topaz-userdebug`
- `m apex_topaz` (or `m systemimage vendorimage`)
- Output: system.img, vendor.img, boot.img
- Package with `tools/package-rom.sh`

### Track D: Implement Missing Features (3-10 days, after Track C)

**D1. 7-day thermal learner** (2 days)
- Implement in kernel: `/proc/apex/thermal_history` ring buffer
- Userspace: `apex_thermal_learner.sh` reads history, adjusts thresholds
- Safe defaults: 45/55/65°C from day one
- Learner shifts thresholds by ±2°C based on 7-day rolling average
- Add to `rom-overlays/init.d/apex_thermal_learner.rc`

**D2. PMIC WDT + safe-mode** (2 days)
- Kernel: PMIC watchdog timer (pm8150_wdt) kicks every 30s
- If system hangs: WDT fires → hardware reboot → safe-mode flag
- Safe-mode: `apex_safe_mode.rc` disables KSU module on boot if flag set
- User can clear safe-mode from ApexControl

**D3. Touch processing pipeline** (3-5 days, research-first)
- Read docs/TOUCH_PIPELINE_RESEARCH.md
- Implement touch event processing improvements in kernel
- Profile with `hyperfine` on device (requires device)
- **Low priority** — research only until device is available

**D4. AutoFDO profile** (1 day)
- Run `tools/autofdo-build.sh` with profile data from device usage
- Requires device to collect profile
- **Low priority** — no device, no profile

### Track E: End-to-End Verification (1-2 days, after Track C)

**E1. Full build certification** (1 day)
- Run all verification scripts with extended timeout
- `verify.sh` 180s timeout
- `verify-rom.sh`, `verify-stealth.sh`, `verify-daily-driver.sh`, `verify-brick-safety.sh`
- All must pass with 0 FAIL

**E2. Test suite green** (2h)
- Fix remaining test failures (Track A)
- All 288 tests pass (or 3 are explicitly skipped with documented reason)

**E3. Release manifest** (1h)
- `tools/release.sh` generates manifest with SHA256 for all artifacts
- Artifacts: kernel zip, ROM zip, KSU module zip, hiding stack zip, pentest modules zip, agent models zip
- Verify all checksums

### Track F: Device Testing (requires physical device, not blocking)

**F1. Flash kernel** → verify boot
**F2. Flash KSU module** → verify overlays
**F3. Test agent** → chat, consent, tools
**F4. Test hiding stack** → Play Integrity, banking apps
**F5. Test WM/Desktop** → freeform windows, scrcpy
**F6. Test Lindroid** → container start, exec, display
**F7. Test pentest** → plug USB Wi-Fi adapter, verify autoload
**F8. Test daily-driver** → 48h soak test

---

## Critical Path

```
Track A (fix tests) ──────────────────────────────────────────────┐
                                                                   │
Track B1 (hiding stack) ──────────────────────────────────►│      │
Track B2 (agent models) ──────────────────────────────────►│      │
Track B3 (scrcpy-server) ─────────────────────────────────►│      │
                                                            │      │
Track C1 (pentest drivers) ───────────────────────────────►│      │
Track C2 (LOS sync) ──► Track C3 (ROM build) ─────────────►│      │
                                                            │      │
Track D1 (thermal learner) ───────────────────────────────►│      │
Track D2 (PMIC WDT) ──────────────────────────────────────►│      │
                                                            ▼      ▼
Track E (verification) ────────────────────────────────────────────┘
                                                            │
                                                            ▼
Track F (device testing) ──────────────────────────────────────────┘
```

**Critical path**: A → C2 → C3 → E (fix tests → sync LOS → build ROM → verify)
**Parallel tracks**: B1/B2/B3, C1, D1/D2 all run independently
**Device-gated**: F (all device testing), D3/D4 (touch/AutoFDO need device)

---

## Disk Space Plan

Current: 24GB free on /home (217GB total, 189GB used)

| Action | Space freed | Space needed | Net |
|--------|-------------|--------------|-----|
| Clean `out/` (kernel build) | +15GB | 0 | +15GB |
| Clean `build/` (APK build) | +2GB | 0 | +2GB |
| LOS shallow sync | 0 | ~80GB | -80GB |
| LOS build output | 0 | ~20GB | -20GB |
| Pentest driver build | 0 | ~5GB | -5GB |
| **Total** | +17GB | -105GB | **-88GB** |

**Problem**: Need 105GB, have 24+17=41GB. Shortfall: 64GB.

**Solutions** (pick one):
1. **External USB drive** (recommended): mount 128GB+ USB drive at ~/los
2. **Selective LOS sync**: only sync `device/xiaomi/topaz` + `frameworks/base` + `packages/apps/Settings` + core deps → ~30-40GB
3. **Skip full ROM build**: continue with KSU module overlay approach (no system.img needed). The ROM works as dirty-flash overlays on top of existing LineageOS install.
4. **Cloud build**: use a cloud VM with more disk for the ROM build

**Recommended**: Option 3 (skip full ROM build) for now. The KSU module overlay approach is the design — a full ROM build is a nice-to-have, not a must-have. The ROM was always designed as dirty-flash overlays, not a standalone ROM image.

---

## Updated Effort Estimates

| Track | Effort | Dependencies | Device Required? |
|-------|--------|--------------|------------------|
| A — Fix tests | 4h | None | No |
| B1 — Hiding stack | 1 day | None | No |
| B2 — Agent models | 1 day | None | No |
| B3 — scrcpy-server | 1 day | None | No |
| C1 — Pentest drivers | 2-3 days | Kernel headers | No |
| C2 — LOS sync | 1-2 days | Disk space | No |
| C3 — ROM build | 2-4h | C2 | No |
| D1 — Thermal learner | 2 days | None | No (code only) |
| D2 — PMIC WDT | 2 days | None | No (code only) |
| D3 — Touch pipeline | 3-5 days | Research | Yes |
| D4 — AutoFDO | 1 day | Profile data | Yes |
| E — Verification | 1-2 days | A, B, C | No |
| F — Device testing | 2-3 days | Everything | Yes |

**Total without device**: 10-16 days
**Total with device**: 13-19 days
**Critical path**: 5-8 days (A → C2 → C3 → E, or A → B → E if skipping ROM build)

---

## Decision: Skip Full ROM Build?

The original DESIGN.md says "dirty-applied overlays only" — the ROM was never designed as a standalone flashable ROM image. The KSU module overlay approach IS the design. A full LOS build would produce system.img/vendor.img, but the user would still dirty-flash it on top of existing LineageOS.

**Recommendation**: Skip C2/C3 (LOS sync + ROM build) for now. Focus on:
1. Track A (fix tests) — 4h
2. Track B (package hiding stack, models, scrcpy) — 1-2 days
3. Track C1 (pentest drivers) — 2-3 days
4. Track D1/D2 (thermal learner, PMIC WDT) — 4 days
5. Track E (verification) — 1-2 days

This gets us from ~65% to ~90% completion without needing 100GB of disk space or a physical device. The remaining 10% is device testing (Track F) and the optional full ROM build.

---

## Next Actions (Immediate)

1. **Fix 3 test failures** (Track A) — unblock CI
2. **Fix verify-brick-safety.sh** (Track A) — unblock test_verify_script_passes
3. **Package hiding stack modules** (Track B1) — make hiding stack functional
4. **Package agent models** (Track B2) — make agent functional on-device
5. **Package scrcpy-server** (Track B3) — make desktop mode functional
6. **Build pentest drivers** (Track C1) — make pentest tools functional
7. **Implement thermal learner** (Track D1) — close zero-maintenance gap
8. **Implement PMIC WDT + safe-mode** (Track D2) — close recovery gap
9. **Full verification pass** (Track E) — prove everything works
