# AGENT BRIEF — Complete the APEX ROM "Remaining Sea"

You are an autonomous engineering agent. Your mission is to take the APEX
kernel/ROM project from its current ~65% completion state to ~90%+ by closing
every gap below. Work through the steps in order. Verify each step with real
tool output before moving on — "should work" is not evidence.

## Context

- Repo: `/home/takon/apex` (branch `feat/zepharo-rebase`, HEAD `4e91e83`)
- Device: Redmi Note 12 4G (topaz/tapas), SM6225-AD, 8GB RAM
- Kernel: Linux 5.15.211, Zepharo base, Clang 22.1.8, KernelSU-Next + SUSFS
- Plan: `docs/BOIL_THE_SEA_PLAN_V2.md` (gap table G1-G15), `docs/BOIL_THE_SEA_PLAN.md` (phases 1-11)
- The ROM is designed as **dirty-flash overlays** (KSU module) on top of an
  existing LineageOS 23.2 install — NOT a standalone ROM image.

## Verified state (as of 2026-09-07) — trust but re-verify

| Item | State |
|---|---|
| Test suite | 286 passed, 2 skipped — the 3 historical failures are FIXED in the **working tree (uncommitted)** |
| verify-brick-safety.sh | FIXED in working tree — exits 0 (was returning non-zero on pass) |
| verify.sh | Takes ~52s wall. Hot path: `in_image()` runs `strings "$IMAGE"` per check (~115x on a 37MB Image) |
| Phase 1 kernel audit | Done — patches restructured into `patches/apex-new/` (7 dirs, `series` present) |
| Phase 2 LOS | NOT synced — no `~/los`. Disk: 24GB free of 217GB. Full shallow sync needs ~80GB+ |
| Phase 3 hiding | Scripts only — `hiding/prebuilt/` is EMPTY. `package-hiding-stack.sh` URLs are placeholders |
| Phase 4 pentest | No out-of-tree builds — no `out/pentest-drivers`. Toolchain present (clang 22.1.8, aarch64-linux-gnu-gcc, zip) |
| Phase 5 zero-maint | Thermal learner, PMIC WDT, safe-mode NOT implemented |
| Phase 6 agent | Mostly done — no GGUF models packaged |
| Phase 7-9 WM/Desktop/Lindroid | Code written, never compiled/tested. scrcpy-server not packaged |
| Phase 10 daily-driver | `verify-daily-driver.sh` exists, verification only |
| Phase 11 pipeline | Scripts exist; some not functional. `build/` dir, `.gradle/`, gradle `build/` outputs NOT in `.gitignore` (build junk is tracked in git) |
| Kernel source | `kernel/` present (1.5G), `out/` has 478 .ko, `out/arch/arm64/boot/Image` (37MB) built |
| Releases | kernel 0.4.0 zip, rom-flashable zip, ksu-module zip. Missing: hiding stack, pentest, models, scrcpy |

## Hard constraints (never violate)

1. **Brick-safety**: never write to bootloader/aboot/sbl/tz/rpm/hyp/modem/
   partition tables — in any script, patch, or update path. Every new artifact
   must keep `tools/verify-brick-safety.sh` passing (exit 0).
2. **No secrets**: never commit API keys/tokens. TrickyStore ships a
   *placeholder* keybox only — do NOT fetch real keyboxes. Yurikey keybox
   provisioning is the user's job; document it, don't do it.
3. **No fabrication**: no physical device is available — do NOT invent device
   test results. Device-gated work = implement + static-verify + mark pending.
4. **Git**: conventional commits, no GPG. Review diffs before committing.
5. **Disk budget**: 24GB free. Watch `df -h` as you go. Never start a download
   that the remaining budget can't hold.
6. **Scope**: no ALOS dual-boot, no GPU inference, no USB-C display (hardware
   limits). Do not "improve" unrelated code.

## Work plan

### Step 0 — Baseline + repo hygiene (1-2h)

1. Re-verify the state table: run the test suite, brick-safety, time verify.sh.
   Note any drift from the table above.
