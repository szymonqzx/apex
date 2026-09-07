# 01 — Architecture

## Overview

APEX is a custom hardened Android ROM and kernel for the Redmi Note 12 4G (topaz/tapas, Snapdragon 685). It combines a performance-tuned Linux 5.15 kernel, an on-device AI agent, a Linux container runtime, pentest tooling, and a comprehensive root-hiding stack — all delivered as a dirty-flash overlay on top of LineageOS 23.2.

The system is not a traditional ROM build. It is a **layered overlay architecture**: the APEX kernel flashes to the boot partition via AnyKernel3, and all ROM modifications are applied as a KernelSU-Next module that overlays files onto `/system` without modifying the system partition directly. This means the ROM can be installed, updated, and removed without touching any partition except `boot`.

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER LAYER                                │
│  Apex Control (Compose UI)  │  NFCForge  │  PTK TUI             │
├─────────────────────────────────────────────────────────────────┤
│                     FRAMEWORK LAYER                              │
│  LlmManagerService  │  McpRegistry  │  ConsentGate              │
│  ApexWindowManager  │  DesktopModeService  │  LindroidManager   │
│  (system_server)    │  (system_server)     │  (system_server)   │
├─────────────────────────────────────────────────────────────────┤
│                      DAEMON LAYER                                │
│  apexagentd         │  apex_remote_proxy  │  apex-bridge         │
│  (own process)      │  (own process)      │  (own process)      │
│  SELinux: apex_agent│  SELinux: apex_remote│  SELinux: apex_chroot│
├─────────────────────────────────────────────────────────────────┤
│                    KERNEL LAYER                                  │
│  APEX sysfs  │  KernelSU-Next  │  SuSFS  │  SchedHorizon        │
│  ZRAM (zstd) │  PREEMPT        │  EAS    │  PSI                 │
│  239 modules │  Module signing │  KASLR  │  STRICT_KERNEL_RWX   │
├─────────────────────────────────────────────────────────────────┤
│                    HARDWARE LAYER                                │
│  SM6225-AD  │  PMIC (STPMIC1)  │  NFC (ST21NFC)  │  Sensors     │
│  A73+A53    │  Charger (PM7250B)│  Wi-Fi (WCN3990)│  Display    │
└─────────────────────────────────────────────────────────────────┘
```

## Process Map

### system_server (PID ~1000, SELinux: system_server)
The Android framework process. Hosts all APEX system services:
- **LlmManagerService** — Binder service `apex.agent`. Manages model registry, dispatches inference to apexagentd via local socket. Survives daemon crashes.
- **McpRegistry** — Read-only snapshot of 15 registered MCP tools. The daemon queries this via binder to know what tools exist.
- **ConsentGate** — State machine for human-in-the-loop consent. PENDING → APPROVED | DENIED | TIMEOUT. 60s default timeout, 30s for remote inference.
- **HitlConsentStore** — Append-only SQLite audit log at `/data/system/apex/consent_audit.db`. Every consent event is recorded with timestamp, tool, description, action, result, and duration.
- **ApexWindowManager** — Binder service `apex_wm`. Manages freeform windows via TaskOrganizer.
- **DesktopModeService** — Binder service `apex_desktop`. Launches scrcpy-server via app_process.
- **LindroidManager** — Binder service `apex_lindroid`. Manages Arch Linux ARM container lifecycle.

### apexagentd (own process, SELinux: apex_agent)
The primary inference engine. Connects to system_server via binder, receives chat requests via local socket `/dev/socket/apex-agent`, loads llama.cpp models via JNI, generates responses. If a response contains a tool call, routes through ConsentGate via binder callback. Killable under OOM (oom_score_adj = 900). On crash, system_server detects via binder death and enters fallback mode.

### apex_remote_proxy (own process, SELinux: apex_remote_proxy)
Standalone daemon for remote model inference. Listens on localhost:9879. Forwards chat completion requests to the configured OmniRoute endpoint. Runs in a separate SELinux domain with network access — apexagentd itself has no network access (neverallow rule).

### apex-bridge (own process, SELinux: apex_chroot)
Userspace daemon bridging Android framework to kernel apex state machine. Listens on `/dev/socket/apex-bridge`. Monitors display state, charging, battery, thermal zones. Writes policy commands to `/sys/class/apex/policy`.

## Data Flow: Chat Request

```
User types in Apex Control
  → AgentViewModel.kt calls IApexAgent.chat(prompt) via binder
    → LlmManagerService receives request in system_server
      → Dispatches to apexagentd via local socket /dev/socket/apex-agent
        → ApexAgentDaemon reads prompt
          → MemoryManager.getRelevantContext(prompt) retrieves top-5 memories
          → Prompt = system_prompt + memories + user_prompt
          → ModelManager loads appropriate tier (0.5B/1.5B/3B GGUF)
          → JNI call: nativeGenerate(modelHandle, prompt, maxTokens, temp)
            → llama.cpp inference on A73 cluster (4 threads)
          → LLM output parsed for tool-call JSON
          → If tool call found:
            → PromptInjectionDetector.analyze(output, toolName, toolArgs)
              → RISK_INJECTION: BLOCK, audit
              → RISK_SUSPICIOUS: warn + proceed to consent
              → RISK_CLEAN: proceed to consent
            → ConsentGate.requestConsent(toolName, desc, action)
              → IApexToolCallback.onToolConsentRequested() → Apex Control UI
              → User approves/denies, 60s timeout auto-denies
            → If approved:
              → McpRegistry dispatches tool
              → ToolEffectVerifier verifies sysfs write took effect
              → HitlConsentStore logs result
            → Tool result fed back to LLM for follow-up
          → Final response text returned through socket → binder → UI
