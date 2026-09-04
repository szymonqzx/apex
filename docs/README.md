# docs

## Status

The documents in this directory are **historical planning/research notes**
from the original "boil-the-sea" design phase (pre-Zepharo rebase). They
describe a much larger planned feature set (apex-governor, apex-state,
apex-watchdog, apex-immortal, apex-lmk, apex-display, KernelSU/SuSFS,
CASS scheduler, etc.) that was **not** included in the shipped v0.2.0 kernel.

**Do not treat them as current documentation.** For the actual implemented
state, see:

- [README.md](../README.md) — project overview, build, install
- [defconfig/README.md](../defconfig/README.md) — kernel configuration
- [patches/README.md](../patches/README.md) — applied patch series
- [tools/README.md](../tools/README.md) — build/verify/package/release tooling
- [CHANGELOG.md](../CHANGELOG.md) — release history

## Historical documents

| Document | Original purpose |
| :--- | :--- |
| `DESIGN.md` | Original APEX kernel design (pre-rebase plan) |
| `BUILD_PLAN.md` | Original phased build plan (phases 0–8, superseded) |
| `CHARGE_PERFECT_PLAN.md` | Advanced charge-manager design (not shipped) |
| `CUSTOM_KERNEL_SYNTHESIS.md` | Research synthesis of topaz custom kernels |
| `ARCHITECTURE_ANALYSIS.md` | SM6225-AD architecture analysis |
| `TOUCH_PIPELINE_RESEARCH.md` | Touch pipeline research |
| `UNDERDEVELOPED_AUDIT.md` | Audit of underdeveloped areas in the original plan |
