# 03 — Agent Daemon

## Overview

The APEX agent is an on-device AI assistant running inside the Android framework. It uses llama.cpp for local inference with Qwen 2.5 models, supports remote inference via OmniRoute, and can execute MCP tools with human-in-the-loop consent. The architecture is split across two processes for crash isolation.

## Process Architecture

### system_server side (survives daemon crashes)
- **LlmManagerService** (351 lines) — Binder service `apex.agent`. Manages model registry, dispatches to daemon via local socket, handles tool callbacks, tracks daemon liveness via `DeathRecipient`.
- **McpRegistry** (385 lines) — Read-only snapshot of 15 registered MCP tools. The daemon queries this via binder.
- **ConsentGate** (298 lines) — Consent state machine. PENDING → APPROVED | DENIED | TIMEOUT.
- **HitlConsentStore** (178 lines) — Append-only SQLite audit log.

### apexagentd side (killable, own process)
- **ApexAgentDaemon** (333 lines) — Main daemon. Connects to system_server, loads models via JNI, processes chat requests, dispatches tools.
- **ModelManager** (420 lines) — Model lifecycle: loading, unloading, tier switching, memory-pressure-aware degradation.
- **MemoryManager** (158 lines) — High-level memory operations wrapping AgentVectorStore.
- **AgentVectorStore** (293 lines) — SQLite + FTS5 persistent memory with BM25 retrieval.
- **AgentDebugLog** (170 lines) — Structured debug log with rotation.

## Model Tiers

| Tier | Model | Size (Q4_K_M) | RAM | Throughput | Use Case |
|------|-------|---------------|-----|------------|----------|
| Fallback | Qwen 2.5 0.5B | ~500MB | 600MB | 15-20 tok/s | Memory pressure, cold start |
| Default | Qwen 2.5 1.5B | ~1.1GB | 1.5GB | 5-10 tok/s | Normal operation |
| High | Qwen 2.5 3B | ~2.2GB | 3.3GB | 3-5 tok/s | Complex reasoning |
| Remote | OmniRoute | 0 (network) | 0 | network-dependent | Heavy tasks, opt-in |

Models are stored as GGUF files at `/data/local/tmp/models/`. The daemon loads one model at a time — switching tiers unloads the current model first.

### Thread Allocation
- **Inference threads**: 4 (A73 cluster, 2.0GHz+)
- **Whisper STT**: 2 A73 cores (1-3s for short phrase)
- **Wake-word VAD**: 1 A53 core (~2-3% CPU)
- **Idle**: 0% (AudioRecord stopped, model unloaded if memory pressure)

## JNI Bridge

### libllm_jni.so (327 lines C)
Native bridge to llama.cpp:
- `nativeLoadModel(path, nThreads)` → returns model handle
- `nativeGenerate(modelHandle, prompt, maxTokens, temperature)` → returns generated text
- `nativeUnloadModel(modelHandle)` → frees model resources
- `nativeGetMemoryUsage(modelHandle)` → returns RSS in bytes
- `nativeSetThreadCount(modelHandle, nThreads)` → adjusts thread count at runtime

If `libllm_jni.so` is not available, the daemon runs in **stub mode** — returns canned responses, no real inference. This allows the framework to boot even when native libraries are missing.

### libwhisper_jni.so (173 lines C)
Native bridge to whisper.cpp for speech-to-text:
- `nativeLoadWhisperModel(path)` → loads `ggml-tiny.en.bin` (~75MB)
- `nativeTranscribe(handle, audioData)` → returns transcript text
- `nativeStartWakeWord(ringBufferSize)` → starts VAD + keyword spotting
- `nativeStopWakeWord()` → stops wake-word detection

## Chat Request Flow

