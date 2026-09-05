# APEX Agent Module

On-device LLM agent for the APEX ROM. Hybrid architecture: daemon primary,
system_server fallback.

## Architecture

```
Apex Control (Compose) ──IApexAgent AIDL──► system_server
  ├─ chat surface                         ├─ McpRegistry (read-only snapshot
  ├─ model router UI                      │  binder service; daemon subscribes)
  ├─ audit log viewer                     ├─ ConsentGate (60s timeout → auto-deny)
  └─ Consent/audit fallback (no LLM)      └─ model download manager
                                          │
                    ┌─────▼─────┐
                    │ apexagentd│  ← PRIMARY (native daemon)
                    │ llama.cpp │  ← Qwen 1.5B default / 3B opt-in
                    │ whisper   │  ← voice (T6)
                    │ MCP dispatcher│
                    │ vector mem│  ← T7
                    └─────┬─────┘
                          │
                    MCP tool calls (consent-gated)
                    apex-charge, apex-tune, apex-chroot
                    (agent is READ-ONLY over hardware)
```

## Components

### system_server (survives daemon crash)

| Component | File | Description |
|-----------|------|-------------|
| LlmManagerService | `java/.../LlmManagerService.java` | Binder service, model registry, dispatch |
| McpRegistry | `java/.../McpRegistry.java` | Read-only tool snapshot (contacts, charge, tune, chroot) |
| ConsentGate | `java/.../ConsentGate.java` | Consent state machine: PENDING → APPROVED/DENIED/TIMEOUT |
| HitlConsentStore | `java/.../HitlConsentStore.java` | Append-only SQLite audit log |

### apexagentd (killable under OOM)

| Component | File | Description |
|-----------|------|-------------|
| ApexAgentDaemon | `java/.../ApexAgentDaemon.java` | Socket server, model loading, inference dispatch |

### AIDL interfaces

| Interface | File |
|-----------|------|
| IApexAgent | `aidl/.../IApexAgent.aidl` |
| IApexToolCallback | `aidl/.../IApexToolCallback.aidl` |
| ApexAgentStatus | `aidl/.../ApexAgentStatus.aidl` |

### SELinux

| File | Description |
|------|-------------|
| `sepolicy/apex_agent.te` | Domain policy: binder, socket, sysfs read, no network, no boot writes |

## Key Design Decisions

1. **Hybrid process model** — daemon is primary, system_server hosts registry/consent only.
   A daemon crash does NOT take down system_server (process isolation).
2. **Consent gate** — every MCP tool call is human-approved, 60s timeout → auto-deny + audit.
3. **Read-only hardware** — agent can read sysfs/procfs but never write to hardware controls.
4. **No network** — SELinux neverallow on tcp/udp sockets. All inference is on-device.
5. **OOM killable** — daemon has oom_score_adj=900, LMKD can reclaim it.

## Build

```bash
# In AOSP/LineageOS source tree:
lunch lineage_topaz-userdebug
m apex-agent-service apexagentd libllm_jni
```

## Porting from AAOSP

This module is adapted from [AAOSP](https://github.com/rufolangus/AAOSP)
(A15-locked). The following were ported to Android 16:

- LlmManagerService → adapted to A16 system_server, hybrid daemon model
- McpRegistry → simplified to read-only snapshot, binder-based
- ConsentGate → 60s timeout, auto-deny, audit log
- HitlConsentStore → SQLite, append-only, SELinux-protected path

Changes from AAOSP:
- Process isolation: daemon separate from system_server (AAOSP ran in-process)
- No GPU inference (Adreno 610 limitation)
- CPU-only llama.cpp with ARM-optimized build
- MCP tools limited to read-only hardware access