2. Review the uncommitted working-tree changes (`git status`, `git diff`).
   They include real fixes: `tests/agent/test_agent_security.py` (scope-drift
   tests now allow MCP tool registrations in `McpRegistry.java`),
   `tools/verify-brick-safety.sh` (skip docs/verify-* scripts), plus
   `anykernel3/anykernel.sh`, `tools/package-anykernel3.sh`,
   `.github/workflows/ci.yml`, `agent/aidl/...`, app sources. Commit them as:
   `fix: test suite green + brick-safety script + anykernel packaging fixes`
3. Fix `.gitignore`: add `.gradle/`, `build/`, `**/build/`, `.kotlin/`,
   `local.properties`, `*.apk`. Untrack already-committed build junk with
   `git rm -r --cached` (e.g. `apps/apex-control/.gradle/`, any
   `apps/*/app/build/`, `apps/*/build/`, root `build/`). Do NOT delete files —
   only untrack. Verify `git status` is clean of build artifacts afterwards.
4. Reconcile doc inconsistency: `patches/apex-new/series` header says "Zepharo
   R9 base (Linux 5.15.170)", `README.md` and plan say 5.15.211. Check
   `kernel/Makefile` for the real version; fix whichever doc is wrong.
5. Acceptance: full suite green, brick-safety exit 0, `git status` shows only
   intentional changes, one `fix:` commit landed.

### Step 1 — Phase 1 kernel audit: verify the restructure (1-2h)

Mostly done — prove it:

1. `python3 tools/check-configs.py` — defconfig is the single source of truth.
2. Inspect `tools/apply-patches.sh`; verify `patches/apex-new/series` matches
   the 7 dirs and that each dir has a working `apply.sh`. If the script
   supports a dry-run/idempotency check, run it.
3. `bash tools/verify.sh --strict` — currently 115 checks, 2 warnings. It must
   PASS with `--strict` (0 warnings) after Step 2's optimization and any
   legitimate fixes. Every warning needs a real fix or a justified, documented
   exception.
4. Acceptance: config check passes, series intact, verify.sh --strict green.

### Step 2 — Fix verify.sh timeout (G11, 30min)

Root cause is confirmed: `in_image()` shell function (line 39 of
`tools/verify.sh`) runs `strings "$IMAGE"` for every check (~115 times on a
37MB Image). Fix:

1. Extract the image strings ONCE at the top:
   `IMAGE_STRINGS="$(strings "$IMAGE" 2>/dev/null || true)"` and have
   `in_image()` grep the variable instead of re-running `strings`.
2. Keep the existing `MODULE_STRINGS` single-extraction pattern (already good).
3. Benchmark: target < 10s wall for `bash tools/verify.sh --strict`.
4. Acceptance: verify.sh --strict PASS in < 10s, no check coverage lost.

### Step 3 — Phase 3 hiding stack packaging (G3, 0.5-1 day)

1. Read `hiding/install_modules.sh`, `hiding/configure_hiding.sh`,
   `hiding/denylist.conf` to learn the expected module layout
   (`/system/apex/modules/*.zip` per the installer).
2. Run `tools/package-hiding-stack.sh` — it downloads 4 zips (zygisk_next,
   shamiko, hma_oss, tricky_store). The URLs are placeholders: verify each one
   resolves; if a URL 404s, find the correct current pinned release URL on
   GitHub (shamiko: LSPosed repo releases; TrickyStore: 5ec1cff/TrickyStore;
   HMA-OSS: AlirezaIvwmd/HMA-OSS; ZygiskNext: stable release). Pin the verified
   URLs back into the script and remove the "placeholders" note.
3. Package `apex-hiding-stack-1.0.0.zip` containing the 4 module zips +
   denylist.conf + install/configure scripts, following the layout
   `tools/package-ksu-module.sh` uses, and add the result into the KSU module
   zip under `system/apex/modules/` so `install_modules.sh` finds it on first
   boot.
4. Run `bash tools/verify-stealth.sh` and `bash tools/verify-rom.sh` — both
   must pass.
5. Acceptance: 4 real module zips in `releases/` (or `hiding/prebuilt/`),
   pinned URLs in the script, verify-stealth.sh + verify-rom.sh green.
6. Record in the docs that the Yurikey keybox is user-supplied (separate
   one-time provisioning step), not a module zip.

### Step 4 — Phase 4 out-of-tree pentest drivers (G4, 2-3 days)

