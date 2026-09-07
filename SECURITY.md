# Security Policy

APEX is a personal, security-oriented kernel + ROM project for the Redmi Note
12 4G (topaz/tapas). We take security reports seriously.

## Scope

In scope:

- Kernel vulnerabilities in APEX-patched code paths (APEX sysfs, charge
  limiting, SUSFS glue, Baseband-guard LSM, thermal learner).
- Boot/rootkit/hiding-stack bypasses that defeat the project's stated goals.
- Anti-brick / partition-write protections (`verify-brick-safety.sh`).

Out of scope:

- Upstream Linux 5.15 / CAF msm-5.15 vulnerabilities — report those to the
  upstream projects.
- Play Integrity / attestation evasion that does not involve a code defect
  in this repository.

## Reporting

This is a personal project — report privately to the maintainer:

- GitHub: open a **private advisory** via the repo's Security tab
  (https://github.com/szymonqzx/apex/security/advisories/new), or
- Email the maintainer (see GitHub profile) with the subject
  `[APEX security] <short description>`.

Please include: affected version (`/sys/class/apex/version` or git commit),
a minimal reproduction, impact, and any suggested fix. No automated scanners
or spam, please.

## Disclosure

The project is GPL-2.0 — fixes are expected to be contributed back as patches
in `patches/apex-new/`. We aim to acknowledge reports within 7 days and
publish a fix with the next release. Coordinated disclosure is appreciated
for issues affecting other devices/ROMs.

## Hardened baseline

The kernel enables CFI, KASLR, Shadow Call Stack, SLAB freelist hardening,
lockdown LSM, MGLRU, and disables unprivileged BPF and userfaultfd (see
`defconfig/apex_defconfig`). Report regressions that weaken these as security
issues, not just bugs.
