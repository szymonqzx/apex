/*
 * HitlConsentStore.java
 *
 * Append-only SQLite store for the consent audit log (HITL = Human In The Loop).
 *
 * Schema:
 *   consent_audit(
 *     id INTEGER PRIMARY KEY AUTOINCREMENT,
 *     timestamp TEXT NOT NULL,
 *     tool_name TEXT NOT NULL,
 *     description TEXT,
 *     action TEXT,
 *     result TEXT NOT NULL,
 *     duration_ms INTEGER
 *   )
 *
 * Database path: /data/system/apex/consent_audit.db
 * SELinux-protected: only system_server (apex_agent domain) can read/write.
 *
 * The audit log is APPEND-ONLY — no delete or update operations.
 */

package com.apex.agent;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Log;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class HitlConsentStore {
  private static final String TAG = "ApexConsentStore";
  private static final String DB_NAME = "consent_audit.db";
  private static final int DB_VERSION = 1;
  private static final String TABLE = "consent_audit";

  private final ConsentDbHelper mDbHelper;

  public HitlConsentStore(Context context) {
    mDbHelper = new ConsentDbHelper(context);
  }

  /**
   * Log a consent event. This is append-only — no update or delete.
   */
  public void log(String toolName, String description, String action,
                   String result, long durationMs) {
    SQLiteDatabase db = mDbHelper.getWritableDatabase();
    ContentValues values = new ContentValues();
    values.put("timestamp", nowIso());
    values.put("tool_name", toolName);
    values.put("description", description);
    values.put("action", action);
    values.put("result", result);
    values.put("duration_ms", durationMs);
    db.insert(TABLE, null, values);
    Log.d(TAG, "Audit: " + toolName + " → " + result + " (" + durationMs + "ms)");
  }

  /**
   * Query recent consent events.
   */
  public List<AuditEntry> queryRecent(int limit) {
    List<AuditEntry> entries = new ArrayList<>();
    SQLiteDatabase db = mDbHelper.getReadableDatabase();
    Cursor cursor = db.query(TABLE, null, null, null, null, null,
        "id DESC", String.valueOf(limit));
    try {
      while (cursor.moveToNext()) {
        entries.add(new AuditEntry(
            cursor.getLong(cursor.getColumnIndexOrThrow("id")),
            cursor.getString(cursor.getColumnIndexOrThrow("timestamp")),
            cursor.getString(cursor.getColumnIndexOrThrow("tool_name")),
            cursor.getString(cursor.getColumnIndexOrThrow("description")),
            cursor.getString(cursor.getColumnIndexOrThrow("action")),
            cursor.getString(cursor.getColumnIndexOrThrow("result")),
            cursor.getLong(cursor.getColumnIndexOrThrow("duration_ms"))));
      }
    } finally {
      cursor.close();
    }
    return entries;
  }

  /**
   * Query consent events by tool name.
   */
  public List<AuditEntry> queryByTool(String toolName) {
    List<AuditEntry> entries = new ArrayList<>();
    SQLiteDatabase db = mDbHelper.getReadableDatabase();
    Cursor cursor = db.query(TABLE, null, "tool_name = ?",
        new String[]{toolName}, null, null, "id DESC");
    try {
      while (cursor.moveToNext()) {
        entries.add(new AuditEntry(
            cursor.getLong(cursor.getColumnIndexOrThrow("id")),
            cursor.getString(cursor.getColumnIndexOrThrow("timestamp")),
            cursor.getString(cursor.getColumnIndexOrThrow("tool_name")),
            cursor.getString(cursor.getColumnIndexOrThrow("description")),
            cursor.getString(cursor.getColumnIndexOrThrow("action")),
            cursor.getString(cursor.getColumnIndexOrThrow("result")),
            cursor.getLong(cursor.getColumnIndexOrThrow("duration_ms"))));
      }
    } finally {
      cursor.close();
    }
    return entries;
  }

  // ── Audit entry data class ──────────────────────────────────────

  public static class AuditEntry {
    public final long id;
    public final String timestamp;
    public final String toolName;
    public final String description;
    public final String action;
    public final String result;
    public final long durationMs;

    public AuditEntry(long id, String timestamp, String toolName,
                      String description, String action, String result, long durationMs) {
      this.id = id;
      this.timestamp = timestamp;
      this.toolName = toolName;
      this.description = description;
      this.action = action;
      this.result = result;
      this.durationMs = durationMs;
    }
  }

  // ── SQLite helper ───────────────────────────────────────────────

  private static class ConsentDbHelper extends SQLiteOpenHelper {
    ConsentDbHelper(Context context) {
      super(context, DB_NAME, null, DB_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
      db.execSQL(
          "CREATE TABLE " + TABLE + " ("
              + "id INTEGER PRIMARY KEY AUTOINCREMENT,"
              + "timestamp TEXT NOT NULL,"
              + "tool_name TEXT NOT NULL,"
              + "description TEXT,"
              + "action TEXT,"
              + "result TEXT NOT NULL,"
              + "duration_ms INTEGER"
              + ")");
      db.execSQL(
          "CREATE INDEX idx_consent_tool ON " + TABLE + "(tool_name)");
      db.execSQL(
          "CREATE INDEX idx_consent_timestamp ON " + TABLE + "(timestamp)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
      // Append-only — never drop. Add migration columns if needed.
      if (oldVersion < 2) {
        // Future: add columns here with ALTER TABLE
      }
    }
  }

  private static String nowIso() {
    return new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)
        .format(new Date());
  }
}