```
1. Apex Control calls IApexAgent.chat(prompt) via binder
2. LlmManagerService dispatches to apexagentd via /dev/socket/apex-agent
3. ApexAgentDaemon receives prompt:
   a. MemoryManager.getRelevantContext(prompt) → top-5 memories (BM25)
   b. MemoryManager.getPreferences() → user preferences
   c. Full prompt = system_prompt + preferences + memories + user_prompt
   d. ModelManager.loadTier(currentTier) → loads GGUF if not already loaded
   e. JNI: nativeGenerate(handle, fullPrompt, maxTokens, temp)
   f. Parse LLM output for tool-call JSON
   g. If tool call found → security pipeline (see 04-agent-security.md)
   h. Final response text → socket → binder → UI
4. LlmManagerService returns response to Apex Control
```

## Fallback Mode

When apexagentd crashes (detected via `IBinder.DeathRecipient`):
1. `mDaemonAlive = false`, `mFallbackMode = true`
2. All binder calls return a plain-text error: "Agent daemon unavailable. Please restart."
3. ConsentGate, McpRegistry, and HitlConsentStore remain operational (they live in system_server)
4. The health check script (`apex_agent_healthcheck.sh`) detects the crash and restarts the daemon
5. Circuit breaker: max 5 restarts per 10-minute window. If exceeded, daemon stays down and logs an incident.

## Model Download

Model files are not bundled in the ROM — they're too large (500MB-2.2GB each). The `ModelDownloadManager.kt` in Apex Control handles downloading GGUF files from a configurable URL. The user can download models from the Model Router screen.

## OOM Handling

- `oom_score_adj = 900` — apexagentd is the first process killed under memory pressure
- LMKD (Low Memory Killer Daemon) can reclaim the daemon without taking down system_server
- On OOM kill, the health check script restarts the daemon
- Model is automatically unloaded if memory pressure is detected by ModelManager

## Socket Protocol

### /dev/socket/apex-agent (apexagentd ↔ system_server)
Newline-delimited JSON:
```
Request:  {"prompt":"...","maxTokens":512,"temperature":0.7,"model":"qwen2.5-1.5b"}
Response: {"ok":true,"text":"...","toolCalls":[...]}  |  {"ok":false,"error":"..."}
```

### /dev/socket/apex-bridge (apex-bridge ↔ clients)
Newline-terminated text commands:
```
"screen_on"     → write screen_on to /sys/class/apex/policy
"screen_off"    → write screen_off to /sys/class/apex/policy
"game 0|1"      → write game N to /sys/class/apex/policy
"charge 0|1"    → write charge N to /sys/class/apex/policy
"audio 0|1"     → write audio N to /sys/class/apex/policy
"status"        → read /sys/class/apex/state
"version"       → read /sys/class/apex/version
"governor"      → read /sys/class/apex/governor
"watchdog"      → read /sys/class/apex/watchdog
"health"        → read /sys/class/apex/health
```

## AIDL Interfaces

### IApexAgent.aidl (76 lines)
```java
interface IApexAgent {
    String chat(String prompt);
    String chatWithModel(String prompt, String modelId);
    void setModelTier(String tier);
    String getModelTier();
    List<String> listAvailableModels();
    ApexAgentStatus getStatus();
    String getAuditLog(int limit);
    void registerToolCallback(IApexToolCallback cb);
    void unregisterToolCallback(IApexToolCallback cb);
}
```

### IApexToolCallback.aidl (36 lines)
```java
interface IApexToolCallback {
    oneway void onToolConsentRequested(String toolName, String description, String proposedAction);
    boolean isDaemonAlive();
}
```

### ApexAgentStatus.aidl (14 lines)
Parcelable containing: daemonState, currentModel, tier, tokensPerSecond, fallbackMode, uptime.

## Boot Sequence

```
init → apex_agent.rc:
  service apexagentd /system/bin/app_process / com.apex.agent.ApexAgentDaemon
    class core
    user system
    group system
    seclabel u:r:apex_agent:s0
    oom_score_adj 900
    onrestart restart apex_remote_proxy
```

The daemon starts as a core service (before boot_completed). It retries connecting to system_server every 5 seconds if the binder service isn't registered yet.
