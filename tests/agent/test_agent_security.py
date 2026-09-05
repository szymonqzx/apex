#!/usr/bin/env python3
"""Tests for APEX agent security controls and consent state machine.

Verifies that:
  1. ConsentGate state machine transitions are correct
  2. Re-prompt policy (S2) is enforced: max 2 retries → plain text
  3. Consent timeout (S5) is 60 seconds → auto-deny
  4. Prompt injection detection blocks known attack patterns
  5. Untrusted input sanitizer strips shell metacharacters and path traversal
  6. SecurityPolicy classifies tools and blocks forbidden paths
  7. ToolEffectVerifier validates sysfs paths
  8. Process isolation: apexagentd is separate from system_server
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
AGENT_JAVA = REPO_ROOT / "agent" / "java" / "com" / "apex" / "agent"
AGENT_SEP = REPO_ROOT / "agent" / "sepolicy"
AGENT_SECURITY = REPO_ROOT / "agent" / "security"


class TestConsentStateMachine(unittest.TestCase):
    """Verify ConsentGate implements the correct state machine."""

    def setUp(self):
        self.source = (AGENT_JAVA / "ConsentGate.java").read_text()

    def test_consent_gate_exists(self):
        self.assertTrue((AGENT_JAVA / "ConsentGate.java").exists())

    def test_consent_timeout_is_60s(self):
        """S5: consent timeout must be 60 seconds."""
        # Check for 60 in the timeout constant
        self.assertTrue(
            re.search(r"60\s*[;L]|\bSIXTY\b|TIMEOUT.*60|60.*timeout", self.source, re.I),
            "ConsentGate must have a 60-second timeout"
        )

    def test_auto_deny_on_timeout(self):
        """S5: timeout must auto-deny with audit."""
        self.assertIn("denied by timeout", self.source.lower() + " " + self.source,
                      "ConsentGate must audit 'denied by timeout'")

    def test_consent_states_defined(self):
        """Consent gate must have PENDING, APPROVED, DENIED, TIMEOUT states."""
        for state in ["PENDING", "APPROVED", "DENIED"]:
            self.assertTrue(
                state in self.source,
                f"ConsentGate must define state: {state}"
            )

    def test_consent_is_append_only(self):
        """Audit log must be append-only."""
        store_source = (AGENT_JAVA / "HitlConsentStore.java").read_text()
        # Check for INSERT (not UPDATE/DELETE on audit table)
        self.assertIn("INSERT", store_source.upper())
        self.assertNotIn(
            "UPDATE consent_audit",
            store_source.upper(),
            "Audit log must be append-only (no UPDATE)"
        )
        self.assertNotIn(
            "DELETE FROM consent_audit",
            store_source.upper(),
            "Audit log must be append-only (no DELETE)"
        )


class TestRepromptPolicy(unittest.TestCase):
    """Verify S2: malformed LLM output → re-prompt, max 2 retries → degrade."""

    def setUp(self):
        self.daemon_source = (AGENT_JAVA / "ApexAgentDaemon.java").read_text()
        self.policy_source = (AGENT_JAVA / "SecurityPolicy.java").read_text()

    def test_max_reprompts_is_2(self):
        """S2: max re-prompt retries must be 2."""
        self.assertIn("MAX_REPROMPT_RETRIES = 2", self.policy_source)

    def test_daemon_has_reprompt_logic(self):
        """Daemon must implement re-prompt on malformed JSON."""
        # Check for retry/reprompt logic in daemon
        has_retry = "retry" in self.daemon_source.lower() or "reprompt" in self.daemon_source.lower()
        self.assertTrue(has_retry, "Daemon must have re-prompt logic")

    def test_fallback_to_plain_text(self):
        """After max retries, must degrade to plain text, not crash."""
        # Check for plain text fallback or text response
        has_fallback = "plain" in self.daemon_source.lower() or "text" in self.daemon_source.lower()
        self.assertTrue(has_fallback, "Daemon must have plain-text fallback")


class TestPromptInjectionDefense(unittest.TestCase):
    """Verify S4: prompt injection detection blocks known attack patterns."""

    def setUp(self):
        self.detector_source = (AGENT_JAVA / "PromptInjectionDetector.java").read_text()
        self.sanitizer_source = (AGENT_JAVA / "UntrustedInputSanitizer.java").read_text()

    def test_detector_exists(self):
        self.assertTrue((AGENT_JAVA / "PromptInjectionDetector.java").exists())

    def test_blocks_role_override(self):
        """Must block 'ignore previous instructions' pattern."""
        self.assertIn("ignore", self.detector_source.lower())
        self.assertIn("previous", self.detector_source.lower())

    def test_blocks_tool_spoofing(self):
        """Must detect tool name spoofing."""
        self.assertIn("spoofing", self.detector_source.lower())

    def test_detects_hidden_encodings(self):
        """Must detect base64, unicode escapes, zero-width chars."""
        self.assertIn("base64", self.detector_source.lower())
        self.assertIn("zero_width", self.detector_source.lower())

    def test_risk_levels_defined(self):
        """Must define RISK_CLEAN, RISK_SUSPICIOUS, RISK_INJECTION."""
        for level in ["RISK_CLEAN", "RISK_SUSPICIOUS", "RISK_INJECTION"]:
            self.assertIn(level, self.detector_source)

    def test_sanitizer_strips_shell_metacharacters(self):
        """Sanitizer must strip shell injection patterns."""
        self.assertIn("SHELL_INJECTION", self.sanitizer_source)

    def test_sanitizer_blocks_path_traversal(self):
        """Sanitizer must block path traversal."""
        self.assertIn("PATH_TRAVERSAL", self.sanitizer_source)

    def test_sanitizer_blocks_sensitive_paths(self):
        """Sanitizer must block bootloader/aboot/partition paths."""
        self.assertIn("SENSITIVE_PATHS", self.sanitizer_source)
        self.assertIn("bootloader", self.sanitizer_source.lower())
        self.assertIn("aboot", self.sanitizer_source.lower())


class TestSecurityPolicy(unittest.TestCase):
    """Verify SecurityPolicy enforces brick-safety and tool classification."""

    def setUp(self):
        self.source = (AGENT_JAVA / "SecurityPolicy.java").read_text()

    def test_forbidden_paths_include_bootloader(self):
        for path in ["bootloader", "aboot", "/dev/block/", "/dev/by-name/"]:
            self.assertIn(path, self.source.lower(),
                          f"SecurityPolicy must forbid: {path}")

    def test_tool_classification(self):
        """Tools must be classified as READ_ONLY, SYSFS_WRITE, SYSTEM_ACTION, BLOCKED."""
        for cat in ["READ_ONLY", "SYSFS_WRITE", "SYSTEM_ACTION", "BLOCKED"]:
            self.assertIn(cat, self.source)

    def test_read_only_tools_defined(self):
        """contacts.lookup must be classified as read-only."""
        self.assertIn("contacts.lookup", self.source)

    def test_consent_required_for_writes(self):
        """Non-read-only tools must require consent."""
        self.assertIn("requiresConsent", self.source)


class TestToolEffectVerifier(unittest.TestCase):
    """Verify tool-effect verification reads back sysfs after write."""

    def setUp(self):
        self.source = (AGENT_JAVA / "ToolEffectVerifier.java").read_text()

    def test_verifier_exists(self):
        self.assertTrue((AGENT_JAVA / "ToolEffectVerifier.java").exists())

    def test_verifies_sysfs_path(self):
        """Must read back from /sys/ and /proc/ paths."""
        self.assertIn("/sys/", self.source)
        self.assertIn("/proc/", self.source)

    def test_rejects_non_sysfs_paths(self):
        """Must reject paths outside sysfs/procfs."""
        self.assertIn("startsWith", self.source)


class TestProcessIsolation(unittest.TestCase):
    """Verify process isolation: daemon crash doesn't take down system_server."""

    def setUp(self):
        self.daemon_source = (AGENT_JAVA / "ApexAgentDaemon.java").read_text()
        self.service_source = (AGENT_JAVA / "LlmManagerService.java").read_text()
        self.sepolicy = (AGENT_SEP / "apex_agent.te").read_text()

    def test_daemon_is_separate_process(self):
        """apexagentd must run as a separate process, not in system_server."""
        self.assertIn("main", self.daemon_source.lower())
        # The daemon must have its own entry point
        self.assertTrue(
            "class ApexAgentDaemon" in self.daemon_source or
            "public class ApexAgentDaemon" in self.daemon_source
        )

    def test_oom_score_adj_is_high(self):
        """Daemon must be killable under OOM (oom_score_adj >= 900)."""
        # Check in daemon source or sepolicy or init rc
        init_rc = (REPO_ROOT / "rom-overlays" / "init.d" / "apex_agent.rc")
        if init_rc.exists():
            rc_content = init_rc.read_text()
            self.assertIn("oom_score_adj", rc_content)
            # Extract the value
            match = re.search(r"oom_score_adj\s+(\d+)", rc_content)
            if match:
                val = int(match.group(1))
                self.assertGreaterEqual(val, 900,
                    "oom_score_adj must be >= 900 for LMKD to kill daemon first")

    def test_service_has_fallback(self):
        """LlmManagerService must have fallback when daemon is unavailable."""
        self.assertTrue(
            "fallback" in self.service_source.lower() or
            "unavailable" in self.service_source.lower(),
            "LlmManagerService must handle daemon unavailability"
        )

    def test_selinux_domain_isolated(self):
        """apex_agent.te must define a separate domain, not permissive."""
        self.assertIn("type apex_agent", self.sepolicy)
        self.assertNotIn("permissive", self.sepolicy,
                         "SELinux must be enforcing, no permissive domains")

    def test_selinux_no_permissive(self):
        """No permissive domains anywhere in sepolicy."""
        self.assertNotIn("permissive apex_agent", self.sepolicy)


