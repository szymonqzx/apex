/*
 * ChargeControlTool.java
 *
 * MCP tool for agent-driven charge control (E3).
 *
 * WRITE tool — requires DUAL_CONFIRMATION consent:
 *   1. On-screen approve in Apex Control
 *   2. Physical button press (volume key within 5s)
 *
 * Rate limited: max 1 charge control change per 10 minutes.
 * All writes are audit logged with before/after values.
 *
 * Writes to /sys/class/power_supply/battery/charge_control_limit_max
 * (standard Android power_supply sysfs interface, supported by APEX kernel).
 */

package com.apex.agent;

import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;

public class ChargeControlTool {
  private static final String TAG = "ChargeControlTool";
  private static final String CHARGE_LIMIT_PATH =
      "/sys/class/power_supply/battery/charge_control_limit_max";
  private static final long RATE_LIMIT_MS = 10 * 60 * 1000; // 10 minutes
  private static final int MIN_LIMIT = 20;
  private static final int MAX_LIMIT = 100;

  private long mLastWriteTime = 0;
  private int mLastWrittenValue = -1;
  private final ConsentGate mConsentGate;

  public ChargeControlTool(ConsentGate consentGate) {
    mConsentGate = consentGate;
  }

  /**
   * Read current charge limit.
   */
  public String readLimit() {
    String val = readSysfs(CHARGE_LIMIT_PATH);
    if (val == null) {
      return "{\"error\":\"charge_control_limit_max not available\"}";
    }
    return "{\"status\":\"ok\",\"charge_limit\":" + val.trim() + "}";
  }

  /**
   * Write charge limit. Requires dual-confirmation consent.
   *
   * @param limitPercent  Target charge limit (20-100)
   * @return JSON result string
   */
  public String writeLimit(int limitPercent) {
    // Validate range
    if (limitPercent < MIN_LIMIT || limitPercent > MAX_LIMIT) {
      return "{\"error\":\"limit must be between " + MIN_LIMIT
          + " and " + MAX_LIMIT + ", got " + limitPercent + "\"}";
    }

    // Rate limit check
    long now = System.currentTimeMillis();
    if (now - mLastWriteTime < RATE_LIMIT_MS) {
      long remaining = (RATE_LIMIT_MS - (now - mLastWriteTime)) / 1000;
      return "{\"error\":\"rate limited — wait " + remaining
          + "s before next change\"}";
    }

    // Read current value for audit
    String before = readSysfs(CHARGE_LIMIT_PATH);
    int beforeVal = -1;
    if (before != null) {
      try {
        beforeVal = Integer.parseInt(before.trim());
      } catch (NumberFormatException ignored) {
      }
    }

    // No-op if already at target
    if (beforeVal == limitPercent) {
      return "{\"status\":\"ok\",\"message\":\"already at "
          + limitPercent + "%\",\"charge_limit\":" + limitPercent + "}";
    }

    // Request dual-confirmation consent
    String consentId = mConsentGate.requestConsent(
        "apex-charge-write",
        "Set charge limit to " + limitPercent + "%"
            + " (currently " + (beforeVal >= 0 ? beforeVal : "unknown") + "%)",
        "Write " + limitPercent + " to " + CHARGE_LIMIT_PATH);

    // Wait for consent with 60s timeout
    ConsentGate.ConsentState state = mConsentGate.waitForDecision(
        consentId, 60, java.util.concurrent.TimeUnit.SECONDS);

    if (state != ConsentGate.ConsentState.APPROVED) {
      return "{\"error\":\"consent " + state.name().toLowerCase()
          + " — charge limit not changed\"}";
    }

    // Perform the write
    boolean success = writeSysfs(CHARGE_LIMIT_PATH, String.valueOf(limitPercent));
    if (!success) {
      return "{\"error\":\"failed to write to "
          + CHARGE_LIMIT_PATH + "\"}";
    }

    mLastWriteTime = System.currentTimeMillis();
    mLastWrittenValue = limitPercent;

    Log.i(TAG, "Charge limit changed: " + beforeVal + " → " + limitPercent
        + " (consent approved)");

    return "{\"status\":\"ok\",\"before\":" + beforeVal
        + ",\"after\":" + limitPercent
        + ",\"audit\":\"charge_limit_changed\"}";
  }

  private String readSysfs(String path) {
    try (BufferedReader br = new BufferedReader(new FileReader(path))) {
      return br.readLine();
    } catch (IOException e) {
      Log.w(TAG, "readSysfs failed: " + path + " — " + e.getMessage());
      return null;
    }
  }

  private boolean writeSysfs(String path, String value) {
    try (FileWriter fw = new FileWriter(path)) {
      fw.write(value);
      fw.flush();
      return true;
    } catch (IOException e) {
      Log.e(TAG, "writeSysfs failed: " + path + " — " + e.getMessage());
      return false;
    }
  }

  /**
   * Get time remaining until rate limit expires (in seconds).
   */
  public long getRateLimitRemaining() {
    long now = System.currentTimeMillis();
    long elapsed = now - mLastWriteTime;
    if (elapsed >= RATE_LIMIT_MS) return 0;
    return (RATE_LIMIT_MS - elapsed) / 1000;
  }
}
