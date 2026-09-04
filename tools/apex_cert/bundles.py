"""apex_cert.bundles — Atomic parts, sealing, and SHA-256 inventory.

Bundle assembly writes parts atomically: each part is written to a temp
file, then renamed into place.  Sealing computes the bundle hash from all
part hashes.  Raw evidence is never mutated by migration, normalization,
or diff.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from .model import (
    EvidenceBundle, EvidencePart, generate_run_id, generate_boot_id,
    sha256_bytes, sha256_file, SCHEMA_VERSION,
)
from .errors import BundleWriteFailed, BundleIntegrityFailed


def create_bundle(*, build_hash: str = "", profile_hash: str = "",
                  boot_id: str = "") -> EvidenceBundle:
    """Create a new evidence bundle with a fresh run ID."""
    return EvidenceBundle(
        run_id=generate_run_id(),
        boot_id=boot_id or generate_boot_id(),
        build_hash=build_hash,
        profile_hash=profile_hash,
        timestamp=__import__("time").strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def add_part(bundle: EvidenceBundle, part: EvidencePart) -> None:
    """Add a part to the bundle (not yet sealed)."""
    bundle.add_part(part)


def seal_bundle(bundle: EvidenceBundle) -> str:
    """Seal the bundle: compute hash inventory, mark SEALED."""
    if not bundle.parts:
        raise BundleIntegrityFailed("Cannot seal a bundle with no parts")
    return bundle.seal()


def save_bundle(bundle: EvidenceBundle, output_dir: Path) -> Path:
    """Save a bundle's manifest and parts to disk atomically.

    Layout:
      output_dir/
        <run_id>/
          manifest.json     — bundle metadata + part inventory
          parts/
            <part_name>     — raw part content
    """
    if bundle.state != "SEALED":
        raise BundleIntegrityFailed(
            f"Cannot save unsealed bundle (state={bundle.state})"
        )

    bundle_dir = output_dir / bundle.run_id
    parts_dir = bundle_dir / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)

    # Write parts atomically
    for part in bundle.parts:
        part_path = parts_dir / part.name
        try:
            fd, tmp = tempfile.mkstemp(dir=parts_dir, prefix=f".{part.name}.")
            with os.fdopen(fd, "wb") as f:
                f.write(part.content)
            os.rename(tmp, part_path)
        except OSError as e:
            raise BundleWriteFailed(f"Failed to write part {part.name}: {e}")

    # Verify part hashes
    for part in bundle.parts:
        part_path = parts_dir / part.name
        actual_hash = sha256_file(part_path)
        if actual_hash != part.content_hash:
            raise BundleIntegrityFailed(
                f"Part {part.name} hash mismatch after write: "
                f"expected {part.content_hash}, got {actual_hash}"
            )

    # Write manifest
    manifest_path = bundle_dir / "manifest.json"
    manifest_data = bundle.to_json()
    fd, tmp = tempfile.mkstemp(dir=bundle_dir, prefix=".manifest.")
    with os.fdopen(fd, "w") as f:
        f.write(manifest_data)
    os.rename(tmp, manifest_path)

    return manifest_path


def load_bundle(bundle_dir: Path) -> EvidenceBundle:
    """Load a bundle from disk and verify integrity."""
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.exists():
        raise BundleIntegrityFailed(f"No manifest.json in {bundle_dir}")

    with open(manifest_path) as f:
        data = json.load(f)

    bundle = EvidenceBundle(
        schema_version=data.get("schema_version", SCHEMA_VERSION),
        run_id=data.get("run_id", ""),
        boot_id=data.get("boot_id", ""),
        build_hash=data.get("build_hash", ""),
        profile_hash=data.get("profile_hash", ""),
        timestamp=data.get("timestamp", ""),
        bundle_hash=data.get("bundle_hash", ""),
        state=data.get("state", "PARTIAL"),
        taint=data.get("taint", "CLEAN"),
    )

    parts_dir = bundle_dir / "parts"
    for part_data in data.get("parts", []):
        part_path = parts_dir / part_data["name"]
        if not part_path.exists():
            raise BundleIntegrityFailed(
                f"Missing part file: {part_path}"
            )
        content = part_path.read_bytes()
        actual_hash = sha256_bytes(content)
        if actual_hash != part_data["content_hash"]:
            raise BundleIntegrityFailed(
                f"Part {part_data['name']} hash mismatch: "
                f"expected {part_data['content_hash']}, got {actual_hash}"
            )
        bundle.add_part(EvidencePart(
            name=part_data["name"],
            source=part_data["source"],
            content=content,
            content_hash=part_data["content_hash"],
            metadata=part_data.get("metadata", {}),
        ))

    # Verify bundle hash
    if bundle.bundle_hash:
        expected = bundle.bundle_hash
        bundle.bundle_hash = ""  # clear to recompute
        actual = bundle.seal()
        if actual != expected:
            raise BundleIntegrityFailed(
                f"Bundle hash mismatch: expected {expected}, got {actual}"
            )

    return bundle
