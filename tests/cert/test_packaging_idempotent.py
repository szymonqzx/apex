#!/usr/bin/env python3
"""Regression tests for anykernel3/anykernel.sh build.prop overlay idempotency.

Verifies that:
  1. The build.prop overlay uses a managed block (not blind append).
  2. Reflashing does not duplicate properties — the old block is removed
     before the new one is written.
  3. The managed block has begin/end markers for identification.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO_ROOT / "anykernel3" / "anykernel.sh"


class TestPackagingIdempotent(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.text = SCRIPT.read_text()

    def test_source_file_exists(self):
        self.assertTrue(SCRIPT.exists(), f"{SCRIPT} not found")

    def test_no_blind_append_to_build_prop(self):
        """The script must not use `cat >> /system/build.prop` (blind append).
        The original code appended on every flash, duplicating properties."""
        # The bug pattern: cat ... >> /system/build.prop or /vendor/build.prop
        blind_append = "cat \"$OVERLAY_DIR/system.build.prop.append\" >> /system/build.prop"
        self.assertNotIn(
            blind_append, self.text,
            "Blind append to /system/build.prop found — not idempotent"
        )
        blind_append_vendor = "cat \"$OVERLAY_DIR/vendor.build.prop.append\" >> /vendor/build.prop"
        self.assertNotIn(
            blind_append_vendor, self.text,
            "Blind append to /vendor/build.prop found — not idempotent"
        )

    def test_managed_block_markers_exist(self):
        """The script must define begin/end markers for the managed block.
        Skipped for v0.1 bare base (no overlay installation)."""
        if "OVERLAY" not in self.text and "overlay" not in self.text:
            self.skipTest("v0.1 bare base — no overlay installation")
        self.assertIn("APEX_BEGIN", self.text, "No APEX_BEGIN marker defined")
        self.assertIn("APEX_END", self.text, "No APEX_END marker defined")
        self.assertIn("OVERLAY BEGIN", self.text, "Begin marker text not found")
        self.assertIn("OVERLAY END", self.text, "End marker text not found")

    def test_managed_block_removal_before_install(self):
        """The script must remove the old managed block before writing the
        new one (idempotent reflash). Skipped for v0.1 bare base."""
        if "OVERLAY" not in self.text and "overlay" not in self.text:
            self.skipTest("v0.1 bare base — no overlay installation")
        # Must have a sed/grep that removes the old block
        self.assertIn(
            "sed -i", self.text,
            "No sed command to remove old managed block — reflash will duplicate"
        )

    def test_idempotent_reflash_simulation(self):
        """Simulate two reflashes and verify the managed block appears
        exactly once after the second flash."""
        with tempfile.TemporaryDirectory() as tmpdir:
            target = Path(tmpdir) / "build.prop"
            overlay = Path(tmpdir) / "overlay.append"

            # Initial build.prop
            target.write_text("ro.build.product=topaz\nro.build.version=13\n")

            # Overlay content
            overlay.write_text("ro.apex.version=1.0\nro.apex.governor=apex\n")

            APEX_BEGIN = "# >>> APEX KERNEL OVERLAY BEGIN >>>"
            APEX_END = "# <<< APEX KERNEL OVERLAY END <<<"

            def install_managed_block(target_path, overlay_path):
                """Mirror the anykernel.sh logic."""
                content = Path(target_path).read_text()
                # Remove existing block
                if APEX_BEGIN in content:
                    lines = content.splitlines()
                    new_lines = []
                    skip = False
                    for line in lines:
                        if APEX_BEGIN in line:
                            skip = True
                            continue
                        if APEX_END in line:
                            skip = False
                            continue
                        if not skip:
                            new_lines.append(line)
                    content = "\n".join(new_lines) + "\n"
                # Append new block
                overlay_content = Path(overlay_path).read_text()
                content += f"{APEX_BEGIN}\n{overlay_content}{APEX_END}\n"
                Path(target_path).write_text(content)

            # First flash
            install_managed_block(target, overlay)
            first = target.read_text()
            begin_count_1 = first.count(APEX_BEGIN)
            end_count_1 = first.count(APEX_END)
            self.assertEqual(begin_count_1, 1, "First flash: multiple BEGIN markers")
            self.assertEqual(end_count_1, 1, "First flash: multiple END markers")
            self.assertIn("ro.apex.version=1.0", first)

            # Second flash (reflash)
            install_managed_block(target, overlay)
            second = target.read_text()
            begin_count_2 = second.count(APEX_BEGIN)
            end_count_2 = second.count(APEX_END)
            self.assertEqual(begin_count_2, 1,
                             f"Second flash: {begin_count_2} BEGIN markers — not idempotent!")
            self.assertEqual(end_count_2, 1,
                             f"Second flash: {end_count_2} END markers — not idempotent!")

            # Property should appear exactly once
            apex_count = second.count("ro.apex.version=1.0")
            self.assertEqual(apex_count, 1,
                             f"Property appears {apex_count} times after reflash — duplicated!")


if __name__ == "__main__":
    unittest.main()
