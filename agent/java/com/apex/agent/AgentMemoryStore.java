package com.apex.agent;

import java.util.ArrayList;
import java.util.List;

/**
 * On-device persistent agent memory using a lightweight vector store (T7).
 *
 * Architecture:
 *   - Storage: SQLite database at /data/system/apex/agent_memory.db
 *   - Encryption: File-Based Encryption (FBE) — data is in user-encrypted
 *     storage, automatically encrypted at rest
 *   - Backup exclusion: directory excluded from backup via
 *     android:fullBackupContent="false" in manifest
 *   - Embeddings: CPU-only sentence embeddings via lightweight model
 *     (all-MiniLM-L6-v2 quantized, ~23MB)
 *   - Vector search: cosine similarity over SQLite-stored vectors
 *
 * Memory lifecycle:
 *   1. User message → embed → store with timestamp + metadata
 *   2. Agent response → embed → store with tool calls + consent results
 *   3. Next interaction → retrieve top-K similar memories → inject as context
 *
 * Privacy:
 *   - All embeddings computed on-device, never transmitted
 *   - Memory database is FBE-encrypted at rest
 *   - Excluded from cloud backups and local backups
 *   - User can clear all memory from Apex Control
 */
public final class AgentMemoryStore {

    private static final int MAX_CONTEXT_MEMORIES = 5;
    private static final double SIMILARITY_THRESHOLD = 0.65;

    public static final class MemoryEntry {
        public final long id;
        public final String content;
        public final String role;      // "user", "agent", "system"
        public final long timestamp;
        public final String metadata;  // JSON: tool calls, consent results
        public final float[] embedding;

        public MemoryEntry(long id, String content, String role,
                          long timestamp, String metadata, float[] embedding) {
            this.id = id;
            this.content = content;
            this.role = role;
            this.timestamp = timestamp;
            this.metadata = metadata;
            this.embedding = embedding;
        }
    }

    private final String dbPath;

    public AgentMemoryStore(String dbPath) {
        this.dbPath = dbPath;
        // Initialize SQLite database with schema
        initDatabase();
    }

    /**
     * Store a memory entry with its embedding.
     *
     * @param content   The text content to remember
     * @param role      Who produced this content (user/agent/system)
     * @param metadata  JSON string with tool calls, consent results, etc.
     */
    public synchronized long store(String content, String role, String metadata) {
        if (content == null || content.isEmpty()) return -1;

        // Sanitize for SQL
        String safeContent = UntrustedInputSanitizer.sanitizeForSql(content);
        String safeRole = UntrustedInputSanitizer.sanitizeForSql(role);
        String safeMeta = metadata != null
            ? UntrustedInputSanitizer.sanitizeForSql(metadata) : "";

        // Compute embedding (JNI call to quantized model)
        float[] embedding = computeEmbedding(content);

        // Insert into SQLite
        long id = insertMemory(safeContent, safeRole, safeMeta, embedding);
        return id;
    }

    /**
     * Retrieve the top-K most similar memories to the query.
     *
     * @param query  The query text
     * @param k      Maximum number of memories to return
     * @return List of MemoryEntry, most similar first
     */
    public synchronized List<MemoryEntry> retrieve(String query, int k) {
        if (query == null || query.isEmpty()) {
            return new ArrayList<>();
        }

        float[] queryEmbedding = computeEmbedding(query);
        List<MemoryEntry> all = getAllMemories();
        List<MemoryEntry> results = new ArrayList<>();

        // Compute cosine similarity and sort
        for (MemoryEntry entry : all) {
            double sim = cosineSimilarity(queryEmbedding, entry.embedding);
            if (sim >= SIMILARITY_THRESHOLD) {
                results.add(entry);
            }
        }

        // Sort by similarity (descending) and take top K
        results.sort((a, b) -> {
            double simA = cosineSimilarity(queryEmbedding, a.embedding);
            double simB = cosineSimilarity(queryEmbedding, b.embedding);
            return Double.compare(simB, simA);
        });

        if (results.size() > k) {
            results = results.subList(0, k);
        }
        return results;
    }

    /**
     * Retrieve context memories for the next agent interaction.
     * Uses MAX_CONTEXT_MEMORIES and SIMILARITY_THRESHOLD.
     */
    public List<MemoryEntry> retrieveContext(String query) {
        return retrieve(query, MAX_CONTEXT_MEMORIES);
    }

    /**
     * Clear all stored memories.
     */
    public synchronized void clearAll() {
        clearDatabase();
    }

    /**
     * Get total memory count.
     */
    public synchronized int count() {
        return getMemoryCount();
    }

    /**
     * Get storage size in bytes.
     */
    public synchronized long storageSize() {
        java.io.File f = new java.io.File(dbPath);
        return f.exists() ? f.length() : 0;
    }

    // --- Internal methods ---

    private void initDatabase() {
        // SQLite schema:
        // CREATE TABLE IF NOT EXISTS memories (
        //   id INTEGER PRIMARY KEY AUTOINCREMENT,
        //   content TEXT NOT NULL,
        //   role TEXT NOT NULL,
        //   timestamp INTEGER NOT NULL,
        //   metadata TEXT DEFAULT '',
        //   embedding BLOB NOT NULL
        // );
        // CREATE INDEX IF NOT EXISTS idx_timestamp ON memories(timestamp);
        nativeInitDb(dbPath);
    }

    private long insertMemory(String content, String role,
                              String metadata, float[] embedding) {
        return nativeInsert(dbPath, content, role,
            System.currentTimeMillis(), metadata, embedding);
    }

    private List<MemoryEntry> getAllMemories() {
        // Query all memories from SQLite
        return nativeGetAll(dbPath);
    }

    private void clearDatabase() {
        nativeClearAll(dbPath);
    }

    private int getMemoryCount() {
        return nativeCount(dbPath);
    }

    private float[] computeEmbedding(String text) {
        // JNI call to quantized all-MiniLM-L6-v2 model
        // Returns 384-dimensional float vector
        return nativeEmbed(text);
    }

    private static double cosineSimilarity(float[] a, float[] b) {
        if (a == null || b == null || a.length != b.length) return 0.0;
        double dot = 0, normA = 0, normB = 0;
        for (int i = 0; i < a.length; i++) {
            dot += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
        }
        if (normA == 0 || normB == 0) return 0.0;
        return dot / (Math.sqrt(normA) * Math.sqrt(normB));
    }

    // Native methods (implemented in libmemory_jni.so)
    private native void nativeInitDb(String dbPath);
    private native long nativeInsert(String dbPath, String content,
        String role, long timestamp, String metadata, float[] embedding);
    private native List<MemoryEntry> nativeGetAll(String dbPath);
    private native void nativeClearAll(String dbPath);
    private native int nativeCount(String dbPath);
    private native float[] nativeEmbed(String text);
}