1. Run `bash tools/build-pentest-drivers.sh`. It clones 6 repos
   (rtl8812au, rtl8814au, rtl88x2bu, rtl8188eus, mt7610u, mt7612u) and builds
   against `kernel/` + `out/`.
2. Expect build friction (5.15 + clang 22): the script may need
   `LLVM=1`/`LLVM_IAS=1`, correct `KSRC`/`KOBJ`/`KDIR` exports, or per-driver
   make overrides. Fix the script, don't work around it by hand.
3. Success = ≥4 of 6 drivers produce `.ko`. A driver that won't build against
   5.15 (API drift) gets documented in the script's comments — do NOT let one
   failure block the rest.
4. Acceptance: `releases/apex-pentest-modules-1.0.0-*.zip` + `.sha256` with the
   built `.ko` files; `verify-brick-safety.sh` still passes (module builds only).
5. VID:PID autoload verification needs a device — mark as device-pending.

### Step 5 — Phase 5 zero-maintenance (G5, G6, 2-4 days)

Implement both as new patch dirs under `patches/apex-new/` following the
existing per-patch structure (`src/` + `apply.sh` + defconfig fragment) and add
them to `series`.

**D1 — 7-day thermal learner:**
- Kernel: `/proc/apex/thermal_history` ring buffer (temperature samples).
- Userspace: `apex_thermal_learner.sh` reads history, adjusts thermal
  thresholds ±2°C against a 7-day rolling average; safe defaults 45/55/65°C
  from day one.
- Init: `rom-overlays/init.d/apex_thermal_learner.rc`, wired into
  `rom-overlays/device/apex_device.mk`.

