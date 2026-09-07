/*
 * AgentVectorStore.java
 *
 * On-device persistent memory using SQLite + BM25 text retrieval.
 * No external embedding model — uses BM25 ranking for semantic-ish
 * retrieval. CPU-only, no GPU required.
 *
 * Storage: /data/local/tmp/apex_memory.db (file-based encryption)
 *
 * Schema:
 *   memories(id INTEGER PRIMARY KEY, content TEXT, category TEXT,
 *            created_at INTEGER, access_count INTEGER,
 *            last_accessed INTEGER)
 *   memories_fts USING fts5(content) — full-text search index
 *
 * Categories: preference, routine, conversation, context, fact
 *
 * Privacy: all data stays on device, encrypted via Android's
 * file-based encryption (FBE). No data leaves the device.
 */

package com.apex.agent;

import android.util.Log;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

public class AgentVectorStore {
  private static final String TAG = "AgentVectorStore";
  private static final String DB_PATH = "/data/local/tmp/apex_memory.db";
  private static final int MAX_RESULTS = 10;
  private static final double BM25_K1 = 1.2;
  private static final double BM25_B = 0.75;

  private Connection mConnection;

  public void open() {
    try {
      String url = "jdbc:sqlite:" + DB_PATH;
      mConnection = DriverManager.getConnection(url);
      initSchema();
      Log.i(TAG, "Vector store opened at " + DB_PATH);
    } catch (Exception e) {
      Log.e(TAG, "Failed to open vector store: " + e.getMessage());
    }
  }

  public void close() {
    try {
      if (mConnection != null && !mConnection.isClosed()) {
        mConnection.close();
      }
    } catch (Exception e) {
      Log.w(TAG, "Close failed: " + e.getMessage());
    }
  }

