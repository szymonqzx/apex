# APEX LLM Inference Layer

On-device LLM inference for the APEX agent. CPU-only (Adreno 610
cannot do GPU inference — no Vulkan 1.1, limited OpenCL compute).

## Components

- **llama.cpp** — GGUF model inference (Qwen 2.5 0.5B/1.5B/3B)
- **whisper.cpp** — Speech-to-text for voice input (T6)
- **libllm_jni** — JNI bridge between Java daemon and native libraries

## Cross-Compilation

Both libraries are cross-compiled for `aarch64-linux-android` using the
Android NDK (r26+). See:

- `build-llama.sh` — llama.cpp build
- `build-whisper.sh` — whisper.cpp build

Key build flags (ARM, no x86 SIMD):
- `LLAMA_NATIVE=OFF` — no runtime CPU detection
- `LLAMA_AVX=OFF`, `LLAMA_AVX2=OFF`, `LLAMA_FMA=OFF`, `LLAMA_F16C=OFF`
- ARM NEON is auto-detected by the NDK compiler

## Model Management

See `models/README.md` for model details and `MEMORY_BUDGET.md` for
latency/memory budgets and the degradation plan.

Default model: Qwen 2.5 1.5B Q4_K_M (~1.1GB file, ~1.5GB runtime)
Opt-in: Qwen 2.5 3B Q4_K_M (~2.2GB file, ~3.3GB runtime)
Fallback: Qwen 2.5 0.5B Q4_K_M (~0.6GB file, ~0.6GB runtime)

## Process Isolation

The inference runs in `apexagentd` (separate process from system_server).
If llama.cpp crashes or is killed by LMKD under memory pressure:

1. system_server detects binder death
2. LlmManagerService enters fallback mode
3. McpRegistry and ConsentGate remain operational
4. User sees "agent unavailable" in Apex Control
5. apexagentd is restarted by init (up to 5 retries per 10 minutes)
