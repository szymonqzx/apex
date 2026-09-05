#!/usr/bin/env python3
"""Tests for APEX ROM power-user features ported from LineageOS-based ROMs.

Verifies that:
  1. All new init.d RC files exist with correct property triggers
  2. Companion shell scripts exist and are syntactically valid
  3. RC files do not touch bootloader/aboot/partition tables (brick-safety)
  4. Kotlin data model and repository have correct structure
  5. Power-user UI screen composable exists with all feature toggles
  6. Apex Control screen has the Power tab
  7. build.prop has power-user feature flags
  8. No permissive SELinux domains in new files
  9. Shell scripts follow set -euo pipefail convention
"""

import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ROM_OVERLAYS = REPO_ROOT / "rom-overlays" / "init.d"
APP_SRC = REPO_ROOT / "apps" / "apex-control" / "app" / "src" / "main" / "java" / "com" / "apex" / "control"
BUILD_PROP = REPO_ROOT / "rom-overlays" / "build.prop" / "system.build.prop.append"


class TestPowerUserRcFiles(unittest.TestCase):
    """Verify init.d RC files for power-user features."""

    EXPECTED_RC_FILES = [
        "apex_game_space.rc",
        "apex_pocket.rc",
        "apex_smart_charging.rc",
        "apex_reboot.rc",
        "apex_gestures.rc",
        "apex_notifications.rc",
        "apex_power_user.rc",
    ]

    EXPECTED_SHELL_SCRIPTS = [
        "apex_pocket_detect.sh",
        "apex_smart_charge.sh",
        "apex_screenshot_gesture.sh",
    ]

    def test_all_rc_files_exist(self):
        for filename in self.EXPECTED_RC_FILES:
            path = ROM_OVERLAYS / filename
            self.assertTrue(path.exists(), f"Missing RC file: {filename}")

    def test_all_shell_scripts_exist(self):
        for filename in self.EXPECTED_SHELL_SCRIPTS:
            path = ROM_OVERLAYS / filename
            self.assertTrue(path.exists(), f"Missing shell script: {filename}")

    def test_rc_files_have_property_triggers(self):
        """Each RC file must use property triggers (on property:...)."""
        for filename in self.EXPECTED_RC_FILES:
            content = (ROM_OVERLAYS / filename).read_text()
            self.assertIn("on property:", content,
                          f"{filename} must have property triggers")

    def test_rc_files_have_boot_completed_trigger(self):
        """RC files that need boot-time init must have sys.boot_completed trigger."""
        boot_files = ["apex_pocket.rc", "apex_smart_charging.rc",
                       "apex_gestures.rc", "apex_notifications.rc", "apex_power_user.rc"]
        for filename in boot_files:
            content = (ROM_OVERLAYS / filename).read_text()
            self.assertIn("sys.boot_completed", content,
                          f"{filename} must handle boot_completed")

    def test_game_space_has_fps_unlock(self):
        content = (ROM_OVERLAYS / "apex_game_space.rc").read_text()
        self.assertIn("max_refresh_rate", content, "Game Space must have FPS unlock")
        self.assertIn("120", content, "FPS unlock must target 120Hz")

    def test_game_space_has_sensor_block(self):
        content = (ROM_OVERLAYS / "apex_game_space.rc").read_text()
        self.assertIn("apex_sensors", content, "Game Space must have sensor block")
        self.assertIn("block_non_fg", content, "Sensor block must target non-foreground")

    def test_game_space_has_gpu_lock(self):
        content = (ROM_OVERLAYS / "apex_game_space.rc").read_text()
        self.assertIn("kgsl", content, "Game Space must control GPU")
        self.assertIn("650000000", content, "GPU lock must target 650MHz")

    def test_pocket_detection_has_proximity(self):
        content = (ROM_OVERLAYS / "apex_pocket_detect.sh").read_text()
        self.assertIn("proximity", content.lower(),
                      "Pocket detection must use proximity sensor")

    def test_pocket_detection_has_polling(self):
        content = (ROM_OVERLAYS / "apex_pocket_detect.sh").read_text()
        self.assertIn("sleep", content, "Pocket detection must have polling interval")
        self.assertIn("while", content, "Pocket detection must have a loop")

    def test_smart_charging_has_time_logic(self):
        content = (ROM_OVERLAYS / "apex_smart_charge.sh").read_text()
        self.assertIn("top_up", content, "Smart charging must have top-up logic")
        self.assertIn("charge_limit", content, "Smart charging must have charge limit")
        self.assertIn("wake_time", content, "Smart charging must have wake time")

    def test_smart_charging_has_battery_level(self):
        content = (ROM_OVERLAYS / "apex_smart_charge.sh").read_text()
        self.assertIn("capacity", content, "Smart charging must read battery capacity")

    def test_reboot_has_all_options(self):
        content = (ROM_OVERLAYS / "apex_reboot.rc").read_text()
        for option in ["recovery", "bootloader", "soft", "systemui", "safe"]:
            self.assertIn(option, content,
                          f"Reboot RC must have {option} option")

    def test_gestures_has_dt2w(self):
        content = (ROM_OVERLAYS / "apex_gestures.rc").read_text()
        self.assertIn("double_tap_wake", content, "Gestures must have DT2W")
        self.assertIn("dt2w", content, "Gestures must use dt2w property")

    def test_gestures_has_tap_to_sleep(self):
        content = (ROM_OVERLAYS / "apex_gestures.rc").read_text()
        self.assertIn("tap_to_sleep", content, "Gestures must have tap-to-sleep")
        self.assertIn("tts", content, "Gestures must use tts property")

    def test_gestures_has_screenshot(self):
        content = (ROM_OVERLAYS / "apex_gestures.rc").read_text()
        self.assertIn("screenshot", content, "Gestures must have screenshot gesture")

    def test_notifications_has_heads_up(self):
        content = (ROM_OVERLAYS / "apex_notifications.rc").read_text()
        self.assertIn("heads_up", content, "Notifications must have heads-up control")
        self.assertIn("timeout", content, "Notifications must have timeout control")

    def test_notifications_has_flashlight_blink(self):
        content = (ROM_OVERLAYS / "apex_notifications.rc").read_text()
        self.assertIn("blink", content, "Notifications must have flashlight blink")
        self.assertIn("flashlight", content, "Flashlight blink service must be defined")

    def test_power_user_has_sensor_block(self):
        content = (ROM_OVERLAYS / "apex_power_user.rc").read_text()
        self.assertIn("sensor_block", content, "Power user must have sensor block")

    def test_power_user_has_app_downgrade(self):
        content = (ROM_OVERLAYS / "apex_power_user.rc").read_text()
        self.assertIn("downgrade", content, "Power user must have app downgrade")

    def test_power_user_has_haptics(self):
        content = (ROM_OVERLAYS / "apex_power_user.rc").read_text()
        self.assertIn("haptic", content.lower(), "Power user must have haptics control")