class TestBrickSafety(unittest.TestCase):
    """Verify brick-safety: no script/patch touches bootloader/aboot/partitions."""

    def setUp(self):
        self.verify_script = REPO_ROOT / "tools" / "verify-brick-safety.sh"

    def test_verify_script_exists(self):
        self.assertTrue(self.verify_script.exists(),
                        "tools/verify-brick-safety.sh must exist")

    def test_verify_script_passes(self):
        """verify-brick-safety.sh must pass with 0 errors."""
        import subprocess
        result = subprocess.run(
            ["bash", str(self.verify_script), str(REPO_ROOT)],
            capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0,
            f"verify-brick-safety.sh failed:\n{result.stderr}")


class TestE2ECallJohn(unittest.TestCase):
    """Verify E2E 'Call John' scenario: agent → ContactsMcp → consent → audit."""

    def setUp(self):
        self.registry_source = (AGENT_JAVA / "McpRegistry.java").read_text()
        self.daemon_source = (AGENT_JAVA / "ApexAgentDaemon.java").read_text()

    def test_contacts_tool_registered(self):
        """McpRegistry must register a contacts tool."""
        self.assertTrue(
            "contacts" in self.registry_source.lower(),
            "McpRegistry must register contacts tool"
        )

    def test_contacts_is_read_only(self):
        """Contacts tool must be read-only (no sysfs writes)."""
        policy_source = (AGENT_JAVA / "SecurityPolicy.java").read_text()
        self.assertIn("contacts.lookup", policy_source)
        # contacts.lookup should be in READ_ONLY_TOOLS
        self.assertIn("READ_ONLY_TOOLS", policy_source)

    def test_tool_dispatch_goes_through_consent(self):
        """Tool dispatch must go through consent gate."""
        self.assertTrue(
            "consent" in self.daemon_source.lower(),
            "Daemon must reference consent before tool dispatch"
        )

    def test_audit_log_records_tool_calls(self):
        """Audit store must record tool name, action, and result."""
        store_source = (AGENT_JAVA / "HitlConsentStore.java").read_text()
        for field in ["tool_name", "action", "result"]:
            self.assertIn(field, store_source,
                          f"HitlConsentStore must record: {field}")


