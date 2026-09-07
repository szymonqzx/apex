# 22 — Design Decisions

## Overview

This document records every locked-in design decision for APEX ROM, with rationale. These decisions were made during the design phase and are considered final — changing them requires a deliberate design review, not a casual modification.

## D1: Dirty-Flash Only

**Decision**: The ROM is applied as a dirty flash on top of an existing LineageOS install. No clean flash, no data wipe.

**Rationale**:
- The user has a personal device with data they don't want to lose
- Clean flashing requires re-setup of all apps, accounts, and settings
- KSU module overlays are inherently dirty-flash (they overlay `/system` without modifying the partition)
- The kernel flashes to boot partition only — no partition formatting

**Implications**:
- No OTA system (manual updates only)
- No factory reset support (would remove KSU module)
- System partition must remain close to stock LineageOS

## D2: KernelSU-Next + SuSFS (Not Magisk)

**Decision**: Use KernelSU-Next with SuSFS for root and hiding, not Magisk.

**Rationale**:
- Kernel-level root is harder to detect than userspace root (Magisk)
- SuSFS provides compile-time hiding (25 vectors closed at kernel level)
- KernelSU-Next is actively maintained for modern kernels (5.15+)
- Magisk's Zygisk is userspace and easier to detect
- Clean break from Magisk ecosystem — no residual artifacts

**Implications**:
- Migration script needed for existing Magisk users
- KernelSU-Next kernel patches must be maintained
- SuSFS must be compiled into the kernel (not a module)

## D3: Strictly Enforcing SELinux

**Decision**: No permissive domains. Every APEX component has its own enforcing SELinux domain.

**Rationale**:
- Permissive domains are a security hole — they log but don't enforce
- Banking apps and Play Integrity check SELinux enforcement state
- Per-domain isolation limits blast radius of compromises
- The neverallow rules (no network for inference daemon, no block device writes) are critical safety nets

**Implications**:
- Every new component needs its own SELinux policy
- Debugging is harder (denials are enforced, not just logged)
- Some operations that would be easy with permissive mode require explicit allow rules

## D4: Process Isolation for Inference

**Decision**: apexagentd runs in its own process with its own SELinux domain. A llama.cpp crash must never take down system_server.

**Rationale**:
- llama.cpp is complex C/C++ code that can segfault
- system_server crashing reboots the device
- Process isolation is the only reliable crash containment
- OOM killer can reclaim the daemon without affecting the framework

**Implications**:
- Binder communication needed between system_server and daemon
- Local socket for chat request dispatch
- DeathRecipient for crash detection and fallback

## D5: No Network for Inference Daemon

**Decision**: apexagentd has a SELinux neverallow on all network sockets. Remote inference goes through a separate proxy process.

**Rationale**:
- The inference daemon processes user data (chat messages, contacts, memory)
- A compromised daemon should not be able to exfiltrate data
- The proxy process only forwards inference requests — it never sees user data beyond the prompt
- Consent for remote inference explicitly warns "data leaves device"

**Implications**:
- Two processes needed for remote inference
- Proxy has its own SELinux domain with network access
- Additional latency for remote inference (daemon → proxy → network)

## D6: Consent for Every Write

**Decision**: Every MCP tool that modifies system state requires explicit human consent with a 60s timeout.

**Rationale**:
- The agent can execute tools autonomously — without consent, it could make unwanted changes
- 60s timeout auto-denies — safer to do nothing than approve something you didn't read
- The consent card shows tool name, args, and plain-language description for verification
- Anti-phishing affordances prevent tricking the user into approving malicious actions

**Implications**:
- Some operations are slower (wait for user approval)
- The agent cannot operate fully autonomously for write operations
- The consent UX must be clear and non-bypassable

## D7: Dual-Confirmation for Charge Control

**Decision**: Charge control writes require on-screen approval PLUS physical volume key press within 5 seconds.

**Rationale**:
- Charge control directly affects battery health and safety
- A single tap could be accidental or triggered by a phishing attempt
- Physical button press requires deliberate action — much harder to spoof
- 5-second window prevents indefinite waiting

