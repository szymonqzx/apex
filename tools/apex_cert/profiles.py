"""apex_cert.profiles — Capability profile draft/approve/hash/match.

Profiles are generated from observed evidence with field-level provenance.
Approval is invalidated by any content/hash change.  Topology matching
forces observe-only on mismatch.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .model import (
    CapabilityProfile, ProfileField, sha256_bytes, SCHEMA_VERSION,
)
from .errors import (
    ProfileEvidenceMissing, ProfileConflict, ProfileHashChanged,
    CapabilityMismatch,
)


def draft_profile(device: str, topology: str,
                  fields: list[ProfileField]) -> CapabilityProfile:
    """Create a draft capability profile from observed fields."""
    profile = CapabilityProfile(
        schema_version=SCHEMA_VERSION,
        device=device,
        topology=topology,
        fields=fields,
    )
    profile.profile_hash = profile.compute_hash()
    return profile


def approve_profile(profile: CapabilityProfile, *,
                    actor: str,
                    expected_hash: str | None = None) -> CapabilityProfile:
    """Approve a profile.  Raises if the hash changed since review."""
    current_hash = profile.compute_hash()
    if expected_hash is not None and current_hash != expected_hash:
        raise ProfileHashChanged(
            f"Profile hash changed after review: "
            f"expected {expected_hash}, got {current_hash}"
        )
    profile.profile_hash = current_hash
    profile.approved = True
    profile.approved_by = actor
    profile.approved_at = time.strftime("%Y-%m-%dT%H:%M:%SZ")
    return profile


def verify_profile(profile: CapabilityProfile) -> bool:
    """Verify that a profile's stored hash matches its content."""
    return profile.compute_hash() == profile.profile_hash


def match_topology(profile: CapabilityProfile,
                   device: str, topology: str) -> None:
    """Check if a device's topology matches the profile.

    Raises CapabilityMismatch if they don't match.
    """
    if profile.device != device:
        raise CapabilityMismatch(
            f"Device mismatch: profile={profile.device}, actual={device}",
            expected=profile.device, actual=device,
        )
    if profile.topology != topology:
        raise CapabilityMismatch(
            f"Topology mismatch: profile={profile.topology}, actual={topology}",
            expected=profile.topology, actual=topology,
        )


def save_profile(profile: CapabilityProfile, output_dir: Path) -> Path:
    """Save a profile to disk."""
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"profile_{profile.device}_{profile.profile_hash[:12]}.json"
    path.write_text(profile.to_json())
    return path


def load_profile(path: Path) -> CapabilityProfile:
    """Load a profile from disk and verify its hash."""
    data = json.loads(path.read_text())
    fields = [
        ProfileField(
            name=f["name"], value=f["value"],
            provenance=f["provenance"], source=f["source"],
            approved=f.get("approved", False),
        )
        for f in data.get("fields", [])
    ]
    profile = CapabilityProfile(
        schema_version=data.get("schema_version", SCHEMA_VERSION),
        profile_id=data.get("profile_id", ""),
        device=data.get("device", ""),
        topology=data.get("topology", ""),
        fields=fields,
        profile_hash=data.get("profile_hash", ""),
        approved=data.get("approved", False),
        approved_by=data.get("approved_by", ""),
        approved_at=data.get("approved_at", ""),
    )
    if not verify_profile(profile):
        raise ProfileHashChanged(
            f"Profile hash mismatch on load: stored={profile.profile_hash}, "
            f"computed={profile.compute_hash()}"
        )
    return profile