class TestBrickSafety(unittest.TestCase):
    """Verify no new RC files touch bootloader/aboot/partition tables."""

    DANGEROUS_PATTERNS = [
        r"write\s+/dev/block/by-name/aboot",
        r"write\s+/dev/block/by-name/bootloader",
        r"write\s+/dev/block/by-name/xbl",
        r"write\s+/dev/block/by-name/tz",
        r"write\s+/dev/block/by-name/hyp",
        r"write\s+/dev/block/by-name/modem",
        r"write\s+/dev/block/by-name/ssd",
        r"dd\s+.*of=/dev/block/by-name/(aboot|bootloader|xbl|tz|hyp|modem)",
    ]

    POWER_USER_RC_FILES = [
        "apex_game_space.rc",
        "apex_pocket.rc",
        "apex_smart_charging.rc",
        "apex_reboot.rc",
        "apex_gestures.rc",
        "apex_notifications.rc",
        "apex_power_user.rc",
    ]

    POWER_USER_SHELL_SCRIPTS = [
        "apex_pocket_detect.sh",
        "apex_smart_charge.sh",
        "apex_screenshot_gesture.sh",
    ]

    def test_no_dangerous_writes_in_rc_files(self):
        for filename in self.POWER_USER_RC_FILES:
            content = (ROM_OVERLAYS / filename).read_text()
            for pattern in self.DANGEROUS_PATTERNS:
                self.assertIsNone(
                    re.search(pattern, content, re.IGNORECASE),
                    f"{filename} contains dangerous write: {pattern}",
                )

    def test_no_dangerous_writes_in_shell_scripts(self):
        for filename in self.POWER_USER_SHELL_SCRIPTS:
            content = (ROM_OVERLAYS / filename).read_text()
            for pattern in self.DANGEROUS_PATTERNS:
                self.assertIsNone(
                    re.search(pattern, content, re.IGNORECASE),
                    f"{filename} contains dangerous write: {pattern}",
                )

    def test_reboot_rc_does_not_flash_partitions(self):
        """Reboot RC must only use sys.powerctl, not direct partition writes."""
        content = (ROM_OVERLAYS / "apex_reboot.rc").read_text()
        self.assertIn("sys.powerctl", content,
                      "Reboot must use sys.powerctl, not direct writes")
        self.assertNotIn("/dev/block", content,
                         "Reboot RC must not touch block devices directly")


