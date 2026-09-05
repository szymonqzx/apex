/*
 * MemoryManager.java
 *
 * High-level memory management for the APEX agent.
 * Wraps AgentVectorStore with semantic operations:
 *   - storePreference: user preferences (persisted, high priority)
 *   - storeRoutine: recurring patterns (e.g., "user charges at 11pm")
 *   - storeConversationSummary: compact summary after each chat
 *   - storeContext: environmental context (location, time, activity)
 *   - storeFact: factual knowledge
 *
 * Also handles prompt injection: retrieves relevant memories and
 * formats them as context for the LLM prompt.
 */

package com.apex.agent;

import android.util.Log;

import java.util.List;

public class MemoryManager {
  private static final String TAG = "MemoryManager";
  private static final int MAX_CONTEXT_MEMORIES = 5;
  private static final int MAX_SUMMARY_LENGTH = 200;

  private final AgentVectorStore mStore;

  public MemoryManager() {
    mStore = new AgentVectorStore();
    mStore.open();
  }

  public void close() {
    mStore.close();
  }

  // ── Store operations ─────────────────────────────────────────────

  public long storePreference(String content) {
    return mStore.store(content, "preference");
  }

  public long storeRoutine(String content) {
    return mStore.store(content, "routine");
  }

  public long storeConversationSummary(String summary) {
    // Truncate if too long
    if (summary.length() > MAX_SUMMARY_LENGTH) {
      summary = summary.substring(0, MAX_SUMMARY_LENGTH) + "...";
    }
    return mStore.store(summary, "conversation");
  }

  public long storeContext(String content) {
    return mStore.store(content, "context");
  }

  public long storeFact(String content) {
    return mStore.store(content, "fact");
  }

  // ── Retrieval ────────────────────────────────────────────────────

  /**
   * Retrieve memories relevant to the given query and format them
   * as a context block for the LLM prompt.
   */
  public String getRelevantContext(String query) {
    List<AgentVectorStore.MemoryEntry> memories =
        mStore.retrieve(query, MAX_CONTEXT_MEMORIES);

    if (memories.isEmpty()) {
      return "";
    }

    StringBuilder sb = new StringBuilder();
    sb.append("[Relevant memories]\n");
    for (AgentVectorStore.MemoryEntry m : memories) {
      sb.append("- [").append(m.category).append("] ");
      sb.append(m.content).append("\n");
    }
    return sb.toString();
  }

  /**
   * Get all preferences (for prompt injection).
   */
  public String getPreferences() {
    List<AgentVectorStore.MemoryEntry> prefs =
        mStore.getByCategory("preference", 10);
    if (prefs.isEmpty()) return "";

    StringBuilder sb = new StringBuilder();
    sb.append("[User preferences]\n");
    for (AgentVectorStore.MemoryEntry m : prefs) {
      sb.append("- ").append(m.content).append("\n");
    }
    return sb.toString();
  }

  /**
   * Get recent routines.
   */
  public String getRoutines() {
    List<AgentVectorStore.MemoryEntry> routines =
        mStore.getByCategory("routine", 5);
    if (routines.isEmpty()) return "";

    StringBuilder sb = new StringBuilder();
    sb.append("[User routines]\n");
    for (AgentVectorStore.MemoryEntry m : routines) {
      sb.append("- ").append(m.content).append("\n");
    }
    return sb.toString();
  }

  /**
   * Build a full context block for the LLM prompt.
   * Includes: preferences, routines, and query-relevant memories.
   */
  public String buildPromptContext(String userQuery) {
    StringBuilder ctx = new StringBuilder();

    String prefs = getPreferences();
    if (!prefs.isEmpty()) {
      ctx.append(prefs).append("\n");
    }

    String routines = getRoutines();
    if (!routines.isEmpty()) {
      ctx.append(routines).append("\n");
    }

    String relevant = getRelevantContext(userQuery);
    if (!relevant.isEmpty()) {
      ctx.append(relevant);
    }

    return ctx.toString().trim();
  }

  // ── Management ───────────────────────────────────────────────────

  public boolean deleteMemory(long id) {
    return mStore.delete(id);
  }

  public int getMemoryCount() {
    return mStore.count();
  }

  public void clearAll() {
    // Not implemented — would need a DELETE FROM memories query
    Log.w(TAG, "clearAll not implemented — use targeted delete");
  }
}
