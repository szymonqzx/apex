"""apex_cert.gates — Host-authoritative gate graph with explicit waivers.

The gate evaluator maps evidence to gates, rejects implicit passes, records
waivers, and distinguishes CERTIFIED from CERTIFIED_WITH_WAIVERS.

A waiver cannot override artifact identity/hash/schema mismatch.  A waived
prerequisite never unlocks the associated unsafe device control automatically.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from .model import (
    GateResult, Waiver, TrustManifest, EvidenceBundle,
    ArtifactState, generate_run_id, sha256_bytes,
)
from .errors import GateEvidenceMissing, GateFailed, WaiverInvalid


# ── Gate definitions ─────────────────────────────────────────────────

@dataclass
class GateDef:
    """Definition of a certification gate."""
    name: str
    description: str
    required_probes: list[str] = field(default_factory=list)
    category: str = "general"  # "battery", "charging", "sms", "call", etc.


CERTIFICATION_GATES: list[GateDef] = [
    GateDef("battery_health", "Battery health and capacity",
            ["battery_capacity", "battery_health", "battery_technology"],
            category="battery"),
    GateDef("charging_basic", "Basic charging functionality",
            ["battery_status", "power_supply", "charger_type"],
            category="charging"),
    GateDef("thermal_sanity", "Thermal zone readings are sane",
            ["thermal_zones"],
            category="thermal"),
    GateDef("apex_state", "Apex state machine is responsive",
            ["apex_state", "apex_version"],
            category="apex"),
    GateDef("kernel_identity", "Kernel version and build match expected",
            ["kernel_version", "kernel_string", "build_fingerprint"],
            category="identity"),
    GateDef("device_identity", "Device codename and model match expected",
            ["device_info", "device_model", "device_brand"],
            category="identity"),
    GateDef("power_supply_topology", "Power supply devices are present",
            ["power_supply"],
            category="charging"),
    GateDef("boot_slot", "Boot slot information (A/B or legacy)",
            ["boot_slot"],
            category="boot"),
]


# ── Gate evaluation ──────────────────────────────────────────────────

def evaluate_gate(gate: GateDef, bundle: EvidenceBundle,
                  waiver: Waiver | None = None) -> GateResult:
    """Evaluate a single gate against the evidence bundle."""
    part_names = {p.name for p in bundle.parts}
    probe_names = {p.metadata.get("probe", p.name.replace("probe_", ""))
                   for p in bundle.parts}

    # Check if all required probes are present
    missing = []
    for req in gate.required_probes:
        probe_part = f"probe_{req}"
        if probe_part not in part_names and req not in probe_names:
            missing.append(req)

    if missing:
        if waiver:
            return GateResult(
                gate_name=gate.name,
                state="waived",
                waiver=waiver.to_dict(),
                detail=f"Missing evidence: {', '.join(missing)} (waived)",
            )
        raise GateEvidenceMissing(
            f"Gate '{gate.name}' missing evidence: {', '.join(missing)}",
            gate=gate.name,
        )

    # Check if any required probe errored
    errored = []
    for part in bundle.parts:
        if part.metadata.get("exit_code", 0) != 0:
            probe_name = part.metadata.get("probe", part.name)
            if probe_name in gate.required_probes:
                errored.append(probe_name)

    if errored:
        if waiver:
            return GateResult(
                gate_name=gate.name,
                state="waived",
                waiver=waiver.to_dict(),
                detail=f"Probe errors: {', '.join(errored)} (waived)",
            )
        return GateResult(
            gate_name=gate.name,
            state="fail",
            detail=f"Probe errors: {', '.join(errored)}",
        )

    return GateResult(
        gate_name=gate.name,
        state="pass",
        detail="All required probes present and successful",
    )


def evaluate_all(bundle: EvidenceBundle,
                 waivers: list[Waiver] | None = None,
                 gates: list[GateDef] | None = None) -> list[GateResult]:
    """Evaluate all gates against the evidence bundle."""
    gates = gates or CERTIFICATION_GATES
    waiver_map = {w.gate_name: w for w in (waivers or [])}
    results = []
    for gate in gates:
        waiver = waiver_map.get(gate.name)
        try:
            results.append(evaluate_gate(gate, bundle, waiver))
        except GateEvidenceMissing as e:
            if waiver:
                results.append(GateResult(
                    gate_name=gate.name,
                    state="waived",
                    waiver=waiver.to_dict(),
                    detail=str(e),
                ))
            else:
                # Record as missing (blocks promotion)
                results.append(GateResult(
                    gate_name=gate.name,
                    state="missing",
                    detail=str(e),
                ))
    return results


def compute_artifact_state(gate_results: list[GateResult]) -> ArtifactState:
    """Compute the artifact state from gate results."""
    has_missing = any(r.state == "missing" for r in gate_results)
    has_fail = any(r.state == "fail" for r in gate_results)
    has_waived = any(r.state == "waived" for r in gate_results)
    all_pass = all(r.state == "pass" for r in gate_results)

    if has_fail:
        return ArtifactState.FAILED
    if has_missing:
        return ArtifactState.PARTIAL
    if all_pass:
        return ArtifactState.CERTIFIED
    if has_waived and not has_missing and not has_fail:
        return ArtifactState.CERTIFIED_WITH_WAIVERS
    return ArtifactState.PARTIAL


def validate_waiver(waiver: Waiver) -> None:
    """Validate a waiver record.  Raises WaiverInvalid if incomplete."""
    if not waiver.reason or not waiver.reason.strip():
        raise WaiverInvalid("Waiver missing reason", field="reason")
    if not waiver.actor or not waiver.actor.strip():
        raise WaiverInvalid("Waiver missing actor", field="actor")
    if not waiver.scope or not waiver.scope.strip():
        raise WaiverInvalid("Waiver missing scope", field="scope")
    if waiver.scope not in ("run", "build", "gate"):
        raise WaiverInvalid(
            f"Invalid waiver scope: {waiver.scope} (must be run/build/gate)",
            field="scope",
        )


def build_manifest(bundle: EvidenceBundle,
                   gate_results: list[GateResult],
                   waivers: list[Waiver] | None = None) -> TrustManifest:
    """Build a trust manifest from gate results."""
    state = compute_artifact_state(gate_results)
    manifest = TrustManifest(
        manifest_id=generate_run_id(),
        run_id=bundle.run_id,
        build_hash=bundle.build_hash,
        profile_hash=bundle.profile_hash,
        artifact_state=state.value,
        gates=[{"gate_name": r.gate_name, "state": r.state,
                "detail": r.detail}
               for r in gate_results],
        waivers=[w.to_dict() for w in (waivers or [])],
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    manifest.manifest_hash = manifest.compute_hash()
    return manifest
