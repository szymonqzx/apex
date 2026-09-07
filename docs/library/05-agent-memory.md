# 05 — Agent Memory

## Overview

The APEX agent has two complementary memory systems:

1. **AgentVectorStore** — SQLite + FTS5 with BM25 text retrieval. The primary memory system used at runtime. No external embedding model — uses BM25 ranking for semantic-ish retrieval. CPU-only.

2. **AgentMemoryStore** — Higher-level memory with embedding-based cosine similarity. Uses a quantized all-MiniLM-L6-v2 model (~23MB) via JNI for embedding computation. Designed for richer semantic retrieval but heavier.

Both store data on-device, encrypted via Android's File-Based Encryption (FBE). No data ever leaves the device.

## AgentVectorStore (293 lines)

### Storage
- **Path**: `/data/local/tmp/apex_memory.db`
- **Engine**: SQLite with FTS5 virtual table
- **Encryption**: Android FBE (file-based encryption)

### Schema
```sql
CREATE TABLE memories (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    content       TEXT NOT NULL,
    category      TEXT NOT NULL DEFAULT 'context',
    created_at    INTEGER NOT NULL,
    access_count  INTEGER DEFAULT 0,
    last_accessed INTEGER DEFAULT 0
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    content, content='memories', content_rowid='id'
);

-- Triggers keep FTS index in sync
CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, content)
    VALUES('delete', old.id, old.content);
END;

CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, content)
    VALUES('delete', old.id, old.content);
    INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
END;
```

### Categories
| Category | Purpose | Priority |
|----------|---------|----------|
| preference | User preferences (e.g., "I prefer dark mode") | High — always injected |
| routine | Recurring patterns (e.g., "User charges at 11pm") | Medium |
| conversation | Compact summary after each chat | Medium |
| context | Environmental context (location, time, activity) | Low |
| fact | Factual knowledge | Low |

### BM25 Retrieval
- **k1**: 1.2 (term frequency saturation)
- **b**: 0.75 (document length normalization)
- **Max results**: 10 per query
- Uses FTS5 `rank` function for BM25 scoring

### Operations
- `store(content, category)` → insert + FTS index update
- `retrieve(query, maxResults)` → FTS5 BM25 search, returns ranked MemoryEntry list
- `getByCategory(category, limit)` → category-filtered retrieval
- `updateAccessCount(id)` → increments access_count, updates last_accessed
- `close()` → closes SQLite connection

## AgentMemoryStore (214 lines)

### Storage
- **Path**: `/data/system/apex/agent_memory.db`
- **Engine**: SQLite with vector storage
- **Encryption**: Android FBE
- **Backup exclusion**: `android:fullBackupContent="false"` in manifest

### Embedding Model
- **Model**: all-MiniLM-L6-v2 quantized
- **Size**: ~23MB
- **Computation**: CPU-only via JNI (no GPU required)
- **Dimensions**: 384-dimensional float vectors

### Retrieval
- Cosine similarity over SQLite-stored vectors
- `SIMILARITY_THRESHOLD = 0.65` — memories below this score are not returned
- `MAX_CONTEXT_MEMORIES = 5` — top 5 most similar memories injected into prompt

### Memory Lifecycle
1. User message → embed → store with timestamp + metadata
2. Agent response → embed → store with tool calls + consent results
3. Next interaction → retrieve top-K similar memories → inject as context

### Privacy
- All embeddings computed on-device, never transmitted
- Memory database is FBE-encrypted at rest
- Excluded from cloud backups and local backups
- User can clear all memory from Apex Control

## MemoryManager (158 lines)

High-level wrapper around AgentVectorStore with semantic operations:

### Store Operations
- `storePreference(content)` — user preferences, high priority for prompt injection
- `storeRoutine(content)` — recurring patterns
- `storeConversationSummary(summary)` — truncated to 200 chars, stored as "conversation"
- `storeContext(content)` — environmental context
- `storeFact(content)` — factual knowledge

### Retrieval
- `getRelevantContext(query)` — retrieves top-5 memories, formats as:
  ```
  [Relevant memories]
  - [preference] I prefer dark mode
  - [routine] User charges phone at 11pm
  - [conversation] User asked about battery health yesterday
  ```
- `getPreferences()` — retrieves all preferences (up to 10), formats as:
  ```
  [User preferences]
  - I prefer dark mode
  - I want charge limit at 80%
  ```

### Prompt Injection
The MemoryManager's output is injected into the LLM prompt before the user's message:
```
System: You are APEX, an on-device AI assistant...
[User preferences]
- I prefer dark mode
- I want charge limit at 80%

[Relevant memories]
- [routine] User charges phone at 11pm
- [conversation] User asked about battery health yesterday

User: What's my battery health?
```

## Debug Log (AgentDebugLog.java, 170 lines)

Structured logging separate from the consent audit log. Captures internal agent diagnostics.

### Format
```
1694025600000 INFO llm Model loaded qwen2.5-1.5b in 3200ms
1694025601000 DEBUG tool Dispatching apex-charge-write limit=80
1694025601050 INFO consent Consent approved for apex-charge-write in 12000ms
1694025601100 WARN memory BM25 retrieval returned 0 results for query
```

### Log Levels and Components
| Level | Usage |
|-------|-------|
| DEBUG | Verbose internal state, timing details |
| INFO | Normal operation events |
| WARN | Unexpected but non-fatal conditions |
| ERROR | Failures that degrade agent functionality |

| Component | Scope |
|-----------|-------|
| llm | Model loading, inference, tier switching |
| tool | Tool dispatch, effect verification |
| consent | Consent requests, approvals, denials, timeouts |
| memory | Vector store operations, retrieval, storage |
| voice | Wake-word detection, STT transcription |
| system | Boot, shutdown, daemon lifecycle |

### Rotation
- File: `/data/system/apex/agent_debug.log`
- Max size: 5MB
- On rotation: `agent_debug.log` → `agent_debug.log.1` (old .1 deleted)
- Max lines per query: 500