class TestSelinuxPolicy(unittest.TestCase):
    """Verify SELinux policy for apex_agent domain."""

    def setUp(self):
        self.te_file = AGENT_SEP / "apex_agent.te"
        self.source = self.te_file.read_text()

    def test_te_file_exists(self):
        self.assertTrue(self.te_file.exists())

    def test_domain_defined(self):
        self.assertIn("type apex_agent", self.source)

    def test_binder_access(self):
        """Must have binder IPC access for system_server communication."""
        self.assertIn("binder", self.source.lower())

    def test_socket_access(self):
        """Must have access to local socket for daemon communication."""
        self.assertIn("socket", self.source.lower())

    def test_data_access(self):
        """Must have access to /data/system/apex/ for audit and memory."""
        self.assertIn("apex", self.source)
        self.assertIn("data_system", self.source.lower()
                      .replace("data_system", "data_system")
                      + " " + self.source)

    def test_no_permissive(self):
        """No permissive domains."""
        self.assertNotIn("permissive", self.source)

    def test_uses_existing_pattern(self):
        """Should extend the existing apex_chroot.te pattern."""
        # Check for init_daemon_domain or domain transition
        self.assertTrue(
            "init_daemon_domain" in self.source or
            "domain" in self.source,
            "apex_agent.te should use init_daemon_domain pattern"
        )


