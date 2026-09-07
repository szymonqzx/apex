# 21 — Testing

## Overview

APEX ROM has a Python test suite with 288 tests covering agent security, build certification, power-user features, and end-to-end agent flows. The tests run against the source code directly (no device required) and validate correctness, security, and completeness.

## Test Framework

- **Framework**: Python unittest (no external dependencies)
- **Location**: `tests/`
- **Run**: `python3 -m pytest tests/ -q`
- **Collection**: 288 tests collected in 0.2s
- **Runtime**: ~25s

## Test Modules

### tests/agent/ (Agent Tests)
| File | Tests | Coverage |
|------|-------|----------|
| `test_agent_aidl.py` | AIDL interface validation | Checks all AIDL files parse correctly, method signatures match |
| `test_agent_security.py` | Security policy enforcement | Brick safety, scope drift, forbidden paths, consent flow |
| `test_e2e_call_john.py` | End-to-end agent flow | Simulates "call John" → contacts tool → consent → execution |
| `test_power_user_features.py` | Power-user features | Governor tuning, thermal profile, bridge status |
| `test_vector_store.py` | Memory vector store | BM25 retrieval, storage, category filtering |

### tests/cert/ (Certification Tests)
| File | Tests | Coverage |
|------|-------|----------|
| `test_android_domain.py` | Android domain validation | Package names, AIDL packages, SELinux domains |
| `test_bridge_errors.py` | Bridge error handling | apex-bridge socket protocol error cases |
| `test_build_certification.py` | Build certification | APK existence, sizes, manifest validity |
| `test_cert_platform.py` | Platform certification | SDK levels, permissions, manifest flags |
| `test_charge_refs.py` | Charge control references | Sysfs paths, consent types, rate limiting |
| `test_check_configs.py` | Configuration checks | Defconfig values, build.prop entries, feature flags |
| `test_packaging_idempotent.py` | Packaging idempotency | Running package scripts twice produces same output |
| `test_wakelock_audit.py` | Wakelock audit | Protected wakelocks spared, safe wakelocks suppressed, unknown flagged |

## Current Test Results

```
288 tests collected
283 passed
3 failed
2 skipped
```

### Failures

1. **`test_verify_script_passes`** — `verify-brick-safety.sh` returns non-zero exit code. The script has a bug that causes it to fail even when checks pass. Needs fixing.

2. **`test_no_lindroid_in_agent`** — `McpRegistry.java` contains "lindroid" in MCP tool registrations. This is a **stale test** — the boil-the-sea plan explicitly adds Lindroid MCP tools in Phase 9. The test should be updated to allow Lindroid MCP tool registrations while still checking that the agent doesn't contain Lindroid *implementation* code (only Binder delegations).

3. **`test_no_wm_in_agent`** — `McpRegistry.java` contains "wm" in MCP tool registrations. Same issue as #2 — stale test that doesn't account for WM MCP tools added in Phase 7.

### Fixing the Stale Tests

The tests should be updated to:
- Allow `McpRegistry.java` to reference Lindroid and WM tool names (they're just string registrations)
- Still verify that `McpRegistry.java` doesn't contain implementation logic for WM or Lindroid (only Binder delegation calls)
- The distinction: `registerTool("apex-lindroid-start", ...)` is OK; `unshare --pid --net` in agent code is not

## Verification Scripts

In addition to the Python test suite, APEX has 5 shell verification scripts:

| Script | Lines | Checks | Status |
|--------|-------|--------|--------|
| `verify.sh` | 479 | Full ROM verification | Timeout (60s+) |
| `verify-rom.sh` | 310 | Flashable zip contents | 28 PASS, 0 WARN, 0 FAIL |
| `verify-brick-safety.sh` | 106 | Brick-safety scan | Failing (bug) |
| `verify-daily-driver.sh` | 145 | Daily-driver features | 33 PASS, 7 WARN, 0 FAIL |
| `verify-stealth.sh` | 163 | Hiding stack | 22 PASS, 8 WARN, 0 FAIL |

## Test Conventions

- Tests run against source files directly — no device needed
- Tests use `unittest.TestCase` with standard assertions
- Tests are organized by domain (agent/, cert/)
- Test file naming: `test_<domain>_<aspect>.py`
- Tests can be run individually: `python3 -m pytest tests/agent/test_agent_security.py -q`
- Tests can be filtered: `python3 -m pytest tests/ -k "brick" -q`

## CI Integration

The CI workflow (`.github/workflows/ci.yml`) runs:
1. `python3 -m pytest tests/ -q` — all tests
2. `shellcheck` on all shell scripts
3. `shfmt` formatting check
4. `verify-rom.sh` — ROM verification

CI fails if any test fails or any shellcheck error is found.
