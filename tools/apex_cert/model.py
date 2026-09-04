"""apex_cert.model — Versioned domain types for the certification platform.

All artifacts (evidence bundles, trust manifests, profiles, gate results)
carry a schema version.  The tool reads supported old versions and writes
the current version.  Migrations create derivatives and never rewrite raw
evidence.
"""

from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Any

# ── Schema versioning ────────────────────────────────────────────────

SCHEMA_VERSION = "1.0"
SUPPORTED_VERSIONS = ("1.0",)


class ArtifactState(str, Enum):
    """Certification artifact state machine."""
    UNVERIFIED = "UNVERIFIED"
    OBSERVE_ONLY = "OBSERVE_ONLY"
    PARTIAL = "PARTIAL"
    CANDIDATE = "CANDIDATE"
    CERTIFIED = "CERTIFIED"
    CERTIFIED_WITH_WAIVERS = "CERTIFIED_WITH_WAIVERS"
    FAILED = "FAILED"
    INVALID = "INVALID"
    STALE = "STALE"
    ROLLED_BACK = "ROLLED_BACK"


class HILRunState(str, Enum):
    """HIL run state machine."""
    PLANNED = "PLANNED"
    PREFLIGHT = "PREFLIGHT"
    RUNNING = "RUNNING"
    SEALED = "SEALED"
    EVALUATED = "EVALUATED"
    ABORTED = "ABORTED"
    PARTIAL = "PARTIAL"
    REJECTED = "REJECTED"
    CANCELLED = "CANCELLED"


class RunTaint(str, Enum):
    """Whether a run contains arbitrary-command evidence."""
    CLEAN = "CLEAN"
    TAINTED = "TAINTED"


# ── Identity ─────────────────────────────────────────────────────────

def generate_run_id() -> str:
    """Generate a unique, sortable run ID."""
    return f"{time.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"


def generate_boot_id() -> str:
    """Generate a boot-scoped ID."""
    return uuid.uuid4().hex


def sha256_bytes(data: bytes) -> str:
    """Compute SHA-256 of exact stored bytes (no canonicalization)."""
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    """Compute SHA-256 of a file's exact bytes, streaming."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


# ── Evidence bundle ──────────────────────────────────────────────────

@dataclass
class ProbeResult:
    """Result of a single probe execution."""
    probe_name: str
    command: str
    exit_code: int
    stdout: str = ""
    stderr: str = ""
    duration_ms: int = 0
    timestamp: str = ""
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class EvidencePart:
    """A single part of an evidence bundle."""
    name: str
    source: str  # "probe" or "command" or "arbitrary"
    content: bytes
    content_hash: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        if not self.content_hash:
            self.content_hash = sha256_bytes(self.content)


@dataclass
class EvidenceBundle:
    """A sealed evidence bundle with SHA-256 inventory."""
    schema_version: str = SCHEMA_VERSION
    run_id: str = ""
    boot_id: str = ""
    build_hash: str = ""
    profile_hash: str = ""
    timestamp: str = ""
    parts: list[EvidencePart] = field(default_factory=list)
    bundle_hash: str = ""
    state: str = "PARTIAL"  # PARTIAL or SEALED
    taint: str = "CLEAN"

    def add_part(self, part: EvidencePart) -> None:
        self.parts.append(part)

    def seal(self) -> str:
        """Compute the bundle hash from all part hashes and mark sealed."""
        if not self.parts:
            from .errors import BundleIntegrityFailed
            raise BundleIntegrityFailed("Cannot seal a bundle with no parts")
        h = hashlib.sha256()
        h.update(self.schema_version.encode())
        h.update(self.run_id.encode())
        for part in sorted(self.parts, key=lambda p: p.name):
            h.update(part.name.encode())
            h.update(part.content_hash.encode())
        self.bundle_hash = h.hexdigest()
        self.state = "SEALED"
        return self.bundle_hash

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "run_id": self.run_id,
            "boot_id": self.boot_id,
            "build_hash": self.build_hash,
            "profile_hash": self.profile_hash,
            "timestamp": self.timestamp,
            "bundle_hash": self.bundle_hash,
            "state": self.state,
            "taint": self.taint,
            "parts": [
                {
                    "name": p.name,
                    "source": p.source,
                    "content_hash": p.content_hash,
                    "metadata": p.metadata,
                }
                for p in self.parts
            ],
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True)


# ── Trust manifest ───────────────────────────────────────────────────

@dataclass
class TrustManifest:
    """Trust manifest issued by the host gate evaluator."""
    schema_version: str = SCHEMA_VERSION
    manifest_id: str = ""
    run_id: str = ""
    build_hash: str = ""
    profile_hash: str = ""
    artifact_state: str = "UNVERIFIED"
    gates: list[dict[str, Any]] = field(default_factory=list)
    waivers: list[dict[str, Any]] = field(default_factory=list)
    evidence_age_hours: float = 0.0
    manifest_hash: str = ""
    timestamp: str = ""

    def compute_hash(self) -> str:
        d = self.to_dict()
        d.pop("manifest_hash", None)
        return sha256_bytes(json.dumps(d, sort_keys=True).encode())

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True)


# ── Capability profile ───────────────────────────────────────────────

@dataclass
class ProfileField:
    """A single field in a capability profile with provenance."""
    name: str
    value: Any
    provenance: str  # "observed", "stock-derived", "manual"
    source: str  # URL, file:line, or "user stated"
    approved: bool = False


@dataclass
class CapabilityProfile:
    """A generated, hashed, approved capability profile."""
    schema_version: str = SCHEMA_VERSION
    profile_id: str = ""
    device: str = ""
    topology: str = ""
    fields: list[ProfileField] = field(default_factory=list)
    profile_hash: str = ""
    approved: bool = False
    approved_by: str = ""
    approved_at: str = ""

    def compute_hash(self) -> str:
        """Hash exact stored bytes of the profile's JSON representation."""
        d = self.to_dict()
        d.pop("profile_hash", None)
        d.pop("approved", None)
        d.pop("approved_by", None)
        d.pop("approved_at", None)
        return sha256_bytes(json.dumps(d, sort_keys=True).encode())

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "profile_id": self.profile_id,
            "device": self.device,
            "topology": self.topology,
            "fields": [asdict(f) for f in self.fields],
            "profile_hash": self.profile_hash,
            "approved": self.approved,
            "approved_by": self.approved_by,
            "approved_at": self.approved_at,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True)


# ── Gate ─────────────────────────────────────────────────────────────

@dataclass
class GateResult:
    """Result of evaluating a single certification gate."""
    gate_name: str
    state: str  # "pass", "fail", "missing", "waived"
    evidence_hash: str = ""
    waiver: dict[str, Any] | None = None
    detail: str = ""


@dataclass
class Waiver:
    """An explicit waiver for a failed or missing gate."""
    gate_name: str
    reason: str
    actor: str
    scope: str  # "run", "build", "gate"
    timestamp: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
