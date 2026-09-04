"""apex_cert.normalize — Volatile-field normalization.

Normalizes volatile data (timestamps, PIDs, counters, ordering) so that
golden diffs show only meaningful subsystem changes.  Raw inputs are never
mutated — normalization creates a derivative.
"""

from __future__ import annotations

import re
from typing import Any

from .model import EvidenceBundle, EvidencePart, sha256_bytes
from .errors import NormalizationFailed


# Patterns that match volatile values in probe output
VOLATILE_PATTERNS = [
    # Timestamps: 1234567890, 1234567890.123
    (re.compile(r"\b\d{10,13}(?:\.\d+)?\b"), "<ts>"),
    # PIDs: pid=1234
    (re.compile(r"\bpid=\d+\b"), "pid=<pid>"),
    # Uptime: uptime 12345.67
    (re.compile(r"\buptime\s+[\d.]+"), "uptime <val>"),
    # Active since: active_since=1234567
    (re.compile(r"active_since=\d+"), "active_since=<val>"),
    # Last time: last_time=1234567
    (re.compile(r"last_time=\d+"), "last_time=<val>"),
    # Preventing since: preventing_since=1234567
    (re.compile(r"preventing_since=\d+"), "preventing_since=<val>"),
    # Wakeup count: wakeup_count=123
    (re.compile(r"wakeup_count=\d+"), "wakeup_count=<val>"),
    # Memory addresses: 0xffff8000abcd
    (re.compile(r"\b0x[0-9a-f]{8,16}\b"), "<addr>"),
    # Sequence numbers: seq=12345
    (re.compile(r"\bseq=\d+\b"), "seq=<seq>"),
]


def normalize_text(text: str) -> str:
    """Normalize volatile fields in a text string."""
    result = text
    for pattern, replacement in VOLATILE_PATTERNS:
        result = pattern.sub(replacement, result)
    return result


def normalize_part(part: EvidencePart) -> EvidencePart:
    """Create a normalized derivative of an evidence part.

    The original part is never mutated.  The derivative references the
    original's hash in its metadata.
    """
    try:
        text = part.content.decode("utf-8", errors="replace")
    except Exception:
        # Binary content — don't normalize
        return EvidencePart(
            name=f"normalized_{part.name}",
            source=part.source,
            content=part.content,
            metadata={**part.metadata, "normalized_from": part.content_hash},
        )

    normalized = normalize_text(text).encode()
    return EvidencePart(
        name=f"normalized_{part.name}",
        source=part.source,
        content=normalized,
        metadata={
            **part.metadata,
            "normalized_from": part.content_hash,
            "normalization": "volatile_fields_removed",
        },
    )


def normalize_bundle(bundle: EvidenceBundle) -> EvidenceBundle:
    """Create a normalized derivative bundle.  Raw bundle is never mutated."""
    normalized = EvidenceBundle(
        schema_version=bundle.schema_version,
        run_id=bundle.run_id,
        boot_id=bundle.boot_id,
        build_hash=bundle.build_hash,
        profile_hash=bundle.profile_hash,
        timestamp=bundle.timestamp,
        state="NORMALIZED",
        taint=bundle.taint,
    )
    for part in bundle.parts:
        normalized.add_part(normalize_part(part))
    return normalized
