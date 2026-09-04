"""apex_cert.package — Slot-aware canary boot orchestration.

Manages A/B slot switching, canary boot health checks, and fallback
activation.  Destructive operations require explicit rehearsal.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from .errors import (
    BootControlUnsupported, CanaryRehearsalRequired, CanaryHealthTimeout,
    PackageIdentityMismatch,
)


@dataclass
class SlotInfo:
    """A/B boot slot information."""
    active: str  # "a" or "b"
    inactive: str  # the other slot
    suffix: str  # "_a" or "_b"


def get_slot_info(executor) -> SlotInfo:
    """Query the device for active/inactive boot slots."""
    result = executor.shell("getprop ro.boot.slot_suffix")
    suffix = result.stdout.strip()
    if not suffix:
        raise BootControlUnsupported(
            "Device does not support A/B boot slots (no slot_suffix)"
        )
    active = suffix.strip("_")
    inactive = "b" if active == "a" else "a"
    return SlotInfo(active=active, inactive=inactive, suffix=suffix)


def set_active_slot(executor, slot: str, *, rehearsal: bool = False) -> str:
    """Set the active boot slot.  Requires explicit rehearsal flag."""
    if not rehearsal:
        raise CanaryRehearsalRequired(
            f"Setting active slot to {slot} requires explicit rehearsal. "
            f"Pass rehearsal=True to proceed."
        )
    result = executor.shell(f"bootctl set-active-boot-slot {slot}")
    if result.exit_code != 0:
        raise BootControlUnsupported(
            f"Failed to set active boot slot: {result.stderr}"
        )
    return slot


def canary_health_check(executor, *,
                        timeout: float = 120.0,
                        poll_interval: float = 5.0) -> dict[str, Any]:
    """Check canary boot health after a slot switch.

    Polls device responsiveness until timeout.
    """
    start = time.monotonic()
    checks: list[dict[str, Any]] = []

    while time.monotonic() - start < timeout:
        try:
            result = executor.shell("getprop sys.boot_completed", timeout=5)
            boot_completed = result.stdout.strip() == "1"
            checks.append({
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "boot_completed": boot_completed,
                "exit_code": result.exit_code,
            })
            if boot_completed:
                # Additional health: check apex state
                apex_result = executor.shell(
                    "cat /proc/apex/state 2>/dev/null || echo unavailable",
                    timeout=5,
                )
                return {
                    "healthy": True,
                    "boot_completed": True,
                    "apex_state": apex_result.stdout.strip(),
                    "checks": checks,
                    "elapsed_s": time.monotonic() - start,
                }
        except Exception as e:
            checks.append({
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "error": str(e),
            })
        time.sleep(poll_interval)

    raise CanaryHealthTimeout(
        f"Canary health check timed out after {timeout}s",
    )


def activate_canary(executor, *,
                    rehearsal: bool = False,
                    health_timeout: float = 120.0) -> dict[str, Any]:
    """Full canary activation: switch slot, reboot, health check.

    This is a destructive operation requiring explicit rehearsal.
    """
    if not rehearsal:
        raise CanaryRehearsalRequired(
            "Canary activation is destructive. Pass rehearsal=True to proceed."
        )

    slot_info = get_slot_info(executor)
    target_slot = slot_info.inactive

    # Set inactive slot as active
    set_active_slot(executor, target_slot, rehearsal=True)

    # Reboot
    executor.shell("reboot", timeout=5)

    # Wait for device to come back
    time.sleep(10)

    # Health check
    health = canary_health_check(executor, timeout=health_timeout)
    health["target_slot"] = target_slot
    health["previous_slot"] = slot_info.active
    return health


def verify_identity(*, build_hash: str, profile_hash: str,
                    expected_build: str, expected_profile: str) -> None:
    """Verify artifact identity matches expected build and profile."""
    if build_hash != expected_build:
        raise PackageIdentityMismatch(
            f"Build hash mismatch: artifact={build_hash}, expected={expected_build}"
        )
    if profile_hash != expected_profile:
        raise PackageIdentityMismatch(
            f"Profile hash mismatch: artifact={profile_hash}, expected={expected_profile}"
        )
