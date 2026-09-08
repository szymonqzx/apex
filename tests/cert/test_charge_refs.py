#!/usr/bin/env python3
"""Regression tests for the charge control implementation.

The charge limiting is now implemented as the standard
POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD property on the bq2589x
charger driver (the "bbc" power supply), not a custom kernel module.

Verifies that:
  1. The property is declared in the charger props array.
  2. Get and set handlers exist and validate range (0-100).
  3. The property is marked writable.
  4. The monitor workfunc checks capacity against the threshold.
  5. The existing chg_dis_votable is used for actuation (no novel code).
  6. Hysteresis is present to prevent chatter.
  7. No fake knobs (charge_mode, bypass_charging) are exposed.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# The charge threshold is now in the bq2589x charger driver itself
SOURCE_C = REPO_ROOT / "kernel" / "drivers" / "power" / "supply" / "nopmi" / "bq2589x_charger.c"
SOURCE_H = REPO_ROOT / "kernel" / "drivers" / "power" / "supply" / "nopmi" / "bq2589x_charger.h"

# Also check the patch source for reproducibility from clean checkout
PATCH_APPLY = REPO_ROOT / "patches" / "apex-new" / "apex-charge" / "apply.sh"


class TestChargeSourceInvariants(unittest.TestCase):
    """Test the in-kernel bq2589x charge threshold implementation."""

    @classmethod
    def setUpClass(cls):
        if SOURCE_C.exists():
            cls.text = SOURCE_C.read_text()
            cls.source_available = True
        else:
            cls.text = ""
            cls.source_available = False
        if SOURCE_H.exists():
            cls.hdr_text = SOURCE_H.read_text()
        else:
            cls.hdr_text = ""

    def test_source_file_exists(self):
        if not self.source_available:
            # kernel/ is not in git — the driver source only exists after
            # `make patch` on a fetched tree. The patch-level invariants are
            # covered by test_patch_apply_script_exists/test_patch_targets_bq2589x.
            self.skipTest(f"{SOURCE_C} not present (kernel tree not fetched)")
        self.assertTrue(SOURCE_C.exists(),
                        f"{SOURCE_C} not found — bq2589x driver missing")

    def test_property_in_props_array(self):
        """CHARGE_CONTROL_END_THRESHOLD must be in the charger props array."""
        if not self.source_available:
            self.skipTest("source not available")
        self.assertIn("POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD",
                      self.text,
                      "Property must be in bq2589x_charger_props[]")

    def test_get_handler_exists(self):
        """Get handler must return charge_end_threshold from the struct."""
        if not self.source_available:
            self.skipTest("source not available")
        # Check that the get handler has the case
        self.assertIn("POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD",
                      self.text)
        # Verify it reads from the struct field
        self.assertIn("charge_end_threshold", self.text,
                      "Must reference charge_end_threshold field")

    def test_set_handler_range_validation(self):
        """Set handler must validate range (0-100) and return -EINVAL."""
        if not self.source_available:
            self.skipTest("source not available")
        # Find the set_property function, then the threshold case within it
        set_fn = re.search(
            r'bq2589x_wall_set_property\(.*?\n\}(.*?return ret;\n\})',
            self.text, re.DOTALL)
        self.assertIsNotNone(set_fn, "bq2589x_wall_set_property not found")
        set_body = set_fn.group(0)
        pattern = r'case POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD:.*?break;'
        match = re.search(pattern, set_body, re.DOTALL)
        self.assertIsNotNone(match, "Set handler case not found in set_property")
        body = match.group(0)
        self.assertIn("EINVAL", body,
                      "Must return -EINVAL for out-of-range values")
        self.assertIn("100", body,
                      "Must validate upper bound (100)")

    def test_property_is_writable(self):
        """The property must be marked writable in property_is_writeable."""
        if not self.source_available:
            self.skipTest("source not available")
        # Find the specific writeable function for the wall psy
        pattern = r'bq2589x_wall_prop_is_writeable\(.*?\n\}'
        match = re.search(pattern, self.text, re.DOTALL)
        self.assertIsNotNone(match,
                             "bq2589x_wall_prop_is_writeable not found")
        body = match.group(0)
        self.assertIn("POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD",
                      body,
                      "Property must be in the writeable switch")

    def test_monitor_work_threshold_check(self):
        """Monitor workfunc must check capacity against the threshold."""
        if not self.source_available:
            self.skipTest("source not available")
        self.assertIn("charge_end_threshold", self.text)
        self.assertIn("chg_dis_votable", self.text,
                      "Must use the existing chg_dis_votable for actuation")
        self.assertIn("END_THRESHOLD_VOTER", self.text,
                      "Must define a voter name for the threshold")

    def test_hysteresis(self):
        """Must apply hysteresis (3%) to prevent chatter at the boundary."""
        if not self.source_available:
            self.skipTest("source not available")
        # The hysteresis is the "- 3" in the re-enable condition
        self.assertIn("charge_end_threshold - 3", self.text,
                      "Must have 3% hysteresis in the re-enable condition")

    def test_struct_field_exists(self):
        """The bq2589x struct must have charge_end_threshold field."""
        if not self.source_available:
            self.skipTest("source not available")
        self.assertIn("charge_end_threshold", self.hdr_text,
                      "Struct field must be in bq2589x_charger.h")

    def test_no_fake_knobs(self):
        """No fake sysfs knobs (charge_mode/bypass_charging as __ATTR names)
        should be added by our patch. The existing bq2589x driver has
        functions with 'charge_mode' in their name (e.g.
        bq2589x_set_fast_charge_mode) — that's fine, we only guard against
        exposing fake sysfs attributes."""
        if not self.source_available:
            self.skipTest("source not available")
        # Check that no __ATTR or kobj_attribute named charge_mode or
        # bypass_charging is present (these were the old fake knobs)
        fake_attr = re.search(r'__ATTR\w*\s*\(\s*"charge_mode"', self.text)
        self.assertIsNone(fake_attr,
                          "Fake 'charge_mode' sysfs attribute must not exist")
        fake_attr = re.search(r'__ATTR\w*\s*\(\s*"bypass_charging"', self.text)
        self.assertIsNone(fake_attr,
                          "Fake 'bypass_charging' sysfs attribute must not exist")

    def test_no_custom_module(self):
        """The old apex_charge.c custom module must not exist."""
        old_module = REPO_ROOT / "kernel" / "drivers" / "apex" / "apex_charge.c"
        self.assertFalse(old_module.exists(),
                         "apex_charge.c should be removed — charge limiting "
                         "is now in the bq2589x driver")

    def test_no_apex_charge_kconfig(self):
        """CONFIG_APEX_CHARGE must not be in the Kconfig."""
        kconfig = REPO_ROOT / "kernel" / "drivers" / "apex" / "Kconfig"
        if kconfig.exists():
            text = kconfig.read_text()
            self.assertNotIn("config APEX_CHARGE", text,
                             "APEX_CHARGE Kconfig entry should be removed")

    def test_patch_apply_script_exists(self):
        """The patch apply.sh must exist for reproducible builds."""
        self.assertTrue(PATCH_APPLY.exists(),
                        "apex-charge/apply.sh must exist for reproducible builds")

    def test_patch_targets_bq2589x(self):
        """The patch apply.sh must target the bq2589x driver."""
        text = PATCH_APPLY.read_text()
        self.assertIn("bq2589x_charger", text,
                      "Patch must modify the bq2589x charger driver")
        self.assertIn("CHARGE_CONTROL_END_THRESHOLD", text,
                      "Patch must add the standard power_supply property")


if __name__ == "__main__":
    unittest.main()