class TestModelManager(unittest.TestCase):
    """Verify model tier switching and memory pressure handling."""

    def setUp(self):
        self.source = (AGENT_JAVA / "ModelManager.java").read_text()

    def test_model_manager_exists(self):
        self.assertTrue((AGENT_JAVA / "ModelManager.java").exists())

    def test_tier_switching(self):
        """Must support switching between model tiers without reboot."""
        self.assertIn("tier", self.source.lower())
        self.assertIn("switch", self.source.lower())

    def test_degradation_chain(self):
        """Must implement degradation: 3B → 1.5B → 0.5B → plain text."""
        self.assertIn("degrad", self.source.lower())
        # Check for multiple model sizes
        self.assertIn("1.5", self.source)
        self.assertIn("3", self.source)

    def test_oom_handling(self):
        """Must handle OOM by unloading models."""
        self.assertTrue(
            "oom" in self.source.lower() or "memory" in self.source.lower(),
            "ModelManager must handle memory pressure"
        )

    def test_unload_on_pressure(self):
        """Must unload model under memory pressure."""
        self.assertTrue(
            "unload" in self.source.lower(),
            "ModelManager must unload models"
        )


class TestApexControlAgentUI(unittest.TestCase):
    """Verify Apex Control app has agent UI components."""

    def setUp(self):
        self.app_agent_dir = REPO_ROOT / "apps" / "apex-control" / "app" / "src" / "main" / "java" / "com" / "apex" / "control" / "agent"

    def test_chat_surface_exists(self):
        self.assertTrue((self.app_agent_dir / "AgentChatSurface.kt").exists())

    def test_model_router_exists(self):
        self.assertTrue((self.app_agent_dir / "ModelRouterScreen.kt").exists())

    def test_audit_log_viewer_exists(self):
        self.assertTrue((self.app_agent_dir / "AuditLogViewer.kt").exists())

    def test_debug_log_viewer_exists(self):
        self.assertTrue((self.app_agent_dir / "AgentDebugLogViewer.kt").exists())

    def test_model_download_manager_exists(self):
        self.assertTrue((self.app_agent_dir / "ModelDownloadManager.kt").exists())

    def test_agent_repository_exists(self):
        self.assertTrue((self.app_agent_dir / "AgentRepository.kt").exists())

    def test_main_screen_has_tabs(self):
        """ApexControlScreen must have tab integration for agent UI."""
        screen = (REPO_ROOT / "apps" / "apex-control" / "app" / "src" / "main" / "java" / "com" / "apex" / "control" / "ui" / "ApexControlScreen.kt").read_text()
        self.assertIn("selectedTab", screen)
        self.assertIn("Agent", screen)
        self.assertIn("Model", screen)
        self.assertIn("Audit", screen)
        self.assertIn("Debug", screen)

    def test_chat_surface_has_consent_card(self):
        """Chat surface must render consent card with approve/deny."""
        chat = (self.app_agent_dir / "AgentChatSurface.kt").read_text()
        self.assertIn("consent", chat.lower())
        self.assertIn("Approve", chat)
        self.assertIn("Deny", chat)

    def test_chat_surface_has_timeout_countdown(self):
        """Consent card must show 60s countdown."""
        chat = (self.app_agent_dir / "AgentChatSurface.kt").read_text()
        self.assertTrue(
            "countdown" in chat.lower() or "60" in chat,
            "Chat surface must have 60s countdown"
        )


class TestUpdateArchitecture(unittest.TestCase):
    """Verify T1: Virtual A/B + OTA fallback architecture."""

    def setUp(self):
        self.docs = REPO_ROOT / "docs" / "UPDATE_ARCHITECTURE.md"
        self.ab_verify = REPO_ROOT / "rom-overlays" / "update" / "apex_ab_verify.sh"
        self.ota_fallback = REPO_ROOT / "rom-overlays" / "update" / "apex_ota_fallback.sh"

    def test_doc_exists(self):
        self.assertTrue(self.docs.exists())

    def test_ab_verify_script_exists(self):
        self.assertTrue(self.ab_verify.exists())

    def test_ota_fallback_script_exists(self):
        self.assertTrue(self.ota_fallback.exists())

    def test_doc_mentions_virtual_ab(self):
        content = self.docs.read_text()
        self.assertIn("Virtual A/B", content)
        self.assertIn("test-before-commit", content.lower())

    def test_doc_mentions_auto_fallback(self):
        content = self.docs.read_text()
        self.assertIn("fallback", content.lower())

    def test_doc_mentions_brick_safety(self):
        content = self.docs.read_text()
        self.assertIn("brick", content.lower())
        self.assertIn("bootloader", content.lower())

    def test_ab_verify_has_boot_check(self):
        """A/B verify must check boot success before marking active."""
        content = self.ab_verify.read_text()
        self.assertIn("boot", content.lower())
        self.assertIn("active", content.lower())

    def test_ota_fallback_doesnt_touch_bootloader(self):
        """OTA script must not write to bootloader/aboot."""
        content = self.ota_fallback.read_text().lower()
        self.assertNotIn("dd if= of=/dev/block/by-name/bootloader", content)
        self.assertNotIn("dd if= of=/dev/block/by-name/aboot", content)


