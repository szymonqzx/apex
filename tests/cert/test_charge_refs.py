#!/usr/bin/env python3
"""Regression tests for patches/apex-charge/src/apex_charge.c.

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
SOURCE = REPO_ROOT / "patches" / "apex-charge" / "src" / "apex_charge.c"


class TestChargeSourceInvariants(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.text = SOURCE.read_text()
        cls.lines = cls.text.splitlines()

    def test_source_file_exists(self):
        self.assertTrue(SOURCE.exists(), f"{SOURCE} not found")

    def test_apex_write_sysfs_checks_kernel_write_return(self):
        """apex_write_sysfs must check the return value of kernel_write().
        The original code ignored it and returned 0 unconditionally."""
        # Find the apex_write_sysfs function body
        match = re.search(
            r'static int apex_write_sysfs\([^)]+\)\s*\{([^}]+)\}',
            self.text, re.DOTALL
        )
        self.assertIsNotNone(match, "apex_write_sysfs function not found")
        body = match.group(1)
        self.assertIn(
            "kernel_write", body,
            "apex_write_sysfs must call kernel_write"
        )
        # Must assign the return value to a variable (not a bare statement).
        # The bug was: kernel_write(f, buf, len, &f->f_pos); — no assignment.
        bare_call = re.search(
            r'^\s*kernel_write\s*\(', body, re.MULTILINE
        )
        self.assertIsNone(
            bare_call,
            "kernel_write() is called as a bare statement — "
            "short writes and errors are silently lost"
        )
        # Must assign to a variable and check it
        self.assertIn(
            "ret = kernel_write", body,
            "kernel_write return value must be captured"
        )

    def test_apex_write_sysfs_returns_error_on_failure(self):
        """apex_write_sysfs must return a negative error on write failure."""
        match = re.search(
            r'static int apex_write_sysfs\([^)]+\)\s*\{([^}]+)\}',
            self.text, re.DOTALL
        )
        body = match.group(1)
        # Must have a path that returns a negative value (error)
        self.assertTrue(
            re.search(r'return\s+-EIO|return\s+ret\s*;', body) is not None or
            re.search(r'if\s*\(\s*ret\s*<\s*0\s*\)\s*return\s+ret', body) is not None,
            "apex_write_sysfs must return an error on write failure"
        )

    def test_every_get_psy_has_matching_put(self):
        """Every apex_get_psy() call must be paired with power_supply_put()
        on all code paths.  This is a file-level balance check: the total
        number of gets and puts must match (excluding the wrapper itself
        and the apex_get_psy definition which just returns the PSY)."""
        # Count all apex_get_psy calls (excluding the function definition)
        gets = len(re.findall(r'\bapex_get_psy\s*\(', self.text))
        # Subtract 1 for the function definition itself
        if re.search(r'static struct power_supply\s+\*apex_get_psy\s*\(', self.text):
            gets -= 1

        # Count all power_supply_put calls
        puts = len(re.findall(r'\bpower_supply_put\s*\(', self.text))

        # The get wrapper (apex_get_psy) calls power_supply_get_by_name,
        # not apex_get_psy, so every apex_get_psy call site needs a put.
        self.assertEqual(
            gets, puts,
            f"{gets} apex_get_psy() calls but {puts} power_supply_put() calls — "
            f"ref leak detected"
        )

    def test_apply_charge_mode_puts_main_and_usb(self):
        """apex_apply_charge_mode must put both 'main' and 'usb' PSYs."""
        match = re.search(
            r'static void apex_apply_charge_mode\(void\)\s*\{(.+?)(?=\nstatic |\nvoid |\Z)',
            self.text, re.DOTALL
        )
        self.assertIsNotNone(match, "apex_apply_charge_mode not found")
        body = match.group(1)
        self.assertIn('power_supply_put(main)', body,
                       "apex_apply_charge_mode must put 'main' PSY")
        self.assertIn('power_supply_put(usb)', body,
                       "apex_apply_charge_mode must put 'usb' PSY")

    def test_apply_bypass_puts_parallel(self):
        """apex_apply_bypass must put the 'parallel' PSY."""
        match = re.search(
            r'static void apex_apply_bypass\(void\)\s*\{(.+?)(?=\nstatic |\nvoid |\Z)',
            self.text, re.DOTALL
        )
        self.assertIsNotNone(match, "apex_apply_bypass not found")
        body = match.group(1)
        self.assertIn('power_supply_put(parallel)', body,
                       "apex_apply_bypass must put 'parallel' PSY")


if __name__ == "__main__":
    unittest.main()
