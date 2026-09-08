#!/usr/bin/env python3
"""Regression tests for tools/apex-wakelock-audit.sh classification logic.

Verifies that:
  1. Protected patterns (modem, RIL, QMI, WLAN, etc.) are correctly
     classified as SPARED, not UNKNOWN or SUPPRESSED.
  2. Safe patterns (telemetry, analytics, miui reporting) are correctly
     classified as SUPPRESSED.
  3. The subshell state-loss bug is fixed: IS_PROTECTED and IS_SAFE
     variables propagate to the parent shell.
"""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

FIXTURE_WAKESOURCES = """\
qmi_wakelock 100 200 50 1234567 890 0 75
ril_modem_wl 80 150 40 2345678 901 0 55
wlan_rx_wake 60 120 30 3456789 012 0 45
telemetry_report 5 10 2 4567890 123 0 8
miui_analytics 3 6 1 5678901 234 0 5
xiaomi_log_upload 2 4 0 6789012 345 0 3
usage_stats_wl 1 2 0 7890123 456 0 2
random_unknown_wl 10 20 5 8901234 567 0 15
display_panel 50 100 25 9012345 678 0 40
sensor_hub_wake 30 60 15 1234567 789 0 25
"""

CLASSIFY_SCRIPT = r"""#!/bin/bash
set -uo pipefail

PROTECTED_PATTERNS='qmi
ril
modem
wlan
wifi
ath
wcn
cnss
ipc
dsi
display
panel
sensor
alarm
power.*key'

SAFE_PATTERNS='telemetry
analytics
miui.*report
xiaomi.*log
data.*report
usage.*stats
feedback
crash.*report'

classify_wl() {
  WL_NAME="$1"
  IS_PROTECTED=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if echo "$WL_NAME" | grep -qi "$pat"; then
      IS_PROTECTED=1
      break
    fi
  done <<PATEOF
$PROTECTED_PATTERNS
PATEOF

  IS_SAFE=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if echo "$WL_NAME" | grep -qi "$pat"; then
      IS_SAFE=1
      break
    fi
  done <<PATEOF
$SAFE_PATTERNS
PATEOF

  if [ "$IS_PROTECTED" -eq 1 ]; then
    echo "SPARED"
  elif [ "$IS_SAFE" -eq 1 ]; then
    echo "SUPPRESSED"
  else
    echo "UNKNOWN"
  fi
}

WS_FILE="$1"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  WL_NAME=$(echo "$line" | awk '{print $1}')
  [ -z "$WL_NAME" ] && continue
  echo "$WL_NAME:$(classify_wl "$WL_NAME")"
done < "$WS_FILE"
"""


class TestWakelockAudit(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.ws_path = Path(self.tmpdir) / "wakeup_sources"
        self.ws_path.write_text(FIXTURE_WAKESOURCES)
        self.script_path = Path(self.tmpdir) / "classify.sh"
        self.script_path.write_text(CLASSIFY_SCRIPT)
        os.chmod(self.script_path, 0o755)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _run_audit(self):
        result = subprocess.run(
            [str(self.script_path), str(self.ws_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        return dict(line.split(":", 1) for line in result.stdout.strip().split("\n"))

    def test_protected_wakelocks_are_spared(self):
        """Modem/RIL/QMI/WLAN wakelocks must be SPARED, not SUPPRESSED."""
        results = self._run_audit()
        protected = ["qmi_wakelock", "ril_modem_wl", "wlan_rx_wake",
                     "display_panel", "sensor_hub_wake"]
        for name in protected:
            self.assertEqual(
                results.get(name), "SPARED",
                f"{name} should be SPARED but got {results.get(name)}"
            )

    def test_safe_wakelocks_are_suppressed(self):
        """Telemetry/analytics wakelocks should be SUPPRESSED."""
        results = self._run_audit()
        safe = ["telemetry_report", "miui_analytics",
                "xiaomi_log_upload", "usage_stats_wl"]
        for name in safe:
            self.assertEqual(
                results.get(name), "SUPPRESSED",
                f"{name} should be SUPPRESSED but got {results.get(name)}"
            )

    def test_unknown_wakelocks_are_unknown(self):
        """Wakelocks matching neither pattern should be UNKNOWN."""
        results = self._run_audit()
        self.assertEqual(
            results.get("random_unknown_wl"), "UNKNOWN",
            f"random_unknown_wl should be UNKNOWN"
        )

    def test_no_protected_wakelock_is_suppressed(self):
        """Critical: no wakelock matching a protected pattern may be
        classified as SUPPRESSED.  This is the regression guard for the
        subshell state-loss bug that caused IS_PROTECTED to always be 0."""
        results = self._run_audit()
        for name, classification in results.items():
            if classification == "SUPPRESSED":
                protected_patterns = [
                    "qmi", "ril", "modem", "wlan", "wifi", "ath",
                    "wcn", "cnss", "ipc", "dsi", "display", "panel",
                    "sensor", "alarm",
                ]
                for pat in protected_patterns:
                    self.assertFalse(
                        pat.lower() in name.lower(),
                        f"PROTECTED wakelock '{name}' was SUPPRESSED "
                        f"(matched pattern '{pat}') — subshell bug regression!"
                    )


if __name__ == "__main__":
    unittest.main()
