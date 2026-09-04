"""apex_cert.report — Human-readable certification report generation."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .model import EvidenceBundle, TrustManifest, CapabilityProfile
from .diff import DiffReport


def generate_report(bundle: EvidenceBundle,
                    manifest: TrustManifest | None = None,
                    profile: CapabilityProfile | None = None,
                    diff: DiffReport | None = None) -> str:
    """Generate a human-readable certification report."""
    lines = []
    lines.append("=" * 60)
    lines.append("APEX Device Reliability Lab — Certification Report")
    lines.append("=" * 60)
    lines.append("")
    lines.append(f"Run ID:          {bundle.run_id}")
    lines.append(f"Boot ID:         {bundle.boot_id}")
    lines.append(f"Timestamp:       {bundle.timestamp}")
    lines.append(f"Schema Version:  {bundle.schema_version}")
    lines.append(f"Bundle Hash:     {bundle.bundle_hash}")
    lines.append(f"Bundle State:    {bundle.state}")
    lines.append(f"Bundle Taint:    {bundle.taint}")
    lines.append(f"Build Hash:      {bundle.build_hash or '(none)'}")
    lines.append(f"Profile Hash:    {bundle.profile_hash or '(none)'}")
    lines.append(f"Parts:           {len(bundle.parts)}")
    lines.append("")

    if profile:
        lines.append("--- Capability Profile ---")
        lines.append(f"Device:          {profile.device}")
        lines.append(f"Topology:        {profile.topology}")
        lines.append(f"Profile Hash:    {profile.profile_hash}")
        lines.append(f"Approved:        {profile.approved}")
        if profile.approved:
            lines.append(f"Approved By:     {profile.approved_by}")
            lines.append(f"Approved At:     {profile.approved_at}")
        lines.append(f"Fields:          {len(profile.fields)}")
        lines.append("")

    if manifest:
        lines.append("--- Trust Manifest ---")
        lines.append(f"Manifest ID:     {manifest.manifest_id}")
        lines.append(f"Artifact State:  {manifest.artifact_state}")
        lines.append(f"Manifest Hash:   {manifest.manifest_hash}")
        lines.append(f"Gates:           {len(manifest.gates)}")
        lines.append(f"Waivers:         {len(manifest.waivers)}")
        lines.append("")

        lines.append("--- Gate Results ---")
        for gate in manifest.gates:
            state_marker = {
                "pass": "[PASS]",
                "fail": "[FAIL]",
                "missing": "[MISSING]",
                "waived": "[WAIVED]",
            }.get(gate.get("state", ""), "[????]")
            lines.append(f"  {state_marker} {gate['gate_name']}: {gate.get('detail', '')}")
        lines.append("")

        if manifest.waivers:
            lines.append("--- Waivers ---")
            for w in manifest.waivers:
                lines.append(f"  {w['gate_name']}: {w['reason']} (by {w['actor']})")
            lines.append("")

    if diff:
        lines.append("--- Golden Differential ---")
        lines.append(f"Golden Run:      {diff.golden_run_id}")
        lines.append(f"Candidate Run:   {diff.candidate_run_id}")
        lines.append(f"Compatible:      {diff.compatible}")
        if not diff.compatible:
            lines.append(f"Incompatibility: {diff.incompatibility_reason}")
        lines.append(f"Summary:         {diff.summary}")
        lines.append("")

        if diff.entries:
            lines.append("--- Diff Entries ---")
            for entry in diff.entries:
                marker = {
                    "added": "[+]",
                    "removed": "[-]",
                    "modified": "[~]",
                }.get(entry.change_type, "[?]")
                lines.append(f"  {marker} {entry.part_name}: {entry.detail}")
            lines.append("")

    lines.append("=" * 60)
    return "\n".join(lines)


def save_report(report: str, output_dir: Path, run_id: str) -> Path:
    """Save a report to disk."""
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"report_{run_id}.txt"
    path.write_text(report)
    return path
