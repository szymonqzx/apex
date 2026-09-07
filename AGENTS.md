# AGENTS.md — APEX Kernel & ROM (agent guidelines)

Cross-harness guidance for AI agents (Devin CLI, Hermes, Claude Code, Codex, …)
working in this repository. Canonical source of truth for commands, layout, and
hard rules.

## Project overview

APEX is a hardened custom kernel + ROM overlay system for the **Redmi Note 12
4G** (topaz / tapas, Snapdragon 685 / SM6225-AD), built on the Zepharo
`zepharo` branch base (Linux **5.15.211**, CAF msm-5.15, GKI-compatible).
Features: KernelSU-Next + SUSFS root/hiding, Baseband-guard anti-brick LSM,
APEX sysfs control plane, charge limiting, thermal learner, WALT scheduler.

The kernel tree itself (`kernel/`) is **not in git** — it is extracted from
`topnotchfreaks/kernel_msm-5.15` (branch `zepharo`) and patched by our series.
A clean checkout + `make build` reproduces the build.

## Key commands

```bash
make patch          # apply patches/apex-new/ series to kernel/ (idempotent)
make build          # incremental kernel build (--clean for full rebuild)
make verify         # verify.sh --strict (Image, features, hardening)
make test           # pytest tests/cert/ (certification suite)
make config         # validate defconfig/apex_defconfig
make package        # AnyKernel3 flashable zip
make device-state   # snapshot device state (run first in every device session)
make lint           # bash -n + check-configs.py + checkpatch if kernel/ present
```

Manual equivalents:

```bash
./tools/build-kernel.sh [--clean|--modules|--dry-run]
./tools/verify.sh [--strict]
python3 -m pytest tests/cert/ -v
python3 tools/check-configs.py
./tools/package-anykernel3.sh
./tools/release.sh <ver> [--build]   # tests + build + tag v<ver>-zepharo + manifest
```

Device tooling lives in `tools/device/` (retry wrappers, safe flasher, boot
verification, feature bisection). See `tools/device/README.md`.

## Repository layout

```
defconfig/apex_defconfig   # Single source of truth (no fragment merging)
patches/apex-new/          # Patch series; series file = order; <name>/apply.sh
anykernel3/                # AnyKernel3 flashable packaging
tools/                     # build / verify / package / release / device scripts
tests/cert/                # pytest certification suite (286 tests)
rom-overlays/              # init scripts, profiles, thermald, SELinux, device.mk
apps/                      # Android apps (apex-control, nfcforge, ptk-tui, lineage-hider)
chroot/                    # bridge daemon + chroot wrappers
agent/ wm/ desktop/ lindroid/  # on-device agent + desktop environments
hiding/                    # root-hiding stack config (SUSFS, Zygisk, etc.)
docs/                      # architecture + design docs (read before major changes)
releases/                  # release manifests + checksums (artifacts are gitignored)
```

## Hard rules

1. **Never commit secrets** (API keys, tokens, keyboxes, private keys).
2. **Never commit build artifacts**: `out/`, `*.ko`, `*.zip`, `*.log`, gradle
   `build/` dirs are gitignored — keep it that way.
3. **`defconfig/apex_defconfig` is the single source of truth.** Config changes
   go there, then `make build` syncs it into the kernel tree. Do not edit
   `kernel/arch/arm64/configs/apex_defconfig` directly.
4. **Kernel code changes go through the patch series**, never by editing
   `kernel/` in place: put source in `patches/apex-new/<name>/src/`, write an
   idempotent `apply.sh`, add an entry to `patches/apex-new/series`.
5. **Conventional commits**: `<type>(<scope>): <summary>` — types `feat`,
   `fix`, `refactor`, `docs`, `test`, `ci`, `chore`, `perf`, `security`.
6. **Version facts must be consistent**: kernel base is 5.15.211 (see
   `kernel/.apex-base`). If you update the base, update README, build scripts,
   `patches/apex-new/series`, and release manifests together.

## Verification expectations

Before claiming a kernel change works: `make build` succeeds, `make verify`
passes, and `make test` (pytest) is green. For releases additionally run
`verify-rom.sh`, `verify-stealth.sh`, `verify-brick-safety.sh` (exit 0) and
`check-configs.py`. Do not fabricate device-test results — device-gated items
(flashing, Play Integrity, runtime behavior) must be labeled as untested on
hardware.

## Project knowledge

- `docs/` holds the architecture (DESIGN.md, BOIL_THE_SEA_PLAN_V2.md, tooling
  landscape in TOOLING.md). Read the relevant doc before major changes.
- Persistent project history and past sessions are indexed in GBrain (query
  slugs `apex-*`, e.g. `apex-rom-completion-state-2026-09-07`).
- Device is currently APatch-rooted, bootloader unlocked, OrangeFox/TWRP
  recovery available; the APEX kernel has not yet been flashed/booted on
  hardware (verify before claiming otherwise).
