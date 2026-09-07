## Summary

<!-- What and why. One paragraph. Reference the issue if one exists. -->

## Changes

<!-- Bullet list of concrete changes, per file/area. -->

## Verification

<!-- Real tool output, not "should work". -->

- [ ] `make build` succeeds (or `./tools/build-kernel.sh --dry-run` for tooling-only changes)
- [ ] `make verify` passes
- [ ] `make test` — pytest `tests/cert/` green
- [ ] `python3 tools/check-configs.py` — clean (if defconfig changed)
- [ ] `bash -n` on any touched shell scripts
- [ ] Device-gated results marked as untested if not run on hardware

## Checklist

- [ ] Conventional commit message (`<type>(<scope>): <summary>`)
- [ ] No secrets / keys / artifacts committed
- [ ] Version facts consistent (5.15.211 base unless intentionally bumped)
- [ ] Kernel changes go through `patches/apex-new/` series (not `kernel/` edits)