  private void initSchema() throws Exception {
    try (Statement stmt = mConnection.createStatement()) {
      // Main table
      stmt.execute(
          "CREATE TABLE IF NOT EXISTS memories (" +
          "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
          "  content TEXT NOT NULL," +
          "  category TEXT NOT NULL DEFAULT 'context'," +
          "  created_at INTEGER NOT NULL," +
          "  access_count INTEGER DEFAULT 0," +
          "  last_accessed INTEGER DEFAULT 0)");

      // FTS5 virtual table for full-text search
      stmt.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts " +
          "USING fts5(content, content='memories', content_rowid='id')");

      // Triggers to keep FTS in sync
      stmt.execute(
          "CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories " +
          "BEGIN INSERT INTO memories_fts(rowid, content) " +
          "VALUES (new.id, new.content); END");

      stmt.execute(
          "CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories " +
          "BEGIN INSERT INTO memories_fts(memories_fts, rowid, content) " +
          "VALUES('delete', old.id, old.content); END");

      stmt.execute(
          "CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories " +
          "BEGIN INSERT INTO memories_fts(memories_fts, rowid, content) " +
          "VALUES('delete', old.id, old.content); " +
          "INSERT INTO memories_fts(rowid, content) " +
          "VALUES (new.id, new.content); END");
    }
  }

  /**
   * Store a memory.
   * @param content  The memory text
   * @param category One of: preference, routine, conversation, context, fact
   * @return The ID of the stored memory, or -1 on failure
   */
  public long store(String content, String category) {
    if (mConnection == null) return -1;
    try {
      PreparedStatement ps = mConnection.prepareStatement(
          "INSERT INTO memories (content, category, created_at) VALUES (?, ?, ?)",
          Statement.RETURN_GENERATED_KEYS);
      ps.setString(1, content);
      ps.setString(2, category);
      ps.setLong(3, System.currentTimeMillis());
      ps.executeUpdate();

      ResultSet keys = ps.getGeneratedKeys();
      if (keys.next()) {
        long id = keys.getLong(1);
        Log.i(TAG, "Stored memory " + id + " [" + category + "]: "
            + content.substring(0, Math.min(60, content.length())));
        return id;
      }
    } catch (Exception e) {
      Log.e(TAG, "Store failed: " + e.getMessage());
    }
    return -1;
  }

  /**
   * Retrieve relevant memories using BM25 ranking via FTS5.
   * @param query  The search query
   * @param limit  Max results (default 10)
   * @return List of memory entries, ranked by relevance
   */
  public List<MemoryEntry> retrieve(String query, int limit) {
    if (mConnection == null) return new ArrayList<>();
    if (limit <= 0) limit = MAX_RESULTS;

    List<MemoryEntry> results = new ArrayList<>();
    try {
      // FTS5 BM25 ranking
      PreparedStatement ps = mConnection.prepareStatement(
          "SELECT m.id, m.content, m.category, m.created_at, " +
          "  m.access_count, m.last_accessed, " +
          "  bm25(memories_fts) as score " +
          "FROM memories_fts " +
          "JOIN memories m ON m.id = memories_fts.rowid " +
          "WHERE memories_fts MATCH ? " +
          "ORDER BY score ASC " +
          "LIMIT ?");

      // FTS5 query syntax: escape special chars, use OR for multi-word
      String ftsQuery = sanitizeFtsQuery(query);
      ps.setString(1, ftsQuery);
      ps.setInt(2, limit);

      ResultSet rs = ps.executeQuery();
      while (rs.next()) {
        MemoryEntry entry = new MemoryEntry();
        entry.id = rs.getLong("id");
        entry.content = rs.getString("content");
        entry.category = rs.getString("category");
        entry.createdAt = rs.getLong("created_at");
        entry.accessCount = rs.getInt("access_count");
        entry.lastAccessed = rs.getLong("last_accessed");
        entry.score = rs.getDouble("score");
        results.add(entry);
      }

      // Update access counts
      for (MemoryEntry entry : results) {
        incrementAccess(entry.id);
      }

      Log.i(TAG, "Retrieved " + results.size() + " memories for query: "
          + query.substring(0, Math.min(40, query.length())));
    } catch (Exception e) {
      Log.e(TAG, "Retrieve failed: " + e.getMessage());
    }
    return results;
  }

  /**
   * Retrieve memories by category.
   */
  public List<MemoryEntry> getByCategory(String category, int limit) {
    if (mConnection == null) return new ArrayList<>();
    List<MemoryEntry> results = new ArrayList<>();
    try {
      PreparedStatement ps = mConnection.prepareStatement(
          "SELECT id, content, category, created_at, access_count, last_accessed " +
          "FROM memories WHERE category = ? " +
          "ORDER BY last_accessed DESC LIMIT ?");
      ps.setString(1, category);
      ps.setInt(2, limit);

      ResultSet rs = ps.executeQuery();
      while (rs.next()) {
        MemoryEntry entry = new MemoryEntry();
        entry.id = rs.getLong("id");
        entry.content = rs.getString("content");
        entry.category = rs.getString("category");
        entry.createdAt = rs.getLong("created_at");
        entry.accessCount = rs.getInt("access_count");
        entry.lastAccessed = rs.getLong("last_accessed");
        results.add(entry);
      }
    } catch (Exception e) {
      Log.e(TAG, "getByCategory failed: " + e.getMessage());
    }
    return results;
  }

  /**
   * Delete a memory by ID.
   */
  public boolean delete(long id) {
    if (mConnection == null) return false;
    try {
      PreparedStatement ps = mConnection.prepareStatement(
          "DELETE FROM memories WHERE id = ?");
      ps.setLong(1, id);
      int rows = ps.executeUpdate();
      return rows > 0;
    } catch (Exception e) {
      Log.e(TAG, "Delete failed: " + e.getMessage());
      return false;
    }
  }

  /**
   * Get total memory count.
   */
  public int count() {
    if (mConnection == null) return 0;
    try (Statement stmt = mConnection.createStatement();
         ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM memories")) {
      if (rs.next()) return rs.getInt(1);
    } catch (Exception e) {
      Log.w(TAG, "Count failed: " + e.getMessage());
    }
    return 0;
  }

  private void incrementAccess(long id) {
    try {
      PreparedStatement ps = mConnection.prepareStatement(
          "UPDATE memories SET access_count = access_count + 1, " +
          "last_accessed = ? WHERE id = ?");
      ps.setLong(1, System.currentTimeMillis());
      ps.setLong(2, id);
      ps.executeUpdate();
    } catch (Exception ignored) {
    }
  }

  /**
   * Sanitize a user query for FTS5 MATCH.
   * Removes special FTS5 syntax characters and wraps terms in OR.
   */
  private String sanitizeFtsQuery(String query) {
    // Remove FTS5 special characters
    String cleaned = query.replaceAll("[\"*():^]", " ");
    // Split into terms and join with OR for broader matching
    String[] terms = cleaned.trim().split("\\s+");
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < terms.length; i++) {
      if (terms[i].length() < 2) continue;
      if (sb.length() > 0) sb.append(" OR ");
      sb.append(terms[i]);
    }
    return sb.length() > 0 ? sb.toString() : cleaned;
  }

  // ── Data class ───────────────────────────────────────────────────

  public static class MemoryEntry {
    public long id;
    public String content;
    public String category;
    public long createdAt;
    public int accessCount;
    public long lastAccessed;
    public double score; // BM25 score (lower = more relevant in FTS5)

    @Override
    public String toString() {
      return "Memory[" + id + "][" + category + "] " + content;
    }
  }
}
