# Agent Memory — On-Device Vector Store (T7)

## Overview

The APEX agent maintains persistent conversational memory using an on-device
vector store. This enables context-aware responses across sessions without
sending any data off-device.

## Architecture

```
User message → AgentMemoryStore.store()
  → computeEmbedding() (all-MiniLM-L6-v2 quantized, 384-dim)
  → SQLite insert (content, role, timestamp, metadata, embedding blob)

Next interaction → AgentMemoryStore.retrieveContext()
  → computeEmbedding(query)
  → cosine similarity search over all stored embeddings
  → top-5 results injected as system context for LLM
```

## Storage

- **Database**: `/data/system/apex/agent_memory.db` (SQLite)
- **Encryption**: File-Based Encryption (FBE) — stored in user-encrypted
  storage partition, automatically encrypted at rest
- **Backup exclusion**: Directory `/data/system/apex/` excluded from
  backup via `android:fullBackupContent="false"` in app manifest
- **SELinux**: `apex_agent.te` restricts access to `apexagentd` domain only

## Embedding Model

- **Model**: all-MiniLM-L6-v2 (quantized INT8, ~23MB)
- **Dimensions**: 384
- **Inference**: CPU-only, single A53 core, ~50ms per sentence
- **Memory**: ~25MB runtime (model + inference buffers)

## Privacy

- All embeddings computed on-device
- No data transmitted to any server
- Memory database is FBE-encrypted at rest
- Excluded from cloud and local backups
- User can clear all memory from Apex Control (Agent tab → Clear Memory)

## Schema

```sql
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content TEXT NOT NULL,
  role TEXT NOT NULL,        -- user / agent / system
  timestamp INTEGER NOT NULL,
  metadata TEXT DEFAULT '',  -- JSON: tool calls, consent results
  embedding BLOB NOT NULL    -- 384 * 4 bytes (float32)
);

CREATE INDEX IF NOT EXISTS idx_timestamp ON memories(timestamp);
```

## Retrieval Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| MAX_CONTEXT_MEMORIES | 5 | Max memories injected as context |
| SIMILARITY_THRESHOLD | 0.65 | Minimum cosine similarity to include |
| Embedding dimensions | 384 | all-MiniLM-L6-v2 output size |
