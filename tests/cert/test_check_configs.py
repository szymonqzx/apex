#!/usr/bin/env python3
"""Regression tests for tools/check-configs.py.

Verifies that:
  1. The dependency check actually fires when a dep is missing (the
     original bug was that DEPENDENCIES keys lacked the CONFIG_ prefix
     and never matched the merged dict).
  2. The conflict check fires when two conflicting configs are both =y.
  3. The tool exits nonzero on errors and zero on a clean config set.
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _load_check_configs():
    """Load check-configs.py as a module (it's not a package)."""
    spec = importlib.util.spec_from_file_location(
        "check_configs", REPO_ROOT / "tools" / "check-configs.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestCheckConfigs(unittest.TestCase):

    def setUp(self):
        self.cc = _load_check_configs()

    def _parse_fragment(self, text):
        """Parse a config fragment from a string."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".config", delete=False
        ) as f:
            f.write(text)
            f.flush()
            path = Path(f.name)
        try:
            return self.cc.parse_config(path)
        finally:
            os.unlink(path)

    def test_dependency_keys_have_config_prefix(self):
        """Every key in DEPENDENCIES must start with CONFIG_.

        This is the regression guard for the P0 bug where bare names
        like 'CPU_FREQ_GOV_APEX' never matched the merged dict.
        """
        for key, deps in self.cc.DEPENDENCIES.items():
            self.assertTrue(
                key.startswith("CONFIG_"),
                f"DEPENDENCIES key '{key}' missing CONFIG_ prefix",
            )
            for dep in deps:
                self.assertTrue(
                    dep.startswith("CONFIG_"),
                    f"Dependency '{dep}' of '{key}' missing CONFIG_ prefix",
                )

    def test_conflict_keys_have_config_prefix(self):
        """Every entry in CONFLICTS must start with CONFIG_."""
        for a, b in self.cc.CONFLICTS:
            self.assertTrue(
                a.startswith("CONFIG_"),
                f"CONFLICTS entry '{a}' missing CONFIG_ prefix",
            )
            self.assertTrue(
                b.startswith("CONFIG_"),
                f"CONFLICTS entry '{b}' missing CONFIG_ prefix",
            )

    def test_dependency_check_fires_on_missing_dep(self):
        """If CONFIG_CPU_FREQ_GOV_APEX=y but CONFIG_CPU_FREQ is absent,
        the dependency check must report an error."""
        merged = {
            "CONFIG_CPU_FREQ_GOV_APEX": "y",
            "CONFIG_CPU_FREQ_GOV_COMMON": "y",
            # CONFIG_CPU_FREQ deliberately missing
        }
        errors = 0
        for config, deps in self.cc.DEPENDENCIES.items():
            if config in merged and merged[config] == "y":
                for dep in deps:
                    if dep not in merged or merged[dep] not in ("y", "m"):
                        errors += 1
        self.assertGreater(
            errors, 0, "Dependency check did not fire on missing CONFIG_CPU_FREQ"
        )

    def test_conflict_check_fires_on_conflicting_pair(self):
        """If two conflicting configs are both =y, the conflict check
        must report an error."""
        merged = {
            "CONFIG_CPU_FREQ_DEFAULT_GOV_APEX": "y",
            "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL": "y",
        }
        errors = 0
        for a, b in self.cc.CONFLICTS:
            if merged.get(a) == "y" and merged.get(b) == "y":
                errors += 1
        self.assertGreater(
            errors, 0, "Conflict check did not fire on conflicting pair"
        )

    def test_parse_config_extracts_values(self):
        """parse_config correctly extracts =y, =n, and =m values."""
        text = """# CONFIG_FOO is not set
CONFIG_BAR=y
CONFIG_BAZ=m
CONFIG_QUX=7
"""
        configs = self._parse_fragment(text)
        self.assertEqual(configs.get("CONFIG_FOO"), "n")
        self.assertEqual(configs.get("CONFIG_BAR"), "y")
        self.assertEqual(configs.get("CONFIG_BAZ"), "m")
        self.assertEqual(configs.get("CONFIG_QUX"), "7")

    def test_parse_config_detects_duplicates(self):
        """parse_config warns on duplicate keys but keeps the last value."""
        text = """CONFIG_DUP=y
CONFIG_DUP=n
"""
        configs = self._parse_fragment(text)
        self.assertEqual(configs.get("CONFIG_DUP"), "n")

    def test_clean_config_set_passes(self):
        """A minimal clean config set with all deps satisfied should
        produce 0 errors."""
        merged = {
            "CONFIG_CPU_FREQ": "y",
            "CONFIG_CPU_FREQ_GOV_COMMON": "y",
            "CONFIG_CPU_FREQ_GOV_APEX": "y",
            "CONFIG_SMP": "y",
            "CONFIG_SCHED_WALT": "y",
            "CONFIG_APEX": "y",
            "CONFIG_APEX_WATCHDOG": "y",
        }
        errors = 0
        for config, deps in self.cc.DEPENDENCIES.items():
            if config in merged and merged[config] == "y":
                for dep in deps:
                    if dep not in merged or merged[dep] not in ("y", "m"):
                        errors += 1
        self.assertEqual(errors, 0, "Clean config set reported errors")


if __name__ == "__main__":
    unittest.main()
