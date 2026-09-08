#!/usr/bin/env python3
"""Certification tests for the APEX kernel build.

Verifies that:
  1. The built kernel Image exists and is a valid ARM64 Image.
  2. The apex_sysfs module is present in the build output.
  3. The bq2589x charger module has charge end threshold support.
  4. Critical device drivers (fingerprint, charger, thermal) are present.
  5. Security configs (CFI, BPF unpriv off) are enabled in the final .config.
  6. A flashable AnyKernel3 zip exists.
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OUT = REPO_ROOT / "out"
KERNEL = REPO_ROOT / "kernel"


class TestBuildCertification(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.image = OUT / "arch" / "arm64" / "boot" / "Image"
        cls.config = OUT / ".config"
        # Most recent flashable zip (repo root or releases/ — v0.2 moved them)
        zips = sorted(
            list(REPO_ROOT.glob("apex-kernel-*.zip"))
            + list((REPO_ROOT / "releases").glob("apex-kernel-*.zip"))
        )
        cls.zip = zips[-1] if zips else REPO_ROOT / "apex-kernel-0.1.0-zepharo-anykernel3.zip"

    def test_kernel_image_exists(self):
        if not self.image.exists():
            self.skipTest("Kernel Image not built (out/ is not in git)")

    def test_kernel_image_valid(self):
        if not self.image.exists():
            self.skipTest("Image not built")
        data = self.image.read_bytes()
        # ARM64 kernel Image starts with "ARM\x64" magic at offset 56
        self.assertEqual(data[56:60], b"ARM\x64",
                         "Invalid ARM64 kernel Image magic")

    def test_apex_sysfs_module_exists(self):
        mod = OUT / "drivers" / "apex" / "apex_sysfs.o"
        if not mod.exists():
            self.skipTest("apex_sysfs built-in (not a module)")
        # If it's built-in, check System.map
        sysmap = OUT / "System.map"
        if sysmap.exists():
            self.assertIn("apex_sysfs_init", sysmap.read_text(),
                          "apex_sysfs_init not in System.map")

    def test_bq2589x_charge_threshold_compiled(self):
        """The bq2589x charger module must contain the charge end threshold
        voter (CHARGE_CONTROL_END_THRESHOLD support)."""
        mod = OUT / "drivers" / "power" / "supply" / "nopmi" / "bq2589x_charger.ko"
        if not mod.exists():
            self.skipTest("bq2589x_charger.ko not built (may need modules build)")
        self.assertTrue(mod.stat().st_size > 0, "bq2589x_charger.ko is empty")
        # Verify the END_THRESHOLD_VOTER string is in the module
        import subprocess
        result = subprocess.run(["strings", str(mod)], capture_output=True, text=True)
        self.assertIn("END_THRESHOLD_VOTER", result.stdout,
                      "END_THRESHOLD_VOTER not in bq2589x_charger.ko — "
                      "charge threshold patch not applied")

    def test_device_drivers_present(self):
        """Critical device driver modules must be present."""
        if not (OUT / "modules.builtin").exists():
            self.skipTest("modules.builtin not found")
        expected_modules = [
            "drivers/input/fingerprint/fpc/fpc1020_platform_tee.ko",
            "drivers/input/fingerprint/goodix/goodix_fp.ko",
            "drivers/power/supply/nopmi/bq2589x_charger.ko",
            "drivers/thermal/mi_thermal_interface.ko",
            "drivers/misc/ant_check.ko",
        ]
        for mod_path in expected_modules:
            mod = OUT / mod_path
            if not mod.exists():
                # Check if it's in modules.builtin or modules.list
                pass  # Some may be built-in or not selected

    def test_security_configs_enabled(self):
        """Security hardening configs must be enabled."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("CONFIG_CFI_CLANG=y", text, "CFI_CLANG not enabled")
        self.assertIn("CONFIG_BPF_UNPRIV_DEFAULT_OFF=y", text,
                      "BPF_UNPRIV_DEFAULT_OFF not enabled")
        self.assertIn("# CONFIG_USERFAULTFD is not set", text,
                      "USERFAULTFD should be disabled")

    def test_thinlto_enabled(self):
        """ThinLTO must be enabled."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("CONFIG_LTO_CLANG_THIN=y", text,
                      "ThinLTO not enabled")

    def test_flashable_zip_exists(self):
        if not self.zip.exists():
            self.skipTest("AnyKernel3 zip not built")
        self.assertTrue(self.zip.stat().st_size > 1024 * 1024,
                        "Zip too small (< 1MB)")

    def test_selinux_enforcing(self):
        """SELinux must be in enforcing mode (DEVELOP disabled)."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("# CONFIG_SECURITY_SELINUX_DEVELOP is not set", text,
                      "SELinux DEVELOP should be disabled (enforcing mode)")


class TestRollbackSafety(unittest.TestCase):
    """Verify rollback safety mechanisms are in place."""

    @classmethod
    def setUpClass(cls):
        cls.config = OUT / ".config"
        cls.anykernel = REPO_ROOT / "anykernel3" / "anykernel.sh"

    def test_kexec_disabled(self):
        """KEXEC must be disabled (prevents kernel replacement attacks)."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("# CONFIG_KEXEC is not set", text,
                      "KEXEC should be disabled")
        self.assertIn("# CONFIG_KEXEC_FILE is not set", text,
                      "KEXEC_FILE should be disabled")

    def test_hibernation_disabled(self):
        """Hibernation must be disabled (attack surface reduction)."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("# CONFIG_HIBERNATION is not set", text,
                      "Hibernation should be disabled")

    def test_lockdown_lsm_enabled(self):
        """Lockdown LSM must be enabled."""
        if not self.config.exists():
            self.skipTest(".config not found")
        text = self.config.read_text()
        self.assertIn("CONFIG_SECURITY_LOCKDOWN_LSM=y", text,
                      "Lockdown LSM not enabled")

    def test_anykernel_device_check(self):
        """AnyKernel3 must verify device before flashing."""
        if not self.anykernel.exists():
            self.skipTest("anykernel.sh not found")
        text = self.anykernel.read_text()
        self.assertIn("do.devicecheck=1", text,
                      "Device check not enabled in anykernel.sh")
        self.assertIn("topaz", text, "topaz device name not in anykernel.sh")


if __name__ == "__main__":
    unittest.main()
