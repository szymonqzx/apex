# 07 — MCP Tools

## Overview

The APEX agent uses a Model Context Protocol (MCP) tool registry that lives in system_server. The daemon queries the registry via binder to discover available tools, their schemas, and whether they require consent. When the LLM generates a tool call, the daemon routes it through the security pipeline (injection detection → consent → execution → verification → audit).

## McpRegistry (385 lines)

Lives in system_server. Read-only snapshot of registered tools. Each tool has:
- **name**: unique identifier (e.g., `apex-charge-write`)
- **description**: human-readable description shown in consent card
- **schema**: JSON Schema for the tool's parameters
- **requiresConsent**: boolean — if true, goes through ConsentGate
- **executor**: function reference that executes the tool

## Registered Tools

### Read-Only Tools (no consent required)

| # | Tool | Description | Data Source |
|---|------|-------------|-------------|
| 1 | `contacts` | Read contact information from address book | Contacts Provider (READ_CONTACTS) |
| 2 | `apex-charge` | Read battery and charging status | `/sys/class/power_supply/battery/` |
| 3 | `apex-tune` | Read kernel tuning parameters | `/proc/apex/tune` |
| 4 | `apex-chroot` | Read Arch Linux chroot status | `/proc/mounts` (checks for `apex_rootfs`) |
| 5 | `apex-memory-store` | Store memory in persistent vector store | AgentVectorStore (SQLite) |
| 6 | `apex-memory-search` | Search agent memory (BM25) | AgentVectorStore (FTS5) |
| 7 | `apex-wm-list` | List all freeform windows | ApexWindowManager via binder |
| 8 | `apex-lindroid-start` | Start Linux container | LindroidManager via binder |
| 9 | `apex-lindroid-stop` | Stop Linux container | LindroidManager via binder |
| 10 | `apex-lindroid-exec` | Execute command in container | LindroidManager via binder |
| 11 | `apex-lindroid-install` | Install package in container | LindroidManager → `pacman -Sy` |
| 12 | `apex-lindroid-launch-app` | Launch Linux GUI app | LindroidManager → `DISPLAY=:0 app &` |

### Write Tools (consent required)

| # | Tool | Description | Consent Type | Target |
|---|------|-------------|-------------|--------|
| 13 | `apex-charge-write` | Set charge limit (20-100%) | DUAL_CONFIRM | `/sys/class/power_supply/battery/charge_control_limit_max` |
| 14 | `apex-wm-focus` | Focus a freeform window | STANDARD | ApexWindowManager via binder |
| 15 | `apex-desktop-start` | Start desktop mode (scrcpy) | STANDARD | DesktopModeService via binder |
| 16 | `apex-desktop-stop` | Stop desktop mode | STANDARD | DesktopModeService via binder |

## Tool Dispatch Flow

```
LLM generates tool call JSON
  → PromptInjectionDetector.analyze(llmOutput, toolName, toolArgs)
    → RISK_INJECTION: BLOCK, audit "blocked: injection detected"
    → RISK_SUSPICIOUS: warn + continue
    → RISK_CLEAN: continue
  → SecurityPolicy.classifyTool(toolName)
    → BLOCKED: reject
    → READ_ONLY: execute directly, no consent
    → SYSFS_WRITE / SYSTEM_ACTION: continue to consent
  → ConsentGate.requestConsent(toolName, description, action)
    → IApexToolCallback.onToolConsentRequested() → Apex Control UI
    → User approves / denies / 60s timeout auto-denies
  → If approved:
    → McpRegistry dispatches to tool executor
    → For sysfs writes: ToolEffectVerifier.verifySysfsWrite(path, expected)
    → HitlConsentStore.log(toolName, description, action, result, durationMs)
  → Tool result fed back to LLM for follow-up generation
```

## Tool Schemas

### contacts
```json
{
  "type": "object",
  "properties": {
    "query": {"type": "string", "description": "Name or phone number to search"}
  }
}
```

### apex-charge-write
```json
{
  "type": "object",
  "properties": {
    "limit": {"type": "integer", "description": "Charge limit percentage (20-100)"}
  },
  "required": ["limit"]
}
```

### apex-memory-store
```json
{
  "type": "object",
  "properties": {
    "content": {"type": "string", "description": "Memory content"},
    "category": {"type": "string", "description": "Memory category: preference, routine, conversation, context, fact"}
  },
  "required": ["content"]
}
```

### apex-wm-focus
```json
{
  "type": "object",
  "properties": {
    "windowId": {"type": "string", "description": "Window ID to focus"}
  },
  "required": ["windowId"]
}
```

## ChargeControlTool (153 lines)

The most security-sensitive tool. Implements E3 charge control with multiple safeguards:

### Safeguards
1. **Range validation**: limit must be 20-100, rejects anything else
2. **Rate limiting**: max 1 charge control change per 10 minutes
3. **No-op detection**: if already at target, returns without writing
4. **Dual-confirmation consent**: on-screen approve + physical volume key press within 5s
5. **Before/after audit**: reads current value before write, logs both in audit
6. **Effect verification**: reads back after write, confirms value matches
7. **Audit logging**: every attempt (approved, denied, timeout) is logged

### Write Path
```
/sys/class/power_supply/battery/charge_control_limit_max
```

This is the standard Android power_supply sysfs interface, supported by the APEX kernel's Qualcomm PMIC charger driver.

## Tool Extensibility

New tools can be added by:
1. Adding a `registerTool()` call in `McpRegistry` constructor
2. Implementing the executor method
3. If the tool writes to sysfs/procfs, add it to `SecurityPolicy.SYSFS_WRITE_TOOLS`
4. If the tool accesses sensitive paths, add path to `SecurityPolicy.FORBIDDEN_PATH_PREFIXES`
5. Write a test in `tests/agent/`

The registry uses `LinkedHashMap` to preserve insertion order, so tools appear in the same order they were registered.
