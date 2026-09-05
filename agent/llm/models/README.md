# APEX Agent Models

## Model Tiers

| Tier | Model | File | File Size | Runtime RAM | Throughput (A73) | Use Case |
|------|-------|------|-----------|-------------|------------------|----------|
| 0 (fallback) | Qwen 2.5 0.5B Q4_K_M | qwen2.5-0.5b-q4_k_m.gguf | ~0.5 GB | ~0.6 GB | ~15-20 tok/s | Emergency fallback, low memory |
| 1 (default) | Qwen 2.5 1.5B Q4_K_M | qwen2.5-1.5b-q4_k_m.gguf | ~1.1 GB | ~1.5 GB | ~5-10 tok/s | Default daily use |
| 2 (opt-in) | Qwen 2.5 3B Q4_K_M | qwen2.5-3b-q4_k_m.gguf | ~2.2 GB | ~3.3 GB | ~3-5 tok/s | High quality, opt-in only |

## Download Sources

Models are downloaded from trusted sources only (HuggingFace, unsloth):
- `https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF`
- `https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF`
- `https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF`

## Storage Path

```
/data/local/tmp/models/
├── qwen2.5-0.5b-q4_k_m.gguf
├── qwen2.5-1.5b-q4_k_m.gguf
└── qwen2.5-3b-q4_k_m.gguf
```

## Context Window

- Default context: 2048 tokens
- Batch size: 512 tokens
- All models use Q4_K_M quantization (best quality/size balance for ARM)

## Model Selection

Users select model tier via Apex Control → Model Router. The selection
is sent via `IApexAgent.setModelTier(String)` binder call. No reboot
required — the daemon unloads the current model and loads the new one.

## Degradation Plan

When memory pressure triggers LMKD to kill apexagentd:

1. LMKD kills apexagentd (oom_score_adj = 900)
2. system_server detects binder death → enters fallback mode
3. Apex Control shows "Agent unavailable — system conserving memory"
4. init restarts apexagentd after 30s delay
5. On restart, daemon loads the FALLBACK tier (0.5B) instead of the
   previous tier, reducing memory footprint
6. User is notified: "Agent restarted in low-memory mode (0.5B)"
7. User can manually switch back to a higher tier via Apex Control
   when memory pressure subsides

## Checksum Verification

If models are shipped with the ROM (future), SHA-256 checksums are
verified on first load. For download-based models, checksums are
verified post-download before the model is marked as available.