```

## Data Flow: Remote Inference

```
User requests remote model in Apex Control
  → AgentViewModel sets model tier to "remote-omniroute"
  → LlmManagerService dispatches to apexagentd
    → apexagentd detects remote tier
    → Connects to apex_remote_proxy on localhost:9879
      → RemoteProxyDaemon receives JSON request
      → RemoteModelClient.chat() sends HTTP POST to OmniRoute endpoint
        → http://127.0.0.1:20128/v1/chat/completions
        → OpenAI-compatible request body
      → Response text returned through proxy → daemon → binder → UI
  → Consent type: REMOTE_INFERENCE (30s timeout, warns "data leaves device")
```

## Data Flow: Kernel Policy

```
Boot
  → post-fs-data.sh: kernel detection, create /data/adb/apex, socket perms
  → service.sh: apply build.prop overlays (idempotent), hidden packages, health monitor

Runtime
  → apex-bridge monitors display/charge/battery/thermal
  → Writes to /sys/class/apex/policy: screen_on, screen_off, game 0|1, charge 0|1, audio 0|1
  → Kernel apex state machine processes policy → adjusts governor, frequencies, thermal
  → /proc/apex/* (0444): state, version, governor, watchdog, health, thermal_profile

Power Events
  → Screen off → kernel reduces A73 max freq, enables EAS energy model
  → Game mode → A73 unlocked, sensor block, notification DND
  → Charging → JEITA thermal mitigation via apex_charge driver
  → Thermal warn (45°C) → throttle A73 to 70%
  → Thermal critical (65°C) → throttle all clusters to 50%
```

## Component Inventory

| Component | Files | Lines | Language |
|-----------|-------|-------|----------|
| Agent spine (system-services) | 35 | ~5,200 | Java + AIDL |
| Agent daemon (agent/) | 24 | ~4,100 | Java + C |
| Apex Control app | 22 | ~3,500 | Kotlin |
| NFCForge app | 8 | ~1,200 | Kotlin |
| PTK TUI app | 6 | ~900 | Kotlin |
| Chroot bridge | 1 | 980 | C |
| Window Manager | 8 | ~530 | Java + AIDL |
| Desktop Mode | 3 | ~220 | Java + AIDL |
| Lindroid | 10 | ~700 | Java + Shell |
| KernelSU-Next + SuSFS | 81 | ~12,000 | C |
| Kernel patches (apex-new) | ~20 | ~2,000 | C + Shell |
| ROM overlays | 22 | ~1,500 | Shell + RC |
| Hiding stack | 3 | ~200 | Shell |
| Migration | 2 | ~200 | Shell |
| Build tools | 12 | ~2,000 | Shell |
| Verify tools | 5 | ~1,200 | Shell |
| Tests | 16 | ~3,000 | Python |
| **Total** | ~280 | ~38,000 | 6 languages |

## Directory Layout

```
apex/
├── agent/              # Agent daemon: Java sources, AIDL, JNI bridges, LLM/voice
├── anykernel3/         # AnyKernel3 flasher template (kernel zip)
├── apps/               # Android apps: apex-control, nfcforge, ptk-tui
├── build/              # Build artifacts (stubs JAR)
├── chroot/             # Chroot bridge daemon (apex-bridge.c)
├── defconfig/          # Kernel defconfig + documentation
├── desktop/            # Desktop Mode service (scrcpy integration)
├── docs/               # All documentation (DESIGN.md, plan docs, this library)
├── drivers/            # Out-of-tree kernel drivers (apex_charge)
├── hiding/             # Hiding stack configuration scripts
├── kernel/             # Kernel source (gitignored, vendored where needed)
├── ksu-module/         # KernelSU-Next module (system overlays)
├── lindroid/           # Lindroid container manager
├── migration/          # Magisk → KSU-Next migration script
├── out/                # Kernel build output (Image, modules)
├── patches/            # Kernel patches (apex-new: KernelSU, SuSFS, sysfs, etc.)
├── releases/           # Flashable ZIPs
├── rom-overlays/       # ROM overlay files (init.d, bin, update)
├── schemas/            # JSON schemas (capability profile, evidence bundle)
├── system-services/    # System app: all framework services + AIDL
├── tests/              # Python test suite (288 tests)
├── tools/              # Build, package, verify, release scripts
└── wm/                 # APEX Window Manager
```

## Key Design Principles

1. **Dirty-flash only** — never clean flash. The ROM overlays onto an existing LineageOS install. No data wipe, no partition formatting.
2. **Process isolation** — apexagentd runs in its own process with its own SELinux domain. A llama.cpp crash must never take down system_server.
3. **No network for inference daemon** — apexagentd has a SELinux neverallow on all network sockets. Remote inference goes through a separate proxy process.
4. **Consent for every write** — every MCP tool that modifies system state requires explicit human consent with a 60s timeout.
5. **Append-only audit** — the consent audit log is append-only. No delete, no update. Every tool call is recorded with before/after values.
6. **Strictly enforcing SELinux** — no permissive domains. Every APEX component has its own SELinux domain with minimal permissions.
7. **Brick safety** — no tool, script, or overlay may touch bootloader, aboot, TZ, modem, or any boot-critical partition. The verify suite enforces this.
8. **On-device first** — all inference, memory, and voice processing happens on-device. Remote inference is opt-in per request with explicit consent.
