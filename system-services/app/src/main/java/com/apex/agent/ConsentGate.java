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
  private static final long REMOTE_TIMEOUT_MS = 30_000;
  private static final long DUAL_CONFIRM_WINDOW_MS = 5_000;

  public enum ConsentState {
    PENDING,
    APPROVED,
    DENIED,
    TIMEOUT
  }

  public enum ConsentType {
    STANDARD,
    REMOTE_INFERENCE,
    DUAL_CONFIRM
  }

  public static class ConsentRequest {
    public final String requestId;
    public final String toolName;
    public final String description;
    public final String action;
    public final ConsentType consentType;
    public final long createdAtMs;

    public ConsentRequest(String requestId, String toolName,
                          String description, String action) {
      this(requestId, toolName, description, action, ConsentType.STANDARD);
    }

    public ConsentRequest(String requestId, String toolName,
                          String description, String action,
                          ConsentType consentType) {
      this.requestId = requestId;
      this.toolName = toolName;
      this.description = description;
      this.action = action;
      this.consentType = consentType;
      this.createdAtMs = System.currentTimeMillis();
    }
  }

  private static class PendingConsent {
    final ConsentRequest request;
    final CountDownLatch latch;
    final AtomicReference<ConsentState> state;
    volatile boolean physicalConfirmed;

    PendingConsent(ConsentRequest request) {
      this.request = request;
      this.latch = new CountDownLatch(1);
      this.state = new AtomicReference<>(ConsentState.PENDING);
      this.physicalConfirmed = false;
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
    return requestConsent(toolName, description, action, ConsentType.STANDARD);
  }

  /**
   * Request consent with a specific consent type.
   * REMOTE_INFERENCE: 30s timeout, warns "data leaves device".
   * DUAL_CONFIRM: requires on-screen approve + physical button press within 5s.
   */
  public String requestConsent(String toolName, String description, String action,
                                ConsentType consentType) {
    String requestId = UUID.randomUUID().toString();
    ConsentRequest request = new ConsentRequest(requestId, toolName, description,
        action, consentType);
    PendingConsent pending = new PendingConsent(request);
    mPending.put(requestId, pending);
    Log.i(TAG, "Consent requested: " + toolName + " type=" + consentType
        + " (id=" + requestId + ")");
    return requestId;
  }

  /**
   * Request remote inference consent — data leaves the device.
   * 30s timeout → auto-deny.
   */
  public String requestRemoteConsent(String toolName, String description, String action) {
    return requestConsent(toolName, description, action, ConsentType.REMOTE_INFERENCE);
  }

  /**
   * Request dual-confirmation consent — on-screen approve + physical button
   * (volume key) press within 5 seconds. Used for hardware writes like
   * charge control.
   */
  public String requestDualConfirmConsent(String toolName, String description,
                                           String action) {
    return requestConsent(toolName, description, action, ConsentType.DUAL_CONFIRM);
  }

  /**
   * Confirm the physical button press for a dual-confirm consent.
   * Must be called within DUAL_CONFIRM_WINDOW_MS after on-screen approve.
   * If the on-screen approve hasn't happened yet, the button press is
   * recorded and the next approve() call will complete the dual-confirm.
   */
  public boolean confirmPhysicalButton(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return false;
    if (pending.request.consentType != ConsentType.DUAL_CONFIRM) return false;

    long now = System.currentTimeMillis();
    long elapsed = now - pending.request.createdAtMs;

    if (pending.state.get() == ConsentState.APPROVED) {
      // On-screen already approved — physical press completes the dual-confirm
      // The approve() already set the state, this is the second confirmation
      Log.i(TAG, "Dual-confirm physical button pressed for " + pending.request.toolName);
      return true;
    } else if (pending.state.get() == ConsentState.PENDING) {
      // Physical press before on-screen approve — record it
      // The approve() call will check if physical was already pressed
      Log.i(TAG, "Dual-confirm physical button pre-pressed for " + pending.request.toolName);
      pending.physicalConfirmed = true;
      return true;
    }
    return false;
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
   * Uses the default timeout (60s for standard, 30s for remote inference).
   */
  public ConsentState waitForDecision(String requestId, long timeout, TimeUnit unit) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return ConsentState.TIMEOUT;

    // Use shorter timeout for remote inference
    long effectiveTimeout = timeout;
    if (pending.request.consentType == ConsentType.REMOTE_INFERENCE) {
      effectiveTimeout = Math.min(timeout, REMOTE_TIMEOUT_MS);
    }

    try {
      boolean decided = pending.latch.await(effectiveTimeout, unit);
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
   * Block until consent decision with the default timeout for the consent type.
   */
  public ConsentState waitForDecision(String requestId) {
    return waitForDecision(requestId, DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS);
  }

  /**
   * Approve a pending consent request.
   * For DUAL_CONFIRM: marks on-screen approved, but only completes if
   * physical button was already pressed (or waits for it within 5s).
   */
  public void approve(String requestId) {
    PendingConsent pending = mPending.get(requestId);
    if (pending == null) return;
    long duration = System.currentTimeMillis() - pending.request.createdAtMs;

    if (pending.request.consentType == ConsentType.DUAL_CONFIRM) {
      if (pending.physicalConfirmed) {
        // Physical button already pressed — complete the dual-confirm
        pending.state.set(ConsentState.APPROVED);
        pending.latch.countDown();
        mStore.log(pending.request.toolName, pending.request.description,
            pending.request.action, "APPROVED (dual-confirm)", duration);
        mPending.remove(requestId);
        Log.i(TAG, "Dual-confirm consent approved: " + pending.request.toolName);
      } else {
        // On-screen approved, waiting for physical button press
        // Set state to APPROVED but don't count down yet — the physical
        // button handler will complete the confirmation
        pending.state.set(ConsentState.APPROVED);
        Log.i(TAG, "Dual-confirm on-screen approved, waiting for button: "
            + pending.request.toolName);
        // Start a 5s timeout — if physical button not pressed, auto-deny
        new Thread(() -> {
          try {
            Thread.sleep(DUAL_CONFIRM_WINDOW_MS);
            if (mPending.containsKey(requestId)
                && pending.physicalConfirmed == false) {
              Log.w(TAG, "Dual-confirm physical button timeout: "
                  + pending.request.toolName);
              pending.state.set(ConsentState.DENIED);
              pending.latch.countDown();
              mStore.log(pending.request.toolName, pending.request.description,
                  pending.request.action, "DENIED (physical timeout)", duration);
              mPending.remove(requestId);
            }
          } catch (InterruptedException ignored) {
          }
        }).start();
      }
    } else {
      // Standard or REMOTE_INFERENCE — single approval
      pending.state.set(ConsentState.APPROVED);
      pending.latch.countDown();
      mStore.log(pending.request.toolName, pending.request.description,
          pending.request.action, "APPROVED", duration);
      mPending.remove(requestId);
      Log.i(TAG, "Consent approved: " + pending.request.toolName);
    }
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
