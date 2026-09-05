# Consent UX Specification — Anti-Phishing Affordances

## Overview

Every MCP tool call that modifies system state (sysfs writes, system actions)
requires explicit human consent through the Apex Control consent card. The
consent UX is designed to make it easy to approve legitimate actions while
making phishing attempts (where injected content tricks the user into approving
malicious actions) difficult.

## Consent Flow

```
LLM generates tool call
  → PromptInjectionDetector.analyze()
    → RISK_CLEAN: proceed to consent
    → RISK_SUSPICIOUS: proceed to consent with warning badge
    → RISK_INJECTION: BLOCK, audit "blocked: injection detected"
  → ConsentGate.requestConsent()
    → Display consent card in Apex Control
    → User has 60 seconds to respond
    → Timeout → auto-deny + audit "denied by timeout"
  → User approves/denies
    → If approved: execute tool, verify effect, audit result
    → If denied: audit "denied by user"
```

## Consent Card Design (Anti-Phishing)

### Layout

```
┌─────────────────────────────────────────┐
│  ⚠ APEX Agent wants to:                 │
│                                         │
│  Set charge threshold to 80%            │
│                                         │
│  Tool: apex.charge                      │  ← monospace, fixed
│  Args: threshold=80                     │  ← monospace, fixed
│                                         │
│  [Approve]              [Deny]          │  ← equal weight
│                                         │
│  Auto-deny in: 47s                      │  ← countdown
└─────────────────────────────────────────┘
```

### Anti-Phishing Affordances

1. **Tool name in monospace**: The tool name is displayed in a fixed-width
   font, making it harder to spoof with visually similar characters
   (e.g., `apex.charge` vs `арех.сharge` with Cyrillic chars).

2. **Equal-weight buttons**: Approve and Deny buttons are the same size,
   same prominence, side by side. No default focus on Approve. The user
   must actively choose — no accidental approval by hitting Enter.

3. **Plain language description**: The agent must describe the action in
   plain language ("Set charge threshold to 80%"), not raw args. If the
   description doesn't match the tool/args, the user can spot the mismatch.

4. **60-second countdown**: Visible countdown timer creates urgency without
   panic. Timeout auto-denies — safer to do nothing than to approve
   something you didn't read.

5. **Warning badge for suspicious content**: When PromptInjectionDetector
   flags RISK_SUSPICIOUS, a yellow warning badge appears with the reason.
   The user sees "⚠ Suspicious content detected: base64_encoding" before
   the consent card.

6. **No inline content rendering**: Tool args are displayed as raw text,
   never rendered as HTML/markdown. No clickable links in the consent card.
   This prevents clickjacking and link spoofing.

7. **Audit trail reference**: Each consent card shows a short audit ID
   (first 8 chars of a UUID) so the user can cross-reference with the
   audit log viewer.

## State Machine

```
IDLE → PROCESSING → CONSENT_REQUESTED → APPROVED → EXECUTING → VERIFIED → DONE
                                  ↓
                              DENIED → DONE (audited)
                                  ↓
                              TIMEOUT → DONE (audited as "denied by timeout")

PROCESSING → ERROR (malformed LLM output, S2)
  → REPROMPT (retry 1) → REPROMPT (retry 2) → PLAIN_TEXT_FALLBACK → DONE
```

## Audit Log Entry

Each consent resolution produces an append-only audit entry:

| Field         | Example                          |
|---------------|----------------------------------|
| timestamp     | 2026-09-05T12:34:56Z             |
| tool_name     | apex.charge                      |
| description   | Set charge threshold to 80%      |
| action        | approved / denied / timeout      |
| result        | success / failed / not_executed  |
| duration_ms   | 1234                             |
| audit_id      | a1b2c3d4                         |

## Edge Cases

- **Multiple tool calls in one LLM response**: Each tool call gets its own
  consent card. No batch approval — each action is individually consented.
- **LLM generates no tool call**: No consent needed, response is plain text.
- **LLM output is malformed JSON (S2)**: Re-prompt with format fix, max 2
  retries. If still malformed, degrade to plain-text answer. No consent
  card shown — no tool to approve.
- **Injection detected (RISK_INJECTION)**: Tool call blocked, audit logged
  as "blocked: injection detected". User sees a warning, not a consent card.
- **Daemon crash during consent**: ConsentGate in system_server survives
  (process isolation). Pending consent requests timeout and auto-deny.
