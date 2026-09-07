# APEX ROM Documentation Library

Comprehensive documentation for every system in the APEX ROM and kernel.

## Index

| # | Document | System |
|---|----------|--------|
| 01 | [Architecture](01-architecture.md) | System overview, process map, data flow, component graph |
| 02 | [Kernel](02-kernel.md) | Defconfig, scheduler, hardening, modules, thermal, ZRAM |
| 03 | [Agent Daemon](03-agent.md) | apexagentd, LLM inference, model tiers, JNI, fallback |
| 04 | [Agent Security](04-agent-security.md) | Consent gate, injection detection, sanitization, effect verification |
| 05 | [Agent Memory](05-agent-memory.md) | Vector store, BM25 retrieval, memory manager, debug log |
| 06 | [Agent Remote & Voice](06-agent-remote-voice.md) | Remote proxy, OmniRoute integration, whisper.cpp STT |
| 07 | [MCP Tools](07-mcp-tools.md) | Tool registry, all 15 registered tools, dispatch flow |
| 08 | [Window Manager](08-window-manager.md) | Freeform WM, tiling, TaskOrganizer, framework overlay |
| 09 | [Desktop Mode](09-desktop-mode.md) | scrcpy integration, desktop layout, input bridging |
| 10 | [Lindroid](10-lindroid.md) | Linux container, namespaces, lifecycle scripts |
| 11 | [Chroot Bridge](11-chroot-bridge.md) | apex-bridge daemon, socket protocol, hardware monitoring |
| 12 | [Hiding Stack](12-hiding-stack.md) | SuSFS, Shamiko, HMA-OSS, TrickyStore, PIF, 76-vector audit |
| 13 | [ROM Overlays](13-rom-overlays.md) | init.d scripts, build.prop, thermald, feature flags |
| 14 | [Pentest Drivers](14-pentest.md) | Driver matrix, VID:PID autoload, NFCForge, PTK TUI |
| 15 | [Apps](15-apps.md) | Apex Control, NFCForge, PTK TUI — UI architecture |
| 16 | [KSU Module](16-ksu-module.md) | Module structure, boot flow, scripts, packaging |
| 17 | [SELinux](17-selinux.md) | All domains, policies, neverallow rules, enforcement |
| 18 | [Migration](18-migration.md) | Magisk to KSU-Next migration, cleanup, safety |
| 19 | [Build Pipeline](19-build-pipeline.md) | Build tools, CI, verification, release artifacts |
| 20 | [Update Architecture](20-update-architecture.md) | Virtual A/B, OTA fallback, dirty-flash upgrade |
| 21 | [Testing](21-testing.md) | Test framework, 288 tests, verification scripts |
| 22 | [Design Decisions](22-decisions.md) | Locked-in decisions and rationale for every major choice |
| 23 | [Risk Register](23-risk-register.md) | Risks, mitigations, known hardware walls, honest assessment |

## How to Read

- **New to the project**: Start with 01 (Architecture), then 22 (Decisions) for the "why".
- **Building the kernel**: 02 (Kernel), 19 (Build Pipeline), 16 (KSU Module).
- **Understanding the agent**: 03 through 07, in order.
- **Flashing for the first time**: 18 (Migration), 16 (KSU Module), 19 (Build Pipeline).
- **Security review**: 04 (Agent Security), 17 (SELinux), 12 (Hiding Stack).
- **Contributing**: 21 (Testing), 19 (Build Pipeline).

## Device Target

- **Device**: Redmi Note 12 4G (codename: topaz/tapas)
- **SoC**: Qualcomm Snapdragon 685 (SM6225-AD, bengal)
- **CPU**: 8-core (4x A73 @ 2.8GHz + 4x A53 @ 1.7GHz)
- **RAM**: 4GB/6GB/8GB
- **Storage**: 64GB/128GB UFS 2.2
- **Kernel base**: CAF/CLO bengal-5.15 (Linux 5.15.211)
- **ROM base**: LineageOS 23.2 (Android 16 / SDK 36)
- **Root**: KernelSU-Next + SuSFS v1.5+

## License

SPDX-License-Identifier: GPL-2.0-only for kernel components.
Application code is personal-use only, not for redistribution.
