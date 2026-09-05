# APEX Agent Memory & Latency Budget

## Device Constraints

- **SoC**: SM6225-AD (Snapdragon 685)
- **CPU**: 4× Cortex-A73 @ 2.2 GHz + 4× Cortex-A53 @ 1.7 GHz
- **RAM**: 8 GB total (system uses ~3-4 GB, agent budget ~2 GB)
- **GPU**: Adreno 610 — **NO GPU inference** (OpenGL ES 3.2 only, no Vulkan 1.1)
- **Storage**: 128 GB UFS 2.2

## Memory Budget

| Component | RAM (default 1.5B) | RAM (opt-in 3B) | RAM (fallback 0.5B) |
|-----------|--------------------|-----------------|---------------------|
| Model weights (Q4_K_M) | ~1.1 GB | ~2.2 GB | ~0.5 GB |
| KV cache (2048 ctx) | ~256 MB | ~512 MB | ~128 MB |
| Context/batch buffers | ~64 MB | ~128 MB | ~32 MB |
| Daemon process overhead | ~64 MB | ~64 MB | ~64 MB |
| **Total** | **~1.5 GB** | **~3.3 GB** | **~0.6 GB** |

System RAM available for agent: ~2 GB (after Android system + apps).
- 1.5B: fits comfortably (~1.5 GB < 2 GB)
- 3B: tight (~3.3 GB > 2 GB) — requires user to close background apps
- 0.5B: always fits (~0.6 GB)

## Latency Budget

All measurements are estimates for Cortex-A73 @ 2.2 GHz, 4 threads, Q4_K_M.

| Model | Prompt eval | Generation | Effective throughput | First token latency |
|-------|-------------|------------|---------------------|---------------------|
| 0.5B | ~30 tok/s | ~15-20 tok/s | ~15-20 tok/s | ~1-2 s |
| 1.5B | ~15 tok/s | ~5-10 tok/s | ~5-10 tok/s | ~3-5 s |
| 3B | ~8 tok/s | ~3-5 tok/s | ~3-5 tok/s | ~6-10 s |

### User Experience Targets

- **Chat response (1.5B)**: 3-5 seconds for first token, ~20-30s for a
  100-token response. Acceptable for a conversational agent.
- **Tool call (1.5B)**: 2-4 seconds to parse intent + generate tool JSON.
  Consent gate adds 60s max (user response time).
- **Voice STT (whisper-tiny)**: ~0.5-1x realtime on A73 (3s audio → 1.5-3s).

## Degradation Plan

### Trigger: LMKD kills apexagentd (memory pressure)

1. LMKD selects apexagentd (oom_score_adj = 900, highest in killable list)
2. apexagentd killed; llama.cpp model memory freed
3. system_server detects binder death → fallback mode
4. Apex Control: "Agent unavailable — system conserving memory"
5. init restarts apexagentd after 30s
6. Daemon loads 0.5B fallback model (not the previous tier)
7. User notified: "Agent restarted in low-memory mode"
8. User can switch back via Apex Control when pressure subsides

### Trigger: llama.cpp crash (segfault in native code)

1. apexagentd process crashes (SIGSEGV/SIGABRT)
2. system_server detects binder death → fallback mode
3. init restarts apexagentd (up to 5 retries per 10 minutes)
4. If 5 retries exhausted: daemon stays down, fallback mode permanent
5. Apex Control: "Agent crashed — using system fallback (no LLM)"
6. McpRegistry + ConsentGate still operational in system_server

### Trigger: Model load failure (corrupt GGUF, disk full)

1. nativeLoadModel returns 0
2. Daemon logs error, falls back to next smaller tier
3. If all tiers fail: daemon runs in stub mode (no inference)
4. Apex Control: "No model available — stub mode"

## Thread Allocation

- **Inference threads**: 4 (pinned to A73 cluster via taskset)
- **Whisper threads**: 2 (lower priority, A53 cluster acceptable)
- **Socket I/O**: 2 threads (accept loop + handler pool)

## Thermal Considerations

Sustained inference on A73 @ 2.2 GHz can raise CPU temperature.
The APEX kernel's thermald monitors and throttles if needed:
- 65°C: reduce thread count from 4 → 2
- 75°C: pause inference, queue requests
- 85°C: kill apexagentd (thermal shutdown)

This integrates with the existing `rom-overlays/thermald/` configuration.