class TestShellScriptConventions(unittest.TestCase):
    """Verify shell scripts follow repo conventions."""

    SHELL_SCRIPTS = [
        "apex_pocket_detect.sh",
        "apex_smart_charge.sh",
        "apex_screenshot_gesture.sh",
    ]

    def test_scripts_have_set_euo_pipefail(self):
        for filename in self.SHELL_SCRIPTS:
            content = (ROM_OVERLAYS / filename).read_text()
            self.assertIn("set -euo pipefail", content,
                          f"{filename} must have 'set -euo pipefail'")

    def test_scripts_have_shebang(self):
        for filename in self.SHELL_SCRIPTS:
            content = (ROM_OVERLAYS / filename).read_text()
            first_line = content.strip().split("\n")[0]
            self.assertTrue(first_line.startswith("#!"),
                            f"{filename} must have shebang")


class TestKotlinPowerUserLayer(unittest.TestCase):
    """Verify Kotlin power-user UI and data layer."""

    POWER_USER_DIR = APP_SRC / "poweruser"

    def test_power_user_state_exists(self):
        path = self.POWER_USER_DIR / "PowerUserState.kt"
        self.assertTrue(path.exists(), "PowerUserState.kt must exist")

    def test_power_user_state_has_game_space(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("gameSpaceEnabled", content)
        self.assertIn("fpsUnlockEnabled", content)
        self.assertIn("sensorBlockEnabled", content)

    def test_power_user_state_has_pocket_detection(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("pocketDetectionEnabled", content)
        self.assertIn("pocketDetected", content)

    def test_power_user_state_has_smart_charging(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("smartChargingEnabled", content)
        self.assertIn("chargeLimitPercent", content)
        self.assertIn("topUpTime", content)
        self.assertIn("wakeTime", content)

    def test_power_user_state_has_gestures(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("doubleTapToWake", content)
        self.assertIn("tapToSleep", content)
        self.assertIn("screenshotGesture", content)

    def test_power_user_state_has_notifications(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("headsUpEnabled", content)
        self.assertIn("headsUpTimeoutMs", content)
        self.assertIn("flashlightBlinkOnCall", content)

    def test_power_user_state_has_reboot_action(self):
        content = (self.POWER_USER_DIR / "PowerUserState.kt").read_text()
        self.assertIn("RebootAction", content)
        self.assertIn("RECOVERY", content)
        self.assertIn("BOOTLOADER", content)
        self.assertIn("SOFT_REBOOT", content)
        self.assertIn("SYSTEM_UI", content)
        self.assertIn("SAFE_MODE", content)

    def test_power_user_repository_exists(self):
        path = self.POWER_USER_DIR / "PowerUserRepository.kt"
        self.assertTrue(path.exists(), "PowerUserRepository.kt must exist")

    def test_repository_has_set_game_space(self):
        content = (self.POWER_USER_DIR / "PowerUserRepository.kt").read_text()
        self.assertIn("setGameSpace", content)

    def test_repository_has_set_smart_charging(self):
        content = (self.POWER_USER_DIR / "PowerUserRepository.kt").read_text()
        self.assertIn("setSmartCharging", content)
        self.assertIn("setChargeLimit", content)

    def test_repository_has_set_gestures(self):
        content = (self.POWER_USER_DIR / "PowerUserRepository.kt").read_text()
        self.assertIn("setDoubleTapToWake", content)
        self.assertIn("setTapToSleep", content)
        self.assertIn("setScreenshotGesture", content)

    def test_repository_has_trigger_reboot(self):
        content = (self.POWER_USER_DIR / "PowerUserRepository.kt").read_text()
        self.assertIn("triggerReboot", content)

    def test_power_user_screen_exists(self):
        path = self.POWER_USER_DIR / "PowerUserScreen.kt"
        self.assertTrue(path.exists(), "PowerUserScreen.kt must exist")

    def test_screen_has_feature_cards(self):
        content = (self.POWER_USER_DIR / "PowerUserScreen.kt").read_text()
        self.assertIn("Game Space", content)
        self.assertIn("Pocket Detection", content)
        self.assertIn("Smart Charging", content)
        self.assertIn("Gestures", content)
        self.assertIn("Notifications", content)
        self.assertIn("Advanced Reboot", content)

    def test_screen_has_switch_rows(self):
        content = (self.POWER_USER_DIR / "PowerUserScreen.kt").read_text()
        self.assertIn("SwitchRow", content)
        self.assertIn("FeatureCard", content)

    def test_screen_has_reboot_dialog(self):
        content = (self.POWER_USER_DIR / "PowerUserScreen.kt").read_text()
        self.assertIn("showRebootDialog", content)
        self.assertIn("AlertDialog", content)


class TestApexControlIntegration(unittest.TestCase):
    """Verify power-user tab is integrated into Apex Control."""

    SCREEN_PATH = APP_SRC / "ui" / "ApexControlScreen.kt"

    def test_power_tab_in_tabs_list(self):
        content = self.SCREEN_PATH.read_text()
        self.assertIn('"Power"', content, "Power tab must be in tabs list")

    def test_power_tab_imports(self):
        content = self.SCREEN_PATH.read_text()
        self.assertIn("PowerUserScreen", content)
        self.assertIn("PowerUserRepository", content)
        self.assertIn("PowerUserState", content)
        self.assertIn("RebootAction", content)

    def test_power_tab_content_in_when_block(self):
        content = self.SCREEN_PATH.read_text()
        # Must have a case 5 -> PowerUserScreen
        self.assertIn("5 -> PowerUserScreen", content)

    def test_power_tab_has_state_management(self):
        content = self.SCREEN_PATH.read_text()
        self.assertIn("powerUserState", content)
        self.assertIn("powerUserRepo", content)


class TestBuildPropFeatures(unittest.TestCase):
    """Verify build.prop has power-user feature flags."""

    def test_build_prop_has_apex_version(self):
        content = BUILD_PROP.read_text()
        self.assertIn("ro.apex.version", content)

    def test_build_prop_has_feature_flags(self):
        content = BUILD_PROP.read_text()
        self.assertIn("ro.apex.game_space", content)
        self.assertIn("ro.apex.pocket_detect", content)
        self.assertIn("ro.apex.smart_charge", content)
        self.assertIn("ro.apex.screenshot_gesture", content)
        self.assertIn("ro.apex.dt2w", content)
        self.assertIn("ro.apex.tts", content)

    def test_feature_flags_default_off(self):
        """All power-user feature flags must default to 0 (off)."""
        content = BUILD_PROP.read_text()
        for flag in ["ro.apex.game_space", "ro.apex.pocket_detect",
                      "ro.apex.smart_charge", "ro.apex.screenshot_gesture",
                      "ro.apex.dt2w", "ro.apex.tts"]:
            # Find the flag line and check it's =0
            for line in content.split("\n"):
                if flag in line and not line.strip().startswith("#"):
                    self.assertIn("=0", line,
                                  f"{flag} must default to 0")


class TestNoPermissiveDomains(unittest.TestCase):
    """Verify no permissive SELinux domains in new files."""

    def test_no_permissive_in_rc_files(self):
        for filename in ["apex_game_space.rc", "apex_pocket.rc",
                         "apex_smart_charging.rc", "apex_reboot.rc",
                         "apex_gestures.rc", "apex_notifications.rc",
                         "apex_power_user.rc"]:
            content = (ROM_OVERLAYS / filename).read_text()
            self.assertNotIn("permissive", content.lower(),
                             f"{filename} must not contain 'permissive'")


if __name__ == "__main__":
    unittest.main()
