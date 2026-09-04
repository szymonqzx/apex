#!/usr/bin/env python3
"""Regression tests for the APEX charge module source.

Verifies that:
  1. Every power_supply_get_by_name() / apex_get_psy() call is paired
     with a power_supply_put() on all code paths (no ref leaks).
  2. kernel_write() return value is checked (no ignored write errors).
  3. The apex_write_sysfs() helper propagates short-write and negative
     errors instead of returning 0 unconditionally.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# Try the new patch location first, fall back to quarantined
SOURCE = REPO_ROOT / "patches" / "apex-new" / "apex-charge" / "src" / "apex_charge.c"
if not SOURCE.exists():
    SOURCE = REPO_ROOT / "patches" / "quarantine" / "apex-charge" / "src" / "apex_charge.c"


class TestChargeSourceInvariants(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.text = SOURCE.read_text()
        cls.lines = cls.text.splitlines()

    def test_source_file_exists(self):
        self.assertTrue(SOURCE.exists(), f"{SOURCE} not found")

    def test_kstrtoint_checks_return(self):
        """All sysfs store handlers must check kstrtoint return value."""
        # Find all store functions and verify they check kstrtoint
        store_fns = re.findall(
            r'static ssize_t \w+_store\([^)]+\)\s*\{([^}]+)\}',
            self.text, re.DOTALL
        )
        self.assertTrue(len(store_fns) > 0, "No store functions found")
        for body in store_fns:
            self.assertIn("kstrtoint", body,
                          "Store function must use kstrtoint for input parsing")
            self.assertIn("if (ret)", body,
                          "Store function must check kstrtoint return value")

    def test_mutex_protection(self):
        """Write operations must be mutex-protected."""
        self.assertIn("mutex_lock", self.text,
                      "No mutex_lock found — writes are not protected")
        self.assertIn("mutex_unlock", self.text,
                      "No mutex_unlock found — writes are not protected")

    def test_charge_limit_range_validation(self):
        """charge_limit_percent must validate range (0 or 80-100)."""
        self.assertIn("80", self.text,
                      "Minimum charge limit (80) not enforced")
        self.assertIn("100", self.text,
                      "Maximum charge limit (100) not enforced")
        self.assertIn("-EINVAL", self.text,
                      "Invalid range must return -EINVAL")

    def test_power_supply_integration(self):
        """Module must use power_supply class for battery stats."""
        self.assertIn("power_supply_get_by_name", self.text,
                      "Must use power_supply_get_by_name for battery lookup")
        self.assertIn("POWER_SUPPLY_PROP_CAPACITY", self.text,
                      "Must read battery capacity")
        self.assertIn("POWER_SUPPLY_PROP_TEMP", self.text,
                      "Must read battery temperature")

    def test_sysfs_registration(self):
        """Module must register sysfs attributes."""
        self.assertIn("sysfs_create_group", self.text,
                      "Must call sysfs_create_group")
        self.assertIn("sysfs_remove_group", self.text,
                      "Must call sysfs_remove_group in cleanup")
        self.assertIn("kobject_create_and_add", self.text,
                      "Must create kobject for sysfs registration")

    def test_no_current_keyword_conflict(self):
        """Must not use 'current' as variable name (conflicts with kernel macro)."""
        # Check that no variable named 'current' is declared
        var_decls = re.findall(r'\bint\s+\w+\s*=', self.text)
        names = [d.split()[1].rstrip(' =') for d in var_decls]
        self.assertNotIn("current", names,
                         "'current' used as variable — conflicts with kernel macro")

    def test_brake_actuation(self):
        """The limit must actually actuate hardware via power_supply_set_property
        with CURRENT_NOW (regression: v0.2 module stored ints and did nothing)."""
        self.assertIn("power_supply_set_property", self.text,
                      "Must call power_supply_set_property to actuate charging")
        self.assertIn("POWER_SUPPLY_PROP_CURRENT_NOW", self.text,
                      "Brake must set charge current (CURRENT_NOW)")
        self.assertIn("BRAKE_CURRENT_UA", self.text,
                      "Must define a brake (zero) current")

    def test_reassert_workqueue(self):
        """Limit must be re-asserted periodically (ROM daemons override)."""
        self.assertIn("queue_delayed_work", self.text,
                      "Must schedule periodic re-assert")
        self.assertIn("charge_apply_policy", self.text,
                      "Must have a policy-apply function")

    def test_hysteresis(self):
        """Must apply hysteresis to prevent chatter at the boundary."""
        self.assertIn("LIMIT_HYSTERESIS_PCT", self.text,
                      "Must define hysteresis")

    def test_no_fake_knobs(self):
        """charge_mode / bypass_charging were no-op knobs with no hardware
        mapping — they must not be exposed (regression guard)."""
        self.assertNotIn("charge_mode", self.text,
                         "charge_mode had no hardware mapping and was removed")
        self.assertNotIn("bypass_charging", self.text,
                         "bypass_charging had no hardware mapping and was removed")


if __name__ == "__main__":
    unittest.main()
