# Agent Security Controls

## Overview

The APEX agent implements defense-in-depth security controls to ensure that
on-device LLM inference can never compromise the system, leak data, or trick
the user into approving malicious actions.

## Security Layers

### S2: Malformed LLM Output Handling

LLM output is parsed as JSON for tool calls. If parsing fails:
1. Re-prompt the LLM with a format correction hint (retry 1)
2. Re-prompt again with a stricter format (retry 2)
3. If still malformed, degrade to plain-text response — no tool call executed

The agent never crashes on malformed output. The re-prompt counter is per
request and resets on each new user message.

**Implementation**: `ApexAgentDaemon.java` — `parseToolCall()` method,
`SecurityPolicy.getMaxRepromptRetries()` returns 2.

### S4: Untrusted Tool Inputs

Tool inputs from LLM output or app content are UNTRUSTED data. They are:
1. **Sanitized** by `UntrustedInputSanitizer` — shell metacharacters stripped,
   path traversal blocked, SQL injection escaped
2. **Scanned** by `PromptInjectionDetector` — role override patterns, hidden
   encodings (base64, unicode, zero-width), tool spoofing detected
3. **Classified** by `SecurityPolicy` — tool category determines consent and
   verification requirements
4. **Consent-gated** by `ConsentGate` — human approval required for all
   non-read-only tools

The agent must describe actions in plain language for consent and never
execute raw injected args.

**Implementation**: `UntrustedInputSanitizer.java`, `PromptInjectionDetector.java`,
`SecurityPolicy.java`, `ConsentGate.java`

### S5: Consent Gate

Every MCP tool call that modifies system state requires explicit human consent:
- 60-second timeout → auto-deny + audit "denied by timeout"
- Audit log is append-only, SELinux-protected, in SQLite (HitlConsentStore)
- Consent card displayed in Apex Control with anti-phishing affordances

See `ConsentUxSpec.md` for the full UX specification.

**Implementation**: `ConsentGate.java`, `HitlConsentStore.java`

### Tool-Effect Verification

After a sysfs write tool executes, `ToolEffectVerifier` reads back the
target path and confirms the value matches the expected result. If
verification fails, the tool reports failure — never claims success
without proof.

**Implementation**: `ToolEffectVerifier.java`

### Brick-Safety Enforcement

No tool, script, patch, or update path may ever write to:
- Bootloader, aboot, sbl, tz, hyp, modem partitions
- /dev/block/, /dev/by-name/, /dev/mem, /dev/kmem, /dev/port
- Partition tables, XBL, AOP, QUPV3, SHRM, CMNLIB

This is enforced by:
- `SecurityPolicy.isForbiddenPath()` — runtime check before any tool dispatch
- `UntrustedInputSanitizer.sanitizePath()` — path validation
- `tools/verify-brick-safety.sh` — grep-based repo-wide guard

### Process Isolation

- `apexagentd` runs as a separate process (not in system_server)
- `oom_score_adj = 900` — killable by LMKD before system_server
- LLM crash (segfault in llama.cpp) cannot take down system_server
- system_server hosts only the read-only MCP registry and consent store
- If daemon dies, fallback responds with "agent unavailable" + consent
  registry still functional

**Implementation**: `ApexAgentDaemon.java`, `LlmManagerService.java`,
`apex_agent.te` (SELinux domain isolation)

## File Inventory

| File | Purpose |
|------|---------|
| `UntrustedInputSanitizer.java` | Input sanitization (shell, path, SQL) |
| `PromptInjectionDetector.java` | Injection pattern detection + risk scoring |
| `ToolEffectVerifier.java` | Post-write sysfs/procfs verification |
| `SecurityPolicy.java` | Tool classification, forbidden paths, consent rules |
| `ConsentUxSpec.md` | Consent UX specification with anti-phishing design |
