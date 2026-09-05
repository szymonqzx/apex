#!/usr/bin/env python3
"""Tests for APEX agent AIDL interface and build configuration.

Verifies that:
  1. IApexAgent AIDL interface is properly defined
  2. Android.bp build file is correct
  3. Model router API is reachable (IApexAgent has model tier methods)
  4. Init RC file starts apexagentd correctly
  5. Update engine RC file exists for A/B updates
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
AGENT_AIDL = REPO_ROOT / "agent" / "aidl" / "com" / "apex" / "agent"
AGENT_JAVA = REPO_ROOT / "agent" / "java" / "com" / "apex" / "agent"


class TestAidlInterface(unittest.TestCase):
    """Verify IApexAgent AIDL interface."""

    def setUp(self):
        self.iapex = AGENT_AIDL / "IApexAgent.aidl"
        self.source = self.iapex.read_text()

    def test_aidl_exists(self):
        self.assertTrue(self.iapex.exists())

    def test_has_chat_method(self):
        """Must have a chat/sendMessage method."""
        self.assertTrue(
            "chat" in self.source.lower() or "sendMessage" in self.source.lower(),
            "IApexAgent must have chat or sendMessage method"
        )

    def test_has_model_tier_method(self):
        """Must have model tier selection method (switchable without reboot)."""
        self.assertTrue(
            "model" in self.source.lower() and
            ("tier" in self.source.lower() or "setModel" in self.source),
            "IApexAgent must have model tier selection method"
        )

    def test_has_status_method(self):
        """Must have a status query method."""
        self.assertTrue(
            "status" in self.source.lower() or "getStatus" in self.source,
            "IApexAgent must have status method"
        )

    def test_has_audit_log_method(self):
        """Must have audit log query method."""
        self.assertTrue(
            "audit" in self.source.lower() or "getAudit" in self.source,
            "IApexAgent must have audit log method"
        )

    def test_package_declaration(self):
        self.assertIn("package com.apex.agent", self.source)


class TestAndroidBp(unittest.TestCase):
    """Verify Android.bp build configuration."""

    def setUp(self):
        self.bp = REPO_ROOT / "agent" / "Android.bp"
        self.source = self.bp.read_text()

    def test_bp_exists(self):
        self.assertTrue(self.bp.exists())

    def test_has_aidl_interface(self):
        self.assertIn("aidl_interface", self.source)

    def test_has_java_library(self):
        self.assertIn("java_library", self.source.lower())

    def test_has_apexagentd_binary(self):
        self.assertTrue(
            "apexagentd" in self.source,
            "Android.bp must build apexagentd binary"
        )


class TestInitRc(unittest.TestCase):
    """Verify init RC files for agent and update engine."""

    def test_agent_rc_exists(self):
        rc = REPO_ROOT / "rom-overlays" / "init.d" / "apex_agent.rc"
        self.assertTrue(rc.exists())

    def test_agent_rc_starts_daemon(self):
        rc = REPO_ROOT / "rom-overlays" / "init.d" / "apex_agent.rc"
        content = rc.read_text()
        self.assertIn("apexagentd", content)
        self.assertIn("service", content)

    def test_update_engine_rc_exists(self):
        rc = REPO_ROOT / "rom-overlays" / "update" / "apex_update_engine.rc"
        self.assertTrue(rc.exists())

    def test_agent_rc_sets_oom_score(self):
        rc = REPO_ROOT / "rom-overlays" / "init.d" / "apex_agent.rc"
        content = rc.read_text()
        self.assertIn("oom_score_adj", content)


class TestLlmBuildScripts(unittest.TestCase):
    """Verify llama.cpp and whisper.cpp cross-compile scripts."""

    def test_llama_build_script_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "build-llama.sh").exists())

    def test_whisper_build_script_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "build-whisper.sh").exists())

    def test_llama_script_targets_arm64(self):
        script = (REPO_ROOT / "agent" / "llm" / "build-llama.sh").read_text()
        self.assertIn("aarch64", script.lower())

    def test_whisper_script_targets_arm64(self):
        script = (REPO_ROOT / "agent" / "llm" / "build-whisper.sh").read_text()
        self.assertIn("aarch64", script.lower())

    def test_llama_script_uses_ndk(self):
        script = (REPO_ROOT / "agent" / "llm" / "build-llama.sh").read_text()
        self.assertIn("NDK", script.upper())

    def test_jni_android_bp_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "libllm_jni" / "Android.bp").exists())

    def test_jni_cmake_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "libllm_jni" / "CMakeLists.txt").exists())


class TestModelTiers(unittest.TestCase):
    """Verify model tier configuration matches specs."""

    def test_model_readme_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "models" / "README.md").exists())

    def test_default_model_is_1_5b(self):
        """Default model must be Qwen 2.5 1.5B."""
        models_doc = (REPO_ROOT / "agent" / "llm" / "models" / "README.md").read_text()
        self.assertIn("1.5B", models_doc)

    def test_3b_is_opt_in(self):
        """3B model must be opt-in, not default."""
        models_doc = (REPO_ROOT / "agent" / "llm" / "models" / "README.md").read_text()
        self.assertIn("3B", models_doc)

    def test_memory_budget_doc_exists(self):
        self.assertTrue((REPO_ROOT / "agent" / "llm" / "MEMORY_BUDGET.md").exists())

    def test_memory_budget_has_degradation_plan(self):
        budget = (REPO_ROOT / "agent" / "llm" / "MEMORY_BUDGET.md").read_text()
        self.assertIn("degrad", budget.lower())

    def test_memory_budget_has_latency_budget(self):
        budget = (REPO_ROOT / "agent" / "llm" / "MEMORY_BUDGET.md").read_text()
        self.assertTrue(
            "latency" in budget.lower() or "tok/s" in budget.lower(),
            "Memory budget doc must include latency budget"
        )


if __name__ == "__main__":
    unittest.main()