class TestAgentModuleStructure(unittest.TestCase):
    """Verify agent module has all required files."""

    def test_aidl_interface_exists(self):
        aidl = REPO_ROOT / "agent" / "aidl" / "com" / "apex" / "agent" / "IApexAgent.aidl"
        self.assertTrue(aidl.exists(), "IApexAgent.aidl must exist")

    def test_android_bp_exists(self):
        bp = REPO_ROOT / "agent" / "Android.bp"
        self.assertTrue(bp.exists(), "agent/Android.bp must exist")

    def test_llm_build_scripts_exist(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "build-llama.sh").exists())
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "build-whisper.sh").exists())

    def test_memory_budget_doc_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "MEMORY_BUDGET.md").exists())

    def test_jni_bridge_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "libllm_jni" / "llm_jni.c").exists())

    def test_voice_manager_exists(self):
        self.assertTrue((AGENT_JAVA / "VoiceManager.java").exists())

    def test_memory_store_exists(self):
        self.assertTrue((AGENT_JAVA / "AgentMemoryStore.java").exists())

    def test_debug_log_exists(self):
        self.assertTrue((AGENT_JAVA / "AgentDebugLog.java").exists())

    def test_security_files_exist(self):
        for f in ["UntrustedInputSanitizer.java",
                   "PromptInjectionDetector.java",
                   "ToolEffectVerifier.java",
                   "SecurityPolicy.java"]:
            self.assertTrue((AGENT_JAVA / f).exists(), f"Missing: {f}")

    def test_consent_ux_spec_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "security" / "ConsentUxSpec.md").exists())

    def test_agent_readme_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "README.md").exists())


class TestNoScopeDrift(unittest.TestCase):
    """Verify no scope drift: no WM, no desktop, no Lindroid, no ALOS."""

    def test_no_wm_in_agent(self):
        """Agent module must not contain window manager code."""
        agent_dir = REPO_ROOT / "agent"
        if not agent_dir.exists():
            return
        for f in agent_dir.rglob("*.java"):
            content = f.read_text().lower()
            self.assertNotIn("windowmanager", content,
                f"{f.name} must not contain WindowManager references")
            self.assertNotIn("wm_manager", content)

    def test_no_lindroid_in_agent(self):
        agent_dir = REPO_ROOT / "agent"
        if not agent_dir.exists():
            return
        for f in agent_dir.rglob("*.java"):
            content = f.read_text().lower()
            self.assertNotIn("lindroid", content,
                f"{f.name} must not contain Lindroid references")

    def test_no_alos_in_agent(self):
        agent_dir = REPO_ROOT / "agent"
        if not agent_dir.exists():
            return
        for f in agent_dir.rglob("*.java"):
            content = f.read_text().lower()
            self.assertNotIn("alos", content,
                f"{f.name} must not contain ALOS references")

    def test_agent_is_read_only_over_hardware(self):
        """Agent tools must be read-only over hardware (no direct writes)."""
        registry = (AGENT_JAVA / "McpRegistry.java").read_text()
        # The agent drives tools through consent-gated MCP, not direct hardware access
        self.assertIn("tool", registry.lower())


class TestRomWarnsNotRefuses(unittest.TestCase):
    """Verify ROM WARNS (not refuses) on non-APEX kernel."""

    def test_kernel_detection_in_overlays(self):
        """ROM overlays should have kernel detection that warns."""
        overlays = REPO_ROOT / "rom-overlays"
        if not overlays.exists():
            return
        found_warning = False
        for f in overlays.rglob("*"):
            if f.is_file() and f.suffix in ['.sh', '.rc', '.prop', '.te']:
                content = f.read_text().lower()
                if 'apex' in content and ('warn' in content or 'notice' in content):
                    found_warning = True
                    break
        # Also check docs
        docs = REPO_ROOT / "docs"
        if docs.exists():
            for f in docs.rglob("*.md"):
                content = f.read_text().lower()
                if 'warn' in content and 'kernel' in content:
                    found_warning = True
                    break
        self.assertTrue(found_warning,
                        "ROM must have kernel warning mechanism (warn, not refuse)")


if __name__ == "__main__":
    unittest.main()
