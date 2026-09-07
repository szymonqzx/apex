# 04 — Agent Security

## Overview

The APEX agent has a multi-layer security architecture designed to prevent prompt injection, enforce human consent on every state-modifying action, verify tool effects, and maintain an append-only audit trail. Every security control is implemented in Java and runs in system_server or the daemon process — there is no external dependency.

## Security Constraints (from DESIGN.md)

| ID | Constraint | Implementation |
|----|-----------|----------------|
| S2 | Malformed LLM output → re-prompt, max 2 retries → degrade to text | SecurityPolicy.MAX_REPROMPT_RETRIES = 2 |
| S4 | Tool inputs from app content are untrusted data | UntrustedInputSanitizer |
| S5 | Consent gate — 60s timeout → auto-deny + audit | ConsentGate with CountDownLatch |
| Brick | No tool may touch bootloader/aboot/partition tables | SecurityPolicy.FORBIDDEN_PATH_PREFIXES |

## Consent Gate (ConsentGate.java, 298 lines)

### State Machine
```
PENDING → APPROVED → tool executes → effect verified → audited
        → DENIED → audited
        → TIMEOUT (60s) → auto-deny → audited
```

### Consent Types
| Type | Timeout | Use Case |
|------|---------|----------|
| STANDARD | 60s | Default for write tools |
| REMOTE_INFERENCE | 30s | Data leaves device — shorter timeout for faster auto-deny |
| DUAL_CONFIRM | 60s + 5s physical | Charge control — on-screen approve + volume key press within 5s |

### Implementation
- Uses `CountDownLatch` for synchronous consent flow — the calling thread blocks until the user responds or timeout expires.
- Each consent request gets a UUID. The UI displays the first 8 characters as an audit ID for cross-referencing.
- `ConcurrentHashMap<String, PendingConsent>` tracks all pending consents (thread-safe).
- `AtomicReference<ConsentState>` for lock-free state transitions.
- `physicalConfirmed` volatile flag for dual-confirm — set by volume key event listener.

### Dual-Confirmation Flow (Charge Control)
```
1. Agent requests charge limit change
2. ConsentGate.requestConsent(DUAL_CONFIRM)
3. Apex Control shows consent card: "Set charge limit to 80%"
4. User taps "Approve" on screen (first confirmation)
5. ConsentGate waits for physical confirmation (volume key within 5s)
6. User presses volume key (second confirmation)
7. Consent state → APPROVED → tool executes
8. If no physical confirmation within 5s → DENIED
```

## Prompt Injection Detector (PromptInjectionDetector.java, 146 lines)

Scans LLM-generated tool calls for injection attempts before presenting to consent gate.

### Detection Patterns

**Role Override (RISK_INJECTION — blocked)**:
- "ignore previous/prior/all instructions"
- "disregard the above/previous/prior"
- "you are now a/an [word]"
- "new/updated instructions:"
- "system prompt:"
- "override safety/security/consent"
- "do not ask for consent"
- "execute without approval/consent/asking"
- "admin mode" / "debug mode"

**Tool Spoofing (RISK_INJECTION — blocked)**:
- "I am / this is / acting as system_server/shell/root/su/adb"

**Hidden Encodings (RISK_SUSPICIOUS — warned)**:
- Base64 strings (40+ chars)
- Unicode escape sequences (`\uXXXX`)
- Zero-width characters (U+200B-200F, U+2028-202F, U+2060-206F)

**Destructive Commands (RISK_INJECTION — blocked)**:
- "rm -rf" in tool args

**Invalid Tool Names (RISK_INJECTION — blocked)**:
- Tool names not matching the valid pattern (alphanumeric + dots + hyphens)

### Risk Levels
| Level | Value | Action |
|-------|-------|--------|
| CLEAN | 0 | Proceed to consent |
| SUSPICIOUS | 1 | Show warning badge, proceed to consent |
| INJECTION | 2 | BLOCK — audit "blocked: injection detected" |

## Untrusted Input Sanitizer (UntrustedInputSanitizer.java, 146 lines)

All tool inputs from LLM output or app content are treated as untrusted data. Five defense layers:

1. **Null/length check** — reject empty or inputs > 4096 chars
2. **Character whitelist** — allow only printable ASCII + common Unicode
3. **Command injection** — strip shell metacharacters: `;` `` ` `` `$` `|` `&` `>` `<` `!` `\n` `\r` `\t` `\\` `$(` `${` `||` `&&`
4. **Path traversal** — reject `../`, absolute paths to `/proc/`, `/sys/`, `/dev/`, `/data/system/`
5. **SQL injection** — escape single quotes, strip SQL keywords (DROP, DELETE, INSERT, UPDATE, CREATE, ALTER, EXEC)

### Sensitive Path Blocklist
The sanitizer rejects any path containing:
```
/dev/block/  /dev/by-name/  /bootloader  /aboot  /sbl  /tz  /hyp
/modem  /persist  /frp  /misc  /metadata  /xbl  /aop  /qupv3  /shrm
/cmnlib  /dev/mem  /dev/kmem  /dev/port
```

## Tool Effect Verifier (ToolEffectVerifier.java, 129 lines)

After a tool writes to sysfs/procfs, the verifier reads the value back and confirms it matches the expected result. If verification fails, the tool reports failure — **never claims success without proof**.

### Methods
- `verifySysfsWrite(path, expected)` — string comparison (trimmed)
- `verifySysfsInt(path, expected)` — integer comparison
- `verifySysfsBool(path, expected)` — boolean (1/0) comparison

### Security
- Only allows reads from `/sys/` and `/proc/` — never `/dev/` or other paths
- Returns `VerificationResult` with success boolean, actual value, expected value, and path
- The audit log records what actually happened, not what was attempted

## Security Policy (SecurityPolicy.java, 176 lines)

Central policy enforcement referenced before any tool dispatch.

### Tool Categories
| Category | Tools | Consent Required | Effect Verification |
|----------|-------|-----------------|---------------------|
| READ_ONLY | contacts.lookup, contacts.list, apex.status, apex.battery, apex.thermal | No | N/A |
| SYSFS_WRITE | apex.charge, apex.tune, apex.kcal | Yes (STANDARD) | Yes |
| SYSTEM_ACTION | apex.chroot.start, apex.chroot.stop | Yes (STANDARD) | N/A |
| BLOCKED | anything not in the above sets | N/A | N/A |

### Forbidden Path Prefixes
```
/dev/block/  /dev/by-name/  /bootloader  /aboot  /sbl  /tz  /hyp
/modem  /persist  /frp  /misc  /metadata  /xbl  /aop  /qupv3  /shrm
/cmnlib  /dev/mem  /dev/kmem  /dev/port
```

Any tool call that attempts to write to these paths is blocked before consent is even requested.

## Consent UX Specification

### Consent Card Layout
```
┌─────────────────────────────────────────┐
│  ⚠ APEX Agent wants to:                 │
│                                         │
│  Set charge threshold to 80%            │
│                                         │
│  Tool: apex.charge                      │  ← monospace
│  Args: threshold=80                     │  ← monospace
│                                         │
│  [Approve]              [Deny]          │  ← equal weight
│                                         │
│  Auto-deny in: 47s                      │  ← countdown
└─────────────────────────────────────────┘
```

### Anti-Phishing Affordances
1. **Tool name in monospace** — prevents Cyrillic homoglyph spoofing
2. **Equal-weight buttons** — no default focus on Approve, user must actively choose
3. **Plain language description** — agent describes action in human terms, not raw args
4. **60-second countdown** — visible timer, timeout auto-denies (safer to do nothing)
5. **Warning badge for suspicious content** — yellow badge with reason when RISK_SUSPICIOUS
6. **No inline content rendering** — tool args shown as raw text, no HTML/markdown, no clickable links
7. **Audit trail reference** — first 8 chars of UUID shown for cross-referencing

### Full State Machine
```
IDLE → PROCESSING → CONSENT_REQUESTED → APPROVED → EXECUTING → VERIFIED → DONE
                                  ↓
                              DENIED → DONE (audited)
                                  ↓
                              TIMEOUT → DONE (audited as "denied by timeout")

PROCESSING → ERROR (malformed LLM output, S2)
  → REPROMPT (retry 1) → REPROMPT (retry 2) → PLAIN_TEXT_FALLBACK → DONE
```

## Audit Log (HitlConsentStore.java, 178 lines)

### Schema
```sql
CREATE TABLE consent_audit (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT NOT NULL,      -- ISO 8601
    tool_name   TEXT NOT NULL,
    description TEXT,
    action      TEXT,
    result      TEXT NOT NULL,      -- approved / denied / timeout / blocked
    duration_ms INTEGER
);
```

### Properties
- **Append-only** — no delete or update operations exposed
- **SQLite** at `/data/system/apex/consent_audit.db`
- **SELinux-protected** — only system_server (apex_agent domain) can read/write
- **Queryable** — `queryRecent(limit)` and `queryByTool(toolName)` methods
- **Viewable** — Apex Control's AuditLogViewer screen displays entries

## Debug Log (AgentDebugLog.java, 170 lines)

Separate from the consent audit log. Captures internal agent diagnostics.

### Format
```
TIMESTAMP LEVEL COMPONENT MESSAGE [key=value ...]
```

### Log Levels
DEBUG, INFO, WARN, ERROR

### Components
llm, tool, consent, memory, voice, system

### Rotation
- Log file: `/data/system/apex/agent_debug.log`
- Max size: 5MB → rotates to `agent_debug.log.1`
- Max lines returned per query: 500
- Viewable from Apex Control via AgentDebugLogViewer composable
