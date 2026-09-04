# Contributing to APEX kernel

Thanks for considering contributing. This project targets the Redmi Note 12
4G (topaz/tapas) with a custom 5.15 kernel — production discipline matters.

## Repository layout

```
defconfig/
  apex_defconfig          # Single source of truth for kernel config
  profile-*.config        # Optional overlays (battery / balanced / performance)
patches/apex-new/         # Patch series applied to the kernel tree
  series                  # Ordered list of patches (git-quilt style)
  <name>/apply.sh         # Per-patch installer (idempotent)
anykernel3/               # AnyKernel3 flashable packaging
tools/                    # Build, verify, package, release tooling
tests/cert/               # Certification test suite (pytest)
kernel/                   # Kernel tree — NOT tracked in git (large source)
docs/                     # Architecture and design docs
```

> **Note:** `kernel/` is not in git. It is the Zepharo R9 base tree; the
> build script applies `patches/apex-new/` and syncs `defconfig/apex_defconfig`
> into it. A clean checkout reproduces the build as long as the kernel base
> archive is extracted to `kernel/`.

## Development workflow

1. **Fork / branch.** Work on a feature branch, not `main`.
2. **Kernel changes** go into `patches/apex-new/<name>/`:
   - Put the source file(s) in `<name>/src/` (or `legacy/` for backports).
   - Write an idempotent `apply.sh <kernel-dir>` that installs them.
   - Add the patch to `patches/apex-new/series` with a one-line description.
3. **Config changes** edit `defconfig/apex_defconfig` directly (it is the
   source of truth). Use `scripts/kconfig/merge_config.sh` only for
   profile overlays.
4. **Code style:** every C file must pass
   `./scripts/checkpatch.pl --no-tree -f <file>` with zero errors and
   warnings. New files need an SPDX-License-Identifier (`GPL-2.0`).
5. **Build:** `./tools/build-kernel.sh` (incremental) or `--clean`.
6. **Verify:** `./tools/verify.sh --strict`.
7. **Test:** `python3 -m pytest tests/cert/ -v`.
8. **Commit** with a conventional-commit message, e.g.
   `feat: add apex-cpuboost input-driven frequency booster`.

## Commit conventions

- Format: `<type>(<scope>): <summary>` — types: `feat`, `fix`, `refactor`,
  `docs`, `test`, `ci`, `chore`, `perf`, `security`.
- Keep commits focused; one logical change per commit.
- Do not commit secrets, keys, or credentials.
- Do not commit build artifacts (`out/`, `*.ko`, `*.zip`, `*.log`).

## Releasing

Releases are cut with `./tools/release.sh <version>`:

1. Runs the certification test suite.
2. Builds (with `--build`), packages the AnyKernel3 zip.
3. Generates checksums and a release manifest.
4. Creates a git tag `v<version>-zepharo`.

Versioning is SemVer: bump major for breaking device support changes, minor
for new features, patch for fixes.

## Testing checklist before a release

- [ ] `./tools/build-kernel.sh --clean` succeeds with zero errors
- [ ] `./tools/verify.sh --strict` passes
- [ ] `python3 -m pytest tests/cert/ -v` — all pass
- [ ] APEX C files pass `checkpatch.pl` clean
- [ ] `bash -n` on all shell scripts
- [ ] AnyKernel3 zip contains `zImage`, `modules/`, `apex-load-modules.sh`
- [ ] `release.sh` manifest lists correct patches and config

## Reporting issues

Include: device variant (topaz/tapas), ROM + Android version, kernel version
(`/sys/class/apex/version`), the exact command that failed, and a log
(`dmesg` or `logcat` where relevant).
