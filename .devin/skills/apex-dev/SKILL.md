---
name: apex-dev
description: APEX kernel/ROM development workflow — build, verify, test, package, and device ops for the Redmi Note 12 4G (topaz) custom kernel
allowed-tools:
  - read
  - grep
  - glob
  - exec
permissions:
  allow:
    - Exec(git)
    - Exec(bash tools/*)
    - Exec(make *)
    - Exec(python3 -m pytest *)
    - Read(**)
  deny:
    - Exec(git push --force*)
    - Exec(sudo *)
---

# APEX Kernel/ROM Development

Guide an agent through APEX development work. The project: a hardened custom
kernel + ROM overlay system for the Redmi Note 12 4G (topaz/tapas, SM6225-AD),
Linux 5.15.211 on the Zepharo `zepharo` branch base.

## Standard loop (PEV)

1. **Plan**: read `AGENTS.md`, the relevant `docs/` design doc (DESIGN.md,
   BOIL_THE_SEA_PLAN_V2.md, TOOLING.md), and check GBrain for prior session
   notes (`apex-*` slugs) before touching anything.
2. **Execute**: one bounded step at a time.
   - Kernel code changes go into `patches/apex-new/<name>/` (src/ + idempotent
     apply.sh + series entry) — never edit `kernel/` in place.
   - Config changes go in `defconfig/apex_defconfig` only.
3. **Verify**: prove it with real tool output:
   - `make build` (or `./tools/build-kernel.sh --dry-run` for a fast check)
   - `make verify` (verify.sh --strict)
   - `make test` (pytest tests/cert/)
   - `python3 tools/check-configs.py` for defconfig edits

## Fast iteration

- `./tools/build-kernel.sh --dry-run` — structural check without building.
- `./tools/verify.sh` — ~2s post-build check (Image, features, hardening).
- Kernel builds are incremental; `--clean` only when the tree is inconsistent.
- Out-of-tree driver builds: `./tools/build-pentest-drivers.sh`.

## Device sessions

If the device is attached:

1. `./tools/device/device-state.sh` — snapshot first, every session.
2. Use `adb-retry.sh` / `fastboot-retry.sh` wrappers (flaky USB).
3. `./tools/device/flash-boot.sh` — safety-first: flashes the inactive slot,
   verifies sha256 after write, requires explicit `--activate`.
4. `./tools/device/boot-test.sh --json` — boot verification with distinct
   exit codes (0/2/3/4); collect logs with `collect-boot-log.sh`.

These are all "ask-first" operations — never flash without explicit user
approval, and never claim device-verified results unless you actually ran them.

## Reporting

Report: what changed (paths), verification output (pass/fail counts), what is
still device-gated/untested, and any assumptions made. Cite sources for
non-obvious claims ([Source: ...]).
