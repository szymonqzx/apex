# 15 — Apps

## Overview

APEX ROM includes three Android apps, all built with Kotlin and Jetpack Compose:

1. **Apex Control** — primary cockpit app (privileged system app)
2. **NFCForge** — NFC card operations (regular system app)
3. **PTK TUI** — pentest terminal (regular system app)

## Apex Control

### Purpose
The primary user interface for the APEX ROM. Provides agent chat, model management, power-user controls, and system status.

### App Type
Privileged system app (`/system/priv-app/ApexControl/`). Has access to system APIs and binder services that regular apps cannot access.

### Source Files (22 Kotlin files, ~3,500 lines)

```
apps/apex-control/app/src/main/java/com/apex/control/
├── MainActivity.kt                          # Single-activity host
├── data/
│   └── BridgeClient.kt                      # Socket client to apex-bridge
├── domain/
│   ├── ApexRepository.kt                    # Data repository
│   └── ApexState.kt                         # State models
├── agent/
│   ├── AgentViewModel.kt                    # Chat + consent UI state
│   ├── AgentRepository.kt                   # Agent binder client
│   ├── AuditLogEntry.kt                     # Audit log data model
│   ├── AuditLogViewer.kt                    # Audit log display
│   ├── ChatState.kt                         # Chat state machine
│   ├── ChatMessage.kt                       # Message data model
│   ├── ConsentRequest.kt                    # Consent request model
│   ├── ModelDownloadManager.kt              # GGUF model downloader
│   ├── ModelInfo.kt                         # Model metadata
│   └── ModelRouterScreen.kt                 # Model tier selection UI
├── poweruser/
│   ├── PowerUserScreen.kt                   # Power-user dashboard
│   ├── PowerUserRepository.kt               # Power-user data client
│   ├── PowerUserState.kt                    # Power-user state models
│   ├── GovernorTuningScreen.kt              # CPU governor tuning
│   ├── ThermalProfileScreen.kt              # Thermal profile viewer
│   ├── BridgeStatusScreen.kt                # Chroot bridge status
│   ├── ModuleStatusScreen.kt                # KSU module status
│   └── IncidentLogViewer.kt                 # Incident log display
└── ui/
    ├── ApexControlScreen.kt                 # Main navigation host
    └── TrustBadge.kt                        # Trust/integrity badge
```

### Screens

#### Agent Chat (AgentViewModel + AgentChatSurface)
- Chat interface with the on-device LLM
- Displays consent cards when the agent requests tool execution
- Shows countdown timer (60s for standard, 30s for remote)
- Warning badge for suspicious content (PromptInjectionDetector)
- Equal-weight Approve/Deny buttons (anti-phishing)
- Tool name and args in monospace font

#### Model Router (ModelRouterScreen)
- Select model tier: Fallback (0.5B), Default (1.5B), High (3B), Remote
- Download GGUF model files
- View model metadata (size, RAM, throughput)
- Configure remote endpoint (OmniRoute URL)

#### Power User Dashboard (PowerUserScreen)
- Hub for all power-user features
- Links to sub-screens: governor tuning, thermal profile, bridge status, module status, incident log

#### Governor Tuning (GovernorTuningScreen)
- Adjust CPU governor parameters
- Set per-cluster min/max frequencies
- Configure A73 and A53 cluster independently
- Read/write to `/sys/class/apex/` and `/proc/apex/`

#### Thermal Profile (ThermalProfileScreen)
- View current thermal trip points
- View 7-day thermal learner data (when implemented)
- Adjust thermal thresholds (advanced)

#### Bridge Status (BridgeStatusScreen)
- View apex-bridge daemon status
- Display current kernel policy state
- Show hardware monitoring data (display, charging, battery, thermal)

#### Module Status (ModuleStatusScreen)
- View installed KSU modules
- Check hiding stack status (Shamiko, HMA, TrickyStore, Yurikey)
- Run Play Integrity check
- Configure denylist

#### Incident Log (IncidentLogViewer)
- View `/persist/apex/incidents.log`
- Shows crash history, watchdog events, safe-mode triggers
- Filter by incident type and date

#### Audit Log (AuditLogViewer)
- View consent audit trail
- Shows every tool call: timestamp, tool name, description, result, duration
- Filter by tool name

#### Trust Badge (TrustBadge)
- Displays Play Integrity status (DEVICE/STRONG)
- Shows SELinux enforcement state
- Displays kernel version and APEX version

## NFCForge

### App Type
Regular system app (`/system/app/NFCForge/`).

### Source Files (8 files, ~1,200 lines)
See [14-pentest.md](14-pentest.md) for details.

## PTK TUI

### App Type
Regular system app (`/system/app/PTKTUI/`).

### Source Files (6 files, ~900 lines)
See [14-pentest.md](14-pentest.md) for details.

## Build System

- **Gradle**: 9.7
- **Kotlin**: 2.0.21
- **Compose**: 1.7
- **compileSdk**: 36 (Android 16)
- **Target SDK**: 36
- **Min SDK**: 33 (Android 13)

### Hidden API Stubs
Some APEX system services use hidden Android APIs not exposed in the public SDK. A stubs JAR at `build/stubs/apex-hidden-api-stubs.jar` (3.3KB) provides compile-time stubs for:
- `ServiceManager` — for registering binder services
- `TaskOrganizer` — for window management
- Other hidden framework classes

The stubs are only for compilation — at runtime, the real framework classes are used.

## APK Sizes

| App | APK Size | Notes |
|-----|----------|-------|
| ApexControl | 39MB | Includes Compose UI + all screens |
| ApexSystemServices | 128KB | Minimal — just services, no UI |
| NFCForge | 18MB | Compose UI + NFC operations |
| PTK TUI | 18MB | Compose UI + terminal emulator |
