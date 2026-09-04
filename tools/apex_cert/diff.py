"""apex_cert.diff — Golden-snapshot differential diagnosis.

Compares a normalized bundle against a golden baseline and reports
meaningful subsystem changes.  Incompatible baselines (different device,
ROM, kernel, profile) are rejected.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from .model import EvidenceBundle, EvidencePart
from .errors import BaselineMissing, BaselineIncompatible, DiffInputInvalid


@dataclass
class DiffEntry:
    """A single difference between a bundle and its golden baseline."""
    part_name: str
    change_type: str  # "added", "removed", "modified"
    detail: str = ""
    golden_hash: str = ""
    candidate_hash: str = ""


@dataclass
class DiffReport:
    """Full differential report between golden and candidate bundles."""
    golden_run_id: str = ""
    candidate_run_id: str = ""
    compatible: bool = True
    incompatibility_reason: str = ""
    entries: list[DiffEntry] = field(default_factory=list)
    summary: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "golden_run_id": self.golden_run_id,
            "candidate_run_id": self.candidate_run_id,
            "compatible": self.compatible,
            "incompatibility_reason": self.incompatibility_reason,
            "entries": [
                {"part_name": e.part_name, "change_type": e.change_type,
                 "detail": e.detail, "golden_hash": e.golden_hash,
                 "candidate_hash": e.candidate_hash}
                for e in self.entries
            ],
            "summary": self.summary,
        }


def check_compatibility(golden: EvidenceBundle,
                        candidate: EvidenceBundle) -> tuple[bool, str]:
    """Check if golden and candidate bundles are compatible for diffing."""
    if golden.build_hash and candidate.build_hash:
        if golden.build_hash != candidate.build_hash:
            return False, f"Build hash mismatch: {golden.build_hash} vs {candidate.build_hash}"
    if golden.profile_hash and candidate.profile_hash:
        if golden.profile_hash != candidate.profile_hash:
            return False, f"Profile hash mismatch: {golden.profile_hash} vs {candidate.profile_hash}"
    return True, ""


def diff_bundles(golden: EvidenceBundle,
                 candidate: EvidenceBundle) -> DiffReport:
    """Compare a candidate bundle against a golden baseline.

    Both bundles should be normalized before diffing.
    """
    report = DiffReport(
        golden_run_id=golden.run_id,
        candidate_run_id=candidate.run_id,
    )

    compatible, reason = check_compatibility(golden, candidate)
    if not compatible:
        report.compatible = False
        report.incompatibility_reason = reason
        report.summary = f"Baseline incompatible: {reason}"
        return report

    golden_parts = {p.name: p for p in golden.parts}
    candidate_parts = {p.name: p for p in candidate.parts}

    all_names = set(golden_parts) | set(candidate_parts)

    for name in sorted(all_names):
        g = golden_parts.get(name)
        c = candidate_parts.get(name)

        if g and not c:
            report.entries.append(DiffEntry(
                part_name=name, change_type="removed",
                golden_hash=g.content_hash,
            ))
        elif c and not g:
            report.entries.append(DiffEntry(
                part_name=name, change_type="added",
                candidate_hash=c.content_hash,
            ))
        elif g.content_hash != c.content_hash:
            # Content differs — compare the actual content
            try:
                g_text = g.content.decode("utf-8", errors="replace")
                c_text = c.content.decode("utf-8", errors="replace")
                g_lines = set(g_text.splitlines())
                c_lines = set(c_text.splitlines())
                added = c_lines - g_lines
                removed = g_lines - c_lines
                detail_parts = []
                if added:
                    detail_parts.append(f"+{len(added)} lines")
                if removed:
                    detail_parts.append(f"-{len(removed)} lines")
                detail = ", ".join(detail_parts) if detail_parts else "content differs"
            except Exception:
                detail = "binary content differs"

            report.entries.append(DiffEntry(
                part_name=name, change_type="modified",
                detail=detail,
                golden_hash=g.content_hash,
                candidate_hash=c.content_hash,
            ))

    # Summary
    added = sum(1 for e in report.entries if e.change_type == "added")
    removed = sum(1 for e in report.entries if e.change_type == "removed")
    modified = sum(1 for e in report.entries if e.change_type == "modified")
    report.summary = (
        f"{added} added, {removed} removed, {modified} modified"
        if (added or removed or modified)
        else "no differences"
    )

    return report
