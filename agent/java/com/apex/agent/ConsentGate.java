/*
 * ConsentGate.java
 *
 * Consent state machine for MCP tool calls.
 *
 * State flow: PENDING → APPROVED | DENIED | TIMEOUT
 *
 * - 60s timeout → auto-deny + audit "denied by timeout"
 * - Each tool call is consented individually (no batch approval)
 * - Uses CountDownLatch for synchronous consent flow
 *
 * Lives in system_server — survives daemon crashes.
 */

package com.apex.agent;

import android.util.Log;

import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public class ConsentGate {
  private static final String TAG = "ApexConsentGate";
  private static final long DEFAULT_TIMEOUT_MS = 60_000;

  public enum ConsentState {
    PENDING,
    APPROVED,
    DENIED,
    TIMEOUT
  }

  public static class ConsentRequest {
    public final String requestId;
    public final String toolName;
    public final String description;
    public final String action;
    public final long createdAtMs;

    public ConsentRequest(String requestId, String toolName,
                          String description, String action) {
      this.requestId = requestId;
      this.toolName = toolName;
      this.description = description;
      this.action = action;
      this.createdAtMs = System.currentTimeMillis();
    }
  }

  private static class PendingConsent {
    final ConsentRequest request;
    final CountDownLatch latch;
    final AtomicReference<ConsentState> state;

    PendingConsent(ConsentRequest request) {
      this.request = request;
      this.latch = new CountDownLatch(1);
      this.state = new AtomicReference<>(ConsentState.PENDING);
    }
  }

  private final ConcurrentHashMap<String, PendingConsent> mPending =
      new ConcurrentHashMap<>();
  private final HitlConsentStore mStore;

  public ConsentGate(HitlConsentStore store) {
    mStore = store;
  }

  /**
   * Request consent for a tool call. Returns a request ID that can be
   * used to resolve the consent later.
   */
  public String requestConsent(String toolName, String description, String action) {
    String requestId = UUID.randomUUID().toString();
    ConsentRequest request = new ConsentRequest(requestId, toolName, description, action);
    PendingConsent pending = new PendingConsent(request);
    mPending.put(requestId, pending);
    Log.i(TAG, "Consent requested: " + toolName + " (id=" + requestId + ")");
    return requestId;
  }

  /**
   * Get the current state of a consent request without blocking.
   */
  public ConsentState getConsentState(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return ConsentState.TIMEOUT;
    return pending.state.get();
  }

  /**
   * Block until a consent decision is made or timeout expires.
   */
  public ConsentState waitForDecision(String requestId, long timeout, TimeUnit unit) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return ConsentState.TIMEOUT;

    try {
      boolean decided = pending.latch.await(timeout, unit);
      if (!decided) {
        handleTimeout(requestId);
        return ConsentState.TIMEOUT;
      }
      return pending.state.get();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return ConsentState.TIMEOUT;
    }
  }

  /**
   * Approve a pending consent request.
   */
  public void approve(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return;
    long duration = System.currentTimeMillis() - pending.request.createdAtMs;
    pending.state.set(ConsentState.APPROVED);
    pending.latch.countDown();
    mStore.log(pending.request.toolName, pending.request.description,
        pending.request.action, "APPROVED", duration);
    mPending.remove(requestId);
    Log.i(TAG, "Consent approved: " + pending.request.toolName);
  }

  /**
   * Deny a pending consent request.
   */
  public void deny(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return;
    long duration = System.currentTimeMillis() - pending.request.createdAtMs;
    pending.state.set(ConsentState.DENIED);
    pending.latch.countDown();
    mStore.log(pending.request.toolName, pending.request.description,
        pending.request.action, "DENIED", duration);
    mPending.remove(requestId);
    Log.i(TAG, "Consent denied: " + pending.request.toolName);
  }

  /**
   * Handle timeout — auto-deny and audit.
   */
  public void handleTimeout(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return;
    long duration = System.currentTimeMillis() - pending.request.createdAtMs;
    pending.state.set(ConsentState.TIMEOUT);
    pending.latch.countDown();
    mStore.log(pending.request.toolName, pending.request.description,
        pending.request.action, "denied by timeout", duration);
    mPending.remove(requestId);
    Log.w(TAG, "Consent timeout: " + pending.request.toolName
        + " (60s elapsed, auto-denied)");
  }

  /**
   * Get the default timeout in milliseconds.
   */
  public long getDefaultTimeoutMs() {
    return DEFAULT_TIMEOUT_MS;
  }
}
