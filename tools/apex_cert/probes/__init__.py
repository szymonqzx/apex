"""apex_cert.probes — Read-only device probes.

Each probe is a reviewed shell command that collects facts from the device
without writing state.  Probes declare timeout, byte budget, and privilege.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from ..model import ProbeResult, EvidencePart
from ..errors import ProbeOutputInvalid, ProbeOutputEmpty


@dataclass
class Probe:
    """Definition of a read-only device probe."""
    name: str
    command: str
    timeout: float = 10.0
    byte_budget: int = 1024 * 1024
    root: bool = False
    description: str = ""

    def execute(self, executor) -> ProbeResult:
        """Run this probe via the ADB executor."""
        result = executor.shell(
            self.command,
            timeout=self.timeout,
            byte_budget=self.byte_budget,
            root=self.root,
        )
        pr = ProbeResult(
            probe_name=self.name,
            command=self.command,
            exit_code=result.exit_code,
            stdout=result.stdout,
            stderr=result.stderr,
            duration_ms=result.duration_ms,
            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            error=None if result.ok else result.stderr or f"exit {result.exit_code}",
        )
        return pr

    def to_part(self, result: ProbeResult) -> EvidencePart:
        """Convert a probe result to an evidence bundle part."""
        import json
        content = json.dumps(result.to_dict(), sort_keys=True).encode()
        return EvidencePart(
            name=f"probe_{self.name}",
            source="probe",
            content=content,
            metadata={
                "probe": self.name,
                "exit_code": result.exit_code,
                "duration_ms": result.duration_ms,
            },
        )


# ── Built-in probe catalog ───────────────────────────────────────────

INVENTORY_PROBES: list[Probe] = [
    Probe("device_info", "getprop ro.product.device", description="Device codename"),
    Probe("device_model", "getprop ro.product.model", description="Device model"),
    Probe("device_brand", "getprop ro.product.brand", description="Device brand"),
    Probe("android_version", "getprop ro.build.version.release", description="Android version"),
    Probe("kernel_version", "uname -r", description="Kernel version"),
    Probe("kernel_string", "cat /proc/version", description="Full kernel string"),
    Probe("build_fingerprint", "getprop ro.build.fingerprint", description="Build fingerprint"),
    Probe("bootloader", "getprop ro.bootloader", description="Bootloader version"),
    Probe("baseband", "getprop gsm.version.baseband", description="Baseband version"),
    Probe("cpu_info", "cat /proc/cpuinfo", description="CPU information", byte_budget=64 * 1024),
    Probe("meminfo", "cat /proc/meminfo", description="Memory info", byte_budget=32 * 1024),
    Probe("power_supply", "ls /sys/class/power_supply/", description="Power supply devices"),
    Probe("battery_capacity", "cat /sys/class/power_supply/battery/capacity", description="Battery SoC"),
    Probe("battery_status", "cat /sys/class/power_supply/battery/status", description="Battery status"),
    Probe("battery_health", "cat /sys/class/power_supply/battery/health", description="Battery health"),
    Probe("battery_technology", "cat /sys/class/power_supply/battery/technology", description="Battery technology"),
    Probe("charger_type", "cat /sys/class/qcom-battery/quick_charge_type 2>/dev/null || echo -1", description="Quick charge type"),
    Probe("thermal_zones", "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo -1", description="Thermal zone 0 temp"),
    Probe("apex_state", "cat /proc/apex/state 2>/dev/null || echo unavailable", description="Apex state machine"),
    Probe("apex_version", "cat /proc/apex/version 2>/dev/null || echo unavailable", description="Apex version"),
    Probe("apex_governor", "cat /proc/apex/governor 2>/dev/null || echo unavailable", description="Apex governor"),
    Probe("apex_health", "cat /proc/apex/health 2>/dev/null || echo unavailable", description="Apex health"),
    Probe("apex_charge_status", "cat /proc/apex_charge/status 2>/dev/null || echo unavailable", description="Apex charge status", root=False),
    Probe("wakeup_sources", "cat /sys/kernel/debug/wakeup_sources 2>/dev/null || echo unavailable", description="Wakelock sources", root=True, byte_budget=256 * 1024),
    Probe("boot_slot", "getprop ro.boot.slot_suffix", description="Active boot slot (A/B)"),
]

# Root-only probes (skipped if su unavailable)
ROOT_PROBES: list[Probe] = [
    Probe("dmesg_tail", "dmesg | tail -200", description="Recent kernel messages", root=True, byte_budget=64 * 1024),
    Probe("logcat_tail", "logcat -d -t 200", description="Recent logcat", root=True, byte_budget=64 * 1024),
]


def run_inventory(executor, *, include_root: bool = True) -> list[ProbeResult]:
    """Run the full inventory probe set."""
    results = []
    probes = list(INVENTORY_PROBES)
    if include_root:
        probes.extend(ROOT_PROBES)
    for probe in probes:
        try:
            results.append(probe.execute(executor))
        except Exception as e:
            results.append(ProbeResult(
                probe_name=probe.name,
                command=probe.command,
                exit_code=-1,
                error=str(e),
                timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            ))
    return results
