#!/usr/bin/env python3
"""Regression tests for chroot/bridge/apex-bridge.c.

Verifies that:
  1. Every mutation command (screen_on, screen_off, game, charge, audio)
     checks the return value of apex_write_policy() and returns ERROR
     on failure — the original code returned "OK" unconditionally.
  2. No mutation command returns "OK" without first checking the write result.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE = REPO_ROOT / "chroot" / "bridge" / "apex-bridge.c"


class TestBridgeErrorHandling(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.text = SOURCE.read_text()

    def test_source_file_exists(self):
        self.assertTrue(SOURCE.exists(), f"{SOURCE} not found")

    def test_no_unconditional_ok_after_write_policy(self):
        """No mutation command may return OK without checking
        apex_write_policy()'s return value.  The original code pattern was:
            apex_write_policy("screen_on");
            snprintf(response, resp_len, "OK");
        which reports success even when the write fails."""
        # Find all apex_write_policy calls that are immediately followed
        # by snprintf(... "OK" ...) without an intervening if-check.
        # The bug pattern: apex_write_policy(...);\n\ts*snprintf(... "OK"
        bug_pattern = re.compile(
            r'apex_write_policy\([^)]+\);\s*\n\s*'
            r'snprintf\([^)]*"OK"',
            re.MULTILINE
        )
        matches = bug_pattern.findall(self.text)
        self.assertEqual(
            len(matches), 0,
            f"Found {len(matches)} mutation commands that return OK "
            f"without checking apex_write_policy() return value"
        )

    def test_mutation_commands_check_write_result(self):
        """Every mutation command must check apex_write_policy() return
        value before responding OK."""
        # Find the handle_command function body
        match = re.search(
            r'static void handle_command\([^)]+\)\s*\{(.+?)(?=\nstatic |\Z)',
            self.text, re.DOTALL
        )
        self.assertIsNotNone(match, "handle_command not found")
        body = match.group(1)

        # Each mutation command should have an if-check on apex_write_policy
        mutation_cmds = ['screen_on', 'screen_off', 'game', 'charge', 'audio']
        for cmd in mutation_cmds:
            # Find the section handling this command
            if cmd in ('screen_on', 'screen_off'):
                # Exact match commands
                pattern = rf'strcmp\(cmd, "{cmd}"\).*?apex_write_policy'
            else:
                # Prefix match commands
                pattern = rf'strncmp\(cmd, "{cmd} ",.*?apex_write_policy'

            section_match = re.search(pattern, body, re.DOTALL)
            if section_match:
                # Find the apex_write_policy call in this section
                section_start = section_match.start()
                # Look at the next 500 chars for the if-check
                section = body[section_start:section_start + 500]
                self.assertIn(
                    'if (apex_write_policy',
                    section,
                    f"Command '{cmd}' does not check apex_write_policy() return value"
                )

    def test_write_policy_checks_write_return(self):
        """apex_write_policy must check the return value of write()."""
        match = re.search(
            r'static int apex_write_policy\([^)]+\)\s*\{(.+?)\n\}',
            self.text, re.DOTALL
        )
        self.assertIsNotNone(match, "apex_write_policy not found")
        body = match.group(1)
        # Must check write() return value
        self.assertIn(
            'written < 0',
            body,
            "apex_write_policy does not check write() return value"
        )
        # Must check for short write
        self.assertIn(
            'written != strlen',
            body,
            "apex_write_policy does not check for short writes"
        )


if __name__ == "__main__":
    unittest.main()