**Implications**:
- Charge control changes take longer (two-step approval)
- Volume key event listener needed in Apex Control
- If user can't press volume key (accessibility), they can't change charge limit via agent

## D8: Append-Only Audit Log

**Decision**: The consent audit log is append-only — no delete, no update operations.

**Rationale**:
- The audit log is the trust foundation — if it can be modified, it's worthless
- Append-only ensures the full history is always available for review
- SQLite supports this via application-level enforcement (no delete/update methods exposed)
- SELinux protects the database file (only system_server can read/write)

**Implications**:
- Log grows indefinitely (mitigated by query limits — 500 max entries per query)
- No "correcting" mistaken entries (the audit records what happened, not what should have happened)

## D9: BM25 for Memory Retrieval (Not Embeddings)

**Decision**: AgentVectorStore uses BM25 text retrieval via SQLite FTS5, not neural embeddings.

**Rationale**:
- No external embedding model needed — BM25 is built into SQLite FTS5
- CPU-only, no GPU required
- Lower memory footprint than embedding models
- Fast enough for on-device use (<10ms per query)
- Good enough for semantic-ish retrieval on short text (memories are typically 1-2 sentences)

**Implications**:
- Retrieval is less semantically aware than embedding-based search
- "I like dark mode" and "I prefer dark themes" would not match well
- AgentMemoryStore (separate class) uses embeddings for richer retrieval, but is heavier

## D10: ZSTD for ZRAM

**Decision**: Use zstd compression for ZRAM, not lz4 or lzo.

**Rationale**:
- zstd has the best compression ratio of the available options
- On a 4-8GB RAM device, maximizing effective memory is critical
- zstd decompression is fast enough for ZRAM use case
- CachyOS kernel has well-optimized zstd support

**Implications**:
- Slightly higher CPU usage during compression compared to lz4
- Better effective memory expansion (2-3x vs 1.5-2x for lz4)

## D11: SchedHorizon Governor (Not SchedUtil)

**Decision**: Use the SchedHorizon CPU frequency governor, not the default SchedUtil.

**Rationale**:
- SchedHorizon is a Bandido-class governor with better EAS awareness
- Provides per-cluster frequency control (A73 and A53 independently)
- Screen-off ramp-down for power saving
- Better gaming performance with game mode integration

**Implications**:
- Custom governor must be maintained in the kernel
- Less tested than SchedUtil on this hardware
- Tuning parameters exposed in Apex Control for user adjustment

## D12: No Userspace Thermald

**Decision**: All thermal policy is enforced in-kernel. No userspace thermald daemon.

**Rationale**:
- Kernel thermal policy has lower latency (microseconds vs milliseconds)
- More granular control (per-CPU frequency, per-charger current)
- The original `mi_thermald` is a black box with unpredictable behavior
- Kernel modules can read temperature directly from power_supply class

**Implications**:
- `thermald.conf` is reference documentation only
- Thermal tuning requires kernel changes, not userspace config
- Less flexibility for runtime adjustment (must rebuild kernel to change trip points)

## D13: Arch Linux ARM for Chroot/Container

**Decision**: Use Arch Linux ARM as the Linux distribution for the chroot/Lindroid container.

**Rationale**:
- Rolling release — always latest packages
- pacman is fast and simple
- AUR has pentest tools (aircrack-ng, nmap, hydra, etc.)
- User is already familiar with Arch (CachyOS desktop)
- Small base install (~500MB)

**Implications**:
- Container needs network access for pacman updates
- Rolling release means potential breakage on update
- No LTS guarantees for packages

## D14: scrcpy for Desktop Mode (Not DisplayPort Alt Mode)

**Decision**: Use scrcpy for desktop display output, not USB-C DisplayPort alt mode.

**Rationale**:
- topaz USB-C is USB 2.0 only — no DisplayPort alt mode support
- scrcpy works over USB ADB or TCP (network)
- scrcpy is actively maintained, well-tested, and low-latency
- No kernel changes needed for scrcpy (uses existing ADB infrastructure)

**Implications**:
- Requires scrcpy client on PC (not built into OS)
- USB 2.0 limits bandwidth (8Mbps video is acceptable but not great)
- No audio over USB (scrcpy handles audio separately)
