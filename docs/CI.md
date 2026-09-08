# APEX CI/CD — GitHub Actions setup (research + operations)

Researched and set up 2026-09-08. Two halves: **kernel builds** (free on
GitHub-hosted runners) and **ROM builds** (need a self-hosted or paid larger
runner). Companion: `docs/TOOLING.md`.

## Research findings (verified 2026-09-08)

### GitHub-hosted runners

- Standard `ubuntu-latest`: 4-core, 16GB RAM, **14GB guaranteed SSD**
  (actual disks since 2026-07 are 72–145GB but NOT dependable —
  actions/runner-images#14492). **Free and unlimited on public repos.**
- Larger runners (paid, per-minute, even for public repos): 4-core
  16GB/150GB, 8-core 32GB/300GB, 16-core 64GB/600GB, 32-core 128GB/1200GB.
  The 8-core/300GB is the minimum that fits a LineageOS build.
- Swap: `pierotofy/set-swap-space@master` adds up to ~15GB — required for
  LTO-full kernel links (16GB RAM alone OOMs, same as our laptop).

### Kernel builds on GH Actions — proven pattern

- TNF's own `kernel_msm-5.15` builder (YASK.yml / main.yml): checkout →
  10–15GB swap → clone source → fetch AOSP clang → configure → `build.sh` →
  upload. Our `ci-kernel-matrix.yml` mirrors this with ccache + per-variant
  builds. See the R9-exact workflow below for the toolchain-verified recipe.
- Artifact retention: 90 days default; set `retention-days` explicitly.

### ROM builds — the hard constraint

- `lineageos4microg/docker-lineage-cicd` requirements: **~300GB storage** for
  LOS 18.1+ (source sync + ccache + output), 32GB+ RAM (16GB works but slow),
  Linux + Docker. Env knobs: `BRANCH_NAME`, `DEVICE_LIST`, `RELEASE_TYPE`,
  `CCACHE_SIZE`, `LOCAL_MIRROR` (>200GB), `BUILD_OVERLAY`, `CRONTAB_TIME`.
- GitHub-hosted runners CANNOT reliably hold a LOS tree (14GB guaranteed).
  Options: (a) **self-hosted runner** (free, you supply the machine — the
  recommended path), (b) 8-core larger runner (~300GB, per-minute billed).
- The cloud-build pattern (docker-lineage-cicd wiki): virgin server →
  install Docker → `docker run` with volumes `/srv/src /srv/zips /srv/logs
  /srv/ccache /srv/local_manifests`.

## What's set up in this repo

### `.github/workflows/ci.yml` — certification + quality gates
pytest cert suite, checkpatch, shellcheck/shfmt, verify-brick-safety on
push/PR. Free runner.

### `.github/workflows/ci-kernel-matrix.yml` — variant compile gate
Builds plain/ksu/susfs/bbg/thermal/full variants (the feature-bisection
stages as CI) with ccache + AOSP clang. Catches compile regressions; it
cannot catch device boot hangs (that's `tools/device/bisect-kernel.sh`).

### `.github/workflows/ci-r9-exact.yml` — the decisive bisection build
Builds the pristine zepharo tree at the pinned base with the **official R9
recipe**: AOSP clang **r450784e** (14.0.7, from the android14-release AOSP
archive) + **LTO full** (gki_defconfig default) + **no -march override** +
**no -Wno-error** + 15GB swap. Produces a flashable AnyKernel3 zip
(`apex-kernel-0.4.0-r9-exact-anykernel3.zip` artifact).

Why: our local R9 repro (clang 20 + thin LTO + `-march=armv8.4-a`) does not
boot on the device; the official release does. This build isolates the
recipe variables (see GBrain `apex-device-flash-session-2026-09-08` Rounds
7–9). Flash the artifact in recovery (proven path): boots ⇒ pipeline
validated, then bisect thin-LTO / march-override / clang-20 one at a time;
hangs ⇒ deeper issue.

Trigger: `gh workflow run ci-r9-exact.yml` (or the Actions tab).

### `.github/workflows/rom-build.yml` — full ROM (self-hosted)
`runs-on: [self-hosted, linux, x64, rom-builder]`. Docker-lineage-cicd for
`lineage-23.2` / `topaz`, volumes under `/srv/apex-rom`, APEX local
manifests from `rom-overlays/device/`, uploads zips + logs. Preflight fails
fast if <100GB free.

## Running the ROM build — attach a self-hosted runner

Requirements: x86_64 Linux, **~350GB free** (`/srv/apex-rom`), 32GB+ RAM,
Docker. Attach:

```bash
# on the build machine
mkdir -p /srv/apex-rom && cd /srv/apex-rom
# (repo Settings → Actions → Runners → New self-hosted runner; copy the
#  token, then:)
curl -fsSL https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz | tar xz
./config.sh --url https://github.com/szymonqzx/apex --token <TOKEN> --labels rom-builder
sudo ./svc.sh install && sudo ./svc.sh start
```

Then `gh workflow run rom-build.yml` (dispatch) — first run does the full
~80GB sync + build (hours; the workflow timeout is 600min).

## Version/toolchain notes

- The R9-exact workflow pins clang r450784e because the official ZEPHARO
  release was built with it ("back to clang r450784e for stability" — R9
  changelog). The kernel matrix historically used r547379; align with
  r450784e when updating.
- LTO: gki_defconfig defaults to `CONFIG_LTO_CLANG_FULL=y`; the R9-exact
  workflow keeps that (changelog says releases are LTO full).
