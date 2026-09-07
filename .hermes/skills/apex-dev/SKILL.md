---
name: apex-dev
description: APEX kernel/ROM development — build, verify, test, package, and device ops for the Redmi Note 12 4G (topaz) custom kernel + ROM overlay system
version: 1.0.0
author: szymonqzx
license: GPL-2.0
metadata:
  hermes:
    tags: [android, kernel, rom, topaz, sm6225, ksu, susfs]
    category: android-development
---

# APEX Kernel/ROM Development

APEX is a hardened custom kernel + ROM overlay system for the **Redmi Note 12
4G** (topaz / tapas, Snapdragon 685 / SM6225-AD), built on the Zepharo
`zepharo` branch base (Linux **5.15.211**, CAF msm-5.15, GKI-compatible).

Stack: KernelSU-Next (root) + SUSFS (hiding) + Baseband-guard (anti-brick LSM)
+ APEX sysfs control plane + charge limiting + thermal learner + WALT.

## Canonical commands

| Task | Command |
| :--- | :--- |
| Apply patch series | `./tools/apply-patches.sh` (idempotent) |
| Build kernel | `./tools/build-kernel.sh` (incremental; `--clean` full) |
| Verify build | `./tools/verify.sh --strict` |
| Cert tests | `python3 -m pytest tests/cert/ -v` |
| Validate defconfig | `python3 tools/check-configs.py` |
| Package flashable | `./tools/package-anykernel3.sh` |
| Release | `./tools/release.sh <ver> --build` |
| Device snapshot | `./tools/device/device-state.sh` (run first) |

## Hard rules

1. `kernel/` is NOT tracked in git — never edit it in place. Kernel changes go
   through `patches/apex-new/<name>/` (src/ + idempotent apply.sh + `series`).
2. `defconfig/apex_defconfig` is the single source of truth.
3. Conventional commits (`feat(scope): summary`). No secrets, no artifacts.
4. Version facts: base is 5.15.211 (`kernel/.apex-base`). Keep README /
   build scripts / series / manifests consistent.
5. Device-gated results (flashing, boot, Play Integrity) must be labeled
   untested unless actually run on hardware. Never fabricate device results.

## Verification gate (before claiming "done")

`make build` + `make verify` + `make test` green; releases additionally need
verify-rom.sh, verify-stealth.sh, verify-brick-safety.sh (exit 0).

## Project knowledge

- Architecture docs in `docs/` (DESIGN.md, BOIL_THE_SEA_PLAN_V2.md,
  TOOLING.md, FLASH_SESSION_2026-09-07.md).
- Prior sessions indexed in GBrain under `apex-*` slugs.
- Read `AGENTS.md` at the repo root for the full agent contract.