**D2 — PMIC WDT + safe-mode:**
- Find the actual PMIC for topaz (check the device DTS in
  `kernel/arch/arm64/boot/dts/qcom/` — SM6225 platforms typically pair with a
  PM6125; use the real compatible, don't assume). Implement the watchdog kick
  (every 30s) against that PMIC's WDT node.
- On watchdog-triggered reboot: set a safe-mode flag; `apex_safe_mode.rc`
  disables the KSU module at boot when the flag is set; expose clearing the
  flag via ApexControl.
- Safe-mode must never require touching boot partitions (brick-safety).

**Both:** after implementing, apply patches (`tools/apply-patches.sh`,
idempotent) and do an incremental kernel build (`tools/build-kernel.sh`,
out/ is warm so this is feasible). Compile-check your new code — a patch that
doesn't compile is not done. `verify.sh` and `verify-brick-safety.sh` must stay
green. Update `TODOS.md` statuses.

### Step 6 — Phase 6 agent models packaging (G14, 0.5-1 day)

1. Read `agent/java/com/apex/agent/ModelManager.java` and
   `apps/apex-control/.../ModelDownloadManager.kt` FIRST — use the exact model
   paths, file names, and quantization the code expects. Don't guess.
2. Download: qwen2.5 0.5b / 1.5b / 3b instruct (GGUF, Q4_K_M or smaller) +
   whisper-tiny.en (or whisper-small.en). Budget ~3.5GB; confirm disk first.
3. Package `apex-agent-models-1.0.0.zip` with the models at the code-expected
   paths (e.g. `/data/adb/apex/models/`).
4. Acceptance: zip + sha256 in `releases/`, layout matches ModelManager.

### Step 7 — Phase 8 scrcpy-server packaging (G12, 0.5 day)

1. Read `tools/build-scrcpy-server.sh` and the desktop mode scripts
   (`desktop/scripts/*.sh`) to learn where the server is expected.
2. Build from source if the script works (needs gradle/Java — check
   availability); otherwise download a prebuilt scrcpy-server jar from the
   official GitHub release matching the scrcpy client version the scripts use.
3. Package into the KSU module zip (`system/app/scrcpy-server/` per plan).
4. Acceptance: server present in module zip; `verify-rom.sh` green.

### Step 8 — Phase 2 LOS + Phase 11 pipeline (G1, G2, G15, 0.5-1 day)

Disk reality: 24GB free; a shallow LOS 23.2 sync needs ~80GB+. **Do not**
attempt the full sync on this disk, and do not fragment a selective sync that
can't build. Per `docs/BOIL_THE_SEA_PLAN_V2.md` (recommended option 3), the ROM
is overlay-based — a full LOS build is a nice-to-have.

Instead:

1. Verify the pipeline is wired correctly:
   - `bash -n` every script under `tools/`.
   - `bash tools/build-rom.sh --dry-run` (and `--version`) — it must fail
     cleanly with a clear "LOS source not synced" message, not a crash.
   - `bash tools/package-rom.sh --help`/`--version` if supported.
   - `bash tools/verify-rom.sh` — must pass (this is the ROM-structure gate
     that does NOT need a build tree). Fix any FAILs.
2. Fix any non-functional pipeline script (e.g. wrong paths, missing shebangs,
   unset vars) so every tool is at least dry-run/version functional.
3. Document the LOS build path for later (external USB drive or bigger disk):
   the exact `repo init`/`repo sync` commands, disk requirements, and the
   build sequence (`build-rom.sh`). Put it in the plan doc, not a new file.
4. Acceptance: all tools pass `bash -n`; `verify-rom.sh` 0 FAIL; build-rom.sh
   --dry-run behaves correctly; the "later" path documented.

### Step 9 — Phase 7-9 WM/Desktop/Lindroid static verification (G13, 1-2h)

Device testing is out of scope — do everything verifiable without a device:

1. Check if the Android SDK is usable (`~/android-sdk` exists). If yes, attempt
   `./gradlew assembleRelease` (or `assembleDebug`) in `apps/apex-control/`
   (gradle wrapper is present) and the other apps; fix compile errors in the
   app code. This is the strongest non-device proof the app layer works.
   Watch disk (gradle downloads) and time — cap effort at a few hours.
2. Run the CI static gates locally that cover these subsystems: AIDL
   well-formedness, SELinux `type` declarations, init.d RC triggers, device.mk
   wiring, Compose annotations (mirror `.github/workflows/ci.yml`).
3. Acceptance: app builds (if SDK usable) or documented blocker; all static
   gates green.

### Step 10 — Phase 10 daily-driver verification (1h)

- `bash tools/verify-daily-driver.sh`. CI notes it may show config-name
  differences — investigate and fix real FAILs (WARNs acceptable but aim to
  clear them). Acceptance: 0 FAIL.

### Step 11 — Final verification gate + release manifest (2h)

1. Full suite: `python3 -m pytest tests/ -q` — 286 passed, 2 skipped (document
   the 2 skips in the plan doc).
2. All gates green: `verify.sh --strict` (<10s), `verify-brick-safety.sh`
   (exit 0), `verify-rom.sh`, `verify-stealth.sh`, `verify-daily-driver.sh`
   (0 FAIL), `python3 tools/check-configs.py`.
3. Create `releases/apex-release-1.0.0.manifest` listing every artifact with
   SHA256: kernel zip, rom-flashable zip, ksu-module zip, hiding-stack zip,
   pentest-modules zip, agent-models zip (whichever exist).
4. Update `docs/BOIL_THE_SEA_PLAN_V2.md`: mark each gap G1-G15 with final
   status + evidence. Update `TODOS.md`.
5. Commit all work as focused conventional commits (e.g. `feat(hiding): ...`,
   `feat(kernel): thermal learner`, `fix(verify): cache Image strings`).
   Push nothing unless asked.

## Final definition of done

- All gates in Step 11 green with captured output.
- New artifacts in `releases/` with checksums: hiding stack, pentest modules,
  agent models, scrcpy-in-ksu-module.
- Kernel patches for thermal learner + PMIC WDT/safe-mode applied and
  compile-verified.
- Repo hygiene: no build artifacts tracked, gitignore covers gradle outputs.
- Plan doc updated with per-gap evidence and the documented LOS-build-later
  path.
- Explicit list of what remains device-gated (Track F: flash, PI/banking test,
  WM/desktop/Lindroid runtime, USB Wi-Fi autoload, 48h soak).

## Out of scope (do not attempt)

- Physical device flashing/testing (Track F)
- Touch processing pipeline (D3) and AutoFDO (D4) — both need device data
- ALOS/DSU dual-boot, GPU inference, USB-C display
- Full LOS sync/build on this disk (documented as the later path)
