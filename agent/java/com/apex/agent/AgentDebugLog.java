package com.apex.agent;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Structured agent debug log (T8).
 *
 * Separate from the consent audit log (HitlConsentStore). This log captures
 * internal agent diagnostics: LLM inference timing, model loading/unloading,
 * tool dispatch events, memory retrieval, voice events, and errors.
 *
 * Format: structured text at /data/system/apex/agent_debug.log
 * Each line: TIMESTAMP LEVEL COMPONENT MESSAGE [key=value ...]
 *
 * Viewable from Apex Control via AgentDebugLogViewer composable.
 *
 * Log levels:
 *   DEBUG   - verbose internal state
 *   INFO    - normal operation events
 *   WARN    - unexpected but non-fatal conditions
 *   ERROR   - failures that degrade agent functionality
 *
 * Components: llm, tool, consent, memory, voice, system
 *
 * Rotation: log file capped at 5MB, rotates to agent_debug.log.1
 */
public final class AgentDebugLog {

    private static final String LOG_PATH = "/data/system/apex/agent_debug.log";
    private static final long MAX_LOG_SIZE = 5 * 1024 * 1024; // 5MB
    private static final int MAX_LINES_RETURN = 500;

    public static final class LogEntry {
        public final String timestamp;
        public final String level;
        public final String component;
        public final String message;
        public final String kvPairs;

        public LogEntry(String timestamp, String level, String component,
                       String message, String kvPairs) {
            this.timestamp = timestamp;
            this.level = level;
            this.component = component;
            this.message = message;
            this.kvPairs = kvPairs;
        }

        @Override
        public String toString() {
            return timestamp + " " + level + " " + component + " " + message
                + (kvPairs.isEmpty() ? "" : " " + kvPairs);
        }
    }

    private AgentDebugLog() {}

    /**
     * Append a debug log entry.
     */
    public static synchronized void log(String level, String component,
                                        String message, String kvPairs) {
        String entry = System.currentTimeMillis() + " " +
            level + " " + component + " " + message +
            (kvPairs != null && !kvPairs.isEmpty() ? " " + kvPairs : "") + "\n";

        // Check rotation
        java.io.File f = new java.io.File(LOG_PATH);
        if (f.exists() && f.length() > MAX_LOG_SIZE) {
            java.io.File rotated = new java.io.File(LOG_PATH + ".1");
            if (rotated.exists()) rotated.delete();
            f.renameTo(rotated);
        }

        // Append
        try (java.io.FileWriter writer = new java.io.FileWriter(LOG_PATH, true)) {
            writer.append(entry);
        } catch (IOException e) {
            // Logging failure must not crash the agent
        }
    }

    public static void debug(String component, String message) {
        log("DEBUG", component, message, "");
    }

    public static void info(String component, String message) {
        log("INFO", component, message, "");
    }

    public static void warn(String component, String message) {
        log("WARN", component, message, "");
    }

    public static void error(String component, String message) {
        log("ERROR", component, message, "");
    }

    public static void info(String component, String message, String kvPairs) {
        log("INFO", component, message, kvPairs);
    }

    /**
     * Read the last N log entries for display in Apex Control.
     *
     * @param maxLines Maximum number of entries to return
     * @return List of LogEntry, most recent last
     */
    public static List<LogEntry> readRecent(int maxLines) {
        List<LogEntry> entries = new ArrayList<>();
        if (maxLines <= 0) maxLines = MAX_LINES_RETURN;

        try (BufferedReader reader = new BufferedReader(new FileReader(LOG_PATH))) {
            String line;
            while ((line = reader.readLine()) != null) {
                LogEntry entry = parseLine(line);
                if (entry != null) {
                    entries.add(entry);
                }
            }
        } catch (IOException e) {
            return entries;
        }

        // Return last N entries
        if (entries.size() > maxLines) {
            entries = entries.subList(entries.size() - maxLines, entries.size());
        }
        return entries;
    }

    /**
     * Read recent entries filtered by component.
     */
    public static List<LogEntry> readByComponent(String component, int maxLines) {
        List<LogEntry> all = readRecent(maxLines * 4);
        List<LogEntry> filtered = new ArrayList<>();
        for (LogEntry e : all) {
            if (component.equals(e.component)) {
                filtered.add(e);
                if (filtered.size() >= maxLines) break;
            }
        }
        return filtered;
    }

    /**
     * Parse a log line into a LogEntry.
     * Format: TIMESTAMP LEVEL COMPONENT MESSAGE [key=value ...]
     */
    private static LogEntry parseLine(String line) {
        if (line == null || line.isEmpty()) return null;
        String[] parts = line.split(" ", 5);
        if (parts.length < 4) return null;
        String kvPairs = parts.length > 4 ? parts[4] : "";
        return new LogEntry(parts[0], parts[1], parts[2], parts[3], kvPairs);
    }

    /**
     * Clear the debug log.
     */
    public static synchronized void clear() {
        java.io.File f = new java.io.File(LOG_PATH);
        if (f.exists()) f.delete();
    }
}
