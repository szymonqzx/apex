#!/usr/bin/env python3
"""Comprehensive unit tests for the apex_cert platform.

Tests the full certification pipeline: bundle creation, sealing, hashing,
normalization, diffing, gate evaluation, profile management, and report
generation — all without a real device (using mock evidence).
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add the repo root to path so we can import tools.apex_cert
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.apex_cert.model import (
    EvidenceBundle, EvidencePart, CapabilityProfile, ProfileField,
    TrustManifest, Waiver, GateResult, ArtifactState, RunTaint,
    generate_run_id, sha256_bytes, SCHEMA_VERSION,
)
from tools.apex_cert.errors import (
    ApexCertError, BundleIntegrityFailed, ProfileHashChanged,
    CapabilityMismatch, GateEvidenceMissing, WaiverInvalid,
    BaselineIncompatible, CommandRiskUnknown, CommandNotApproved,
    BootControlUnsupported, CanaryRehearsalRequired,
)
from tools.apex_cert.bundles import (
    create_bundle, add_part, seal_bundle, save_bundle, load_bundle,
)
from tools.apex_cert.normalize import normalize_text, normalize_part, normalize_bundle
from tools.apex_cert.diff import diff_bundles, check_compatibility
from tools.apex_cert.gates import (
    evaluate_gate, evaluate_all, compute_artifact_state,
    validate_waiver, build_manifest, CERTIFICATION_GATES, GateDef,
)
from tools.apex_cert.profiles import (
    draft_profile, approve_profile, verify_profile, match_topology,
    save_profile, load_profile,
)
from tools.apex_cert.commands import classify_risk, RiskLevel, requires_confirmation
from tools.apex_cert.report import generate_report


class TestModel(unittest.TestCase):

    def test_generate_run_id_is_unique(self):
        ids = {generate_run_id() for _ in range(100)}
        self.assertEqual(len(ids), 100)

    def test_sha256_bytes_deterministic(self):
        self.assertEqual(sha256_bytes(b"hello"), sha256_bytes(b"hello"))
        self.assertNotEqual(sha256_bytes(b"hello"), sha256_bytes(b"world"))

    def test_evidence_part_auto_hashes(self):
        part = EvidencePart(name="test", source="probe", content=b"data")
        self.assertTrue(part.content_hash)
        self.assertEqual(part.content_hash, sha256_bytes(b"data"))

    def test_bundle_seal_computes_hash(self):
        bundle = EvidenceBundle(run_id="test-123")
        bundle.add_part(EvidencePart(name="a", source="probe", content=b"foo"))
        bundle.add_part(EvidencePart(name="b", source="probe", content=b"bar"))
        h = bundle.seal()
        self.assertTrue(h)
        self.assertEqual(bundle.state, "SEALED")

    def test_bundle_seal_order_independent(self):
        """Bundle hash should be the same regardless of part insertion order."""
        b1 = EvidenceBundle(run_id="test")
        b1.add_part(EvidencePart(name="a", source="probe", content=b"foo"))
        b1.add_part(EvidencePart(name="b", source="probe", content=b"bar"))
        b1.seal()

        b2 = EvidenceBundle(run_id="test")
        b2.add_part(EvidencePart(name="b", source="probe", content=b"bar"))
        b2.add_part(EvidencePart(name="a", source="probe", content=b"foo"))
        b2.seal()

        self.assertEqual(b1.bundle_hash, b2.bundle_hash)

    def test_bundle_seal_empty_raises(self):
        bundle = EvidenceBundle(run_id="test")
        with self.assertRaises(BundleIntegrityFailed):
            bundle.seal()

    def test_schema_version_is_string(self):
        self.assertIsInstance(SCHEMA_VERSION, str)


class TestBundles(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_create_bundle_has_run_id(self):
        bundle = create_bundle()
        self.assertTrue(bundle.run_id)
        self.assertEqual(bundle.state, "PARTIAL")

    def test_seal_and_save_roundtrip(self):
        bundle = create_bundle(build_hash="abc123")
        add_part(bundle, EvidencePart(name="probe_test", source="probe",
                                       content=b'{"exit_code": 0}'))
        seal_bundle(bundle)
        path = save_bundle(bundle, Path(self.tmpdir))
        self.assertTrue(path.exists())

        loaded = load_bundle(path.parent)
        self.assertEqual(loaded.run_id, bundle.run_id)
        self.assertEqual(loaded.bundle_hash, bundle.bundle_hash)
        self.assertEqual(len(loaded.parts), 1)
        self.assertEqual(loaded.parts[0].content, b'{"exit_code": 0}')

    def test_load_bundle_detects_hash_mismatch(self):
        bundle = create_bundle()
        add_part(bundle, EvidencePart(name="test", source="probe", content=b"original"))
        seal_bundle(bundle)
        path = save_bundle(bundle, Path(self.tmpdir))

        # Tamper with the part file
        part_path = path.parent / "parts" / "test"
        part_path.write_bytes(b"tampered")

        with self.assertRaises(BundleIntegrityFailed):
            load_bundle(path.parent)

    def test_save_unsealed_bundle_raises(self):
        bundle = create_bundle()
        add_part(bundle, EvidencePart(name="test", source="probe", content=b"data"))
        with self.assertRaises(BundleIntegrityFailed):
            save_bundle(bundle, Path(self.tmpdir))


class TestNormalize(unittest.TestCase):

    def test_normalize_replaces_timestamps(self):
        text = "uptime 1234567890"
        normalized = normalize_text(text)
        self.assertNotIn("1234567890", normalized)

    def test_normalize_replaces_pids(self):
        text = "pid=1234 started"
        normalized = normalize_text(text)
        self.assertIn("<pid>", normalized)
        self.assertNotIn("1234", normalized)

    def test_normalize_preserves_non_volatile(self):
        text = "ro.build.product=topaz"
        normalized = normalize_text(text)
        self.assertEqual(normalized, text)

    def test_normalize_part_creates_derivative(self):
        original = EvidencePart(name="test", source="probe",
                                content=b"uptime 1234567890")
        normalized = normalize_part(original)
        self.assertNotEqual(normalized.content_hash, original.content_hash)
        self.assertIn("normalized_from", normalized.metadata)
        self.assertEqual(normalized.metadata["normalized_from"],
                         original.content_hash)

    def test_normalize_bundle_preserves_original(self):
        bundle = create_bundle()
        add_part(bundle, EvidencePart(name="test", source="probe",
                                       content=b"uptime 1234567890"))
        original_hash = bundle.parts[0].content_hash
        normalize_bundle(bundle)
        # Original bundle should be unchanged
        self.assertEqual(bundle.parts[0].content_hash, original_hash)


class TestDiff(unittest.TestCase):

    def _make_bundle(self, run_id: str, parts: dict[str, bytes],
                     build_hash: str = "same") -> EvidenceBundle:
        bundle = EvidenceBundle(run_id=run_id, build_hash=build_hash)
        for name, content in parts.items():
            bundle.add_part(EvidencePart(name=name, source="probe",
                                         content=content))
        bundle.seal()
        return bundle

    def test_identical_bundles_no_diff(self):
        golden = self._make_bundle("g", {"a": b"foo", "b": b"bar"})
        candidate = self._make_bundle("c", {"a": b"foo", "b": b"bar"})
        report = diff_bundles(golden, candidate)
        self.assertTrue(report.compatible)
        self.assertEqual(len(report.entries), 0)

    def test_added_part(self):
        golden = self._make_bundle("g", {"a": b"foo"})
        candidate = self._make_bundle("c", {"a": b"foo", "b": b"bar"})
        report = diff_bundles(golden, candidate)
        added = [e for e in report.entries if e.change_type == "added"]
        self.assertEqual(len(added), 1)
        self.assertEqual(added[0].part_name, "b")

    def test_removed_part(self):
        golden = self._make_bundle("g", {"a": b"foo", "b": b"bar"})
        candidate = self._make_bundle("c", {"a": b"foo"})
        report = diff_bundles(golden, candidate)
        removed = [e for e in report.entries if e.change_type == "removed"]
        self.assertEqual(len(removed), 1)

    def test_modified_part(self):
        golden = self._make_bundle("g", {"a": b"foo"})
        candidate = self._make_bundle("c", {"a": b"bar"})
        report = diff_bundles(golden, candidate)
        modified = [e for e in report.entries if e.change_type == "modified"]
        self.assertEqual(len(modified), 1)

    def test_incompatible_build_hash(self):
        golden = self._make_bundle("g", {"a": b"foo"}, build_hash="v1")
        candidate = self._make_bundle("c", {"a": b"foo"}, build_hash="v2")
        report = diff_bundles(golden, candidate)
        self.assertFalse(report.compatible)
        self.assertIn("Build hash mismatch", report.incompatibility_reason)


class TestGates(unittest.TestCase):

    def _make_bundle_with_probes(self, probe_names: list[str],
                                  errored: list[str] | None = None) -> EvidenceBundle:
        errored = errored or []
        bundle = EvidenceBundle(run_id="test")
        for name in probe_names:
            exit_code = -1 if name in errored else 0
            content = json.dumps({"probe_name": name, "exit_code": exit_code}).encode()
            bundle.add_part(EvidencePart(
                name=f"probe_{name}",
                source="probe",
                content=content,
                metadata={"probe": name, "exit_code": exit_code},
            ))
        bundle.seal()
        return bundle

    def test_gate_passes_with_all_evidence(self):
        gate = GateDef("test_gate", "Test", required_probes=["a", "b"])
        bundle = self._make_bundle_with_probes(["a", "b"])
        result = evaluate_gate(gate, bundle)
        self.assertEqual(result.state, "pass")

    def test_gate_fails_with_missing_evidence(self):
        gate = GateDef("test_gate", "Test", required_probes=["a", "b", "c"])
        bundle = self._make_bundle_with_probes(["a", "b"])
        with self.assertRaises(GateEvidenceMissing):
            evaluate_gate(gate, bundle)

    def test_gate_fails_with_errored_probe(self):
        gate = GateDef("test_gate", "Test", required_probes=["a"])
        bundle = self._make_bundle_with_probes(["a"], errored=["a"])
        result = evaluate_gate(gate, bundle)
        self.assertEqual(result.state, "fail")

    def test_gate_waived_when_waiver_provided(self):
        gate = GateDef("test_gate", "Test", required_probes=["a", "b"])
        bundle = self._make_bundle_with_probes(["a"])  # missing "b"
        waiver = Waiver(gate_name="test_gate", reason="probe b unavailable",
                        actor="tester", scope="run")
        result = evaluate_gate(gate, bundle, waiver=waiver)
        self.assertEqual(result.state, "waived")

    def test_compute_artifact_state_all_pass(self):
        results = [
            GateResult("a", "pass"),
            GateResult("b", "pass"),
        ]
        state = compute_artifact_state(results)
        self.assertEqual(state, ArtifactState.CERTIFIED)

    def test_compute_artifact_state_with_waiver(self):
        results = [
            GateResult("a", "pass"),
            GateResult("b", "waived", waiver={"gate_name": "b"}),
        ]
        state = compute_artifact_state(results)
        self.assertEqual(state, ArtifactState.CERTIFIED_WITH_WAIVERS)

    def test_compute_artifact_state_with_fail(self):
        results = [
            GateResult("a", "pass"),
            GateResult("b", "fail"),
        ]
        state = compute_artifact_state(results)
        self.assertEqual(state, ArtifactState.FAILED)

    def test_compute_artifact_state_with_missing(self):
        results = [
            GateResult("a", "pass"),
            GateResult("b", "missing"),
        ]
        state = compute_artifact_state(results)
        self.assertEqual(state, ArtifactState.PARTIAL)

    def test_validate_waiver_requires_reason(self):
        waiver = Waiver(gate_name="g", reason="", actor="a", scope="run")
        with self.assertRaises(WaiverInvalid):
            validate_waiver(waiver)

    def test_validate_waiver_requires_actor(self):
        waiver = Waiver(gate_name="g", reason="r", actor="", scope="run")
        with self.assertRaises(WaiverInvalid):
            validate_waiver(waiver)

    def test_validate_waiver_invalid_scope(self):
        waiver = Waiver(gate_name="g", reason="r", actor="a", scope="invalid")
        with self.assertRaises(WaiverInvalid):
            validate_waiver(waiver)

    def test_build_manifest_computes_hash(self):
        bundle = self._make_bundle_with_probes(["battery_capacity", "battery_health"])
        results = evaluate_all(bundle)
        manifest = build_manifest(bundle, results)
        self.assertTrue(manifest.manifest_hash)
        self.assertTrue(manifest.manifest_id)


class TestProfiles(unittest.TestCase):

    def test_draft_and_approve_profile(self):
        fields = [
            ProfileField(name="device", value="topaz",
                         provenance="observed", source="probe"),
        ]
        profile = draft_profile("topaz", "khaje", fields)
        self.assertTrue(profile.profile_hash)
        self.assertFalse(profile.approved)

        approved = approve_profile(profile, actor="tester",
                                   expected_hash=profile.profile_hash)
        self.assertTrue(approved.approved)
        self.assertEqual(approved.approved_by, "tester")

    def test_approve_rejects_hash_change(self):
        fields = [ProfileField(name="x", value="1",
                               provenance="observed", source="s")]
        profile = draft_profile("d", "t", fields)
        # Mutate the profile after review
        profile.fields.append(ProfileField(name="y", value="2",
                                           provenance="observed", source="s"))
        with self.assertRaises(ProfileHashChanged):
            approve_profile(profile, actor="tester",
                            expected_hash=profile.profile_hash)

    def test_match_topology_mismatch(self):
        profile = draft_profile("topaz", "khaje", [])
        with self.assertRaises(CapabilityMismatch):
            match_topology(profile, "fogo", "khaje")

    def test_profile_save_load_roundtrip(self):
        fields = [ProfileField(name="x", value="1",
                               provenance="observed", source="s")]
        profile = draft_profile("topaz", "khaje", fields)
        profile = approve_profile(profile, actor="tester")

        with tempfile.TemporaryDirectory() as d:
            path = save_profile(profile, Path(d))
            loaded = load_profile(path)
            self.assertEqual(loaded.profile_hash, profile.profile_hash)
            self.assertTrue(loaded.approved)


class TestCommands(unittest.TestCase):

    def test_classify_safe_command(self):
        self.assertEqual(classify_risk("getprop ro.product.device"), RiskLevel.SAFE)
        self.assertEqual(classify_risk("cat /proc/cpuinfo"), RiskLevel.SAFE)

    def test_classify_state_changing_command(self):
        self.assertEqual(classify_risk("setprop debug.sf.showupdates 1"),
                         RiskLevel.STATE_CHANGING)

    def test_classify_dangerous_command(self):
        self.assertEqual(classify_risk("rm -rf /data"), RiskLevel.DANGEROUS)

    def test_classify_unknown_command(self):
        self.assertEqual(classify_risk("some_unknown_binary --flag"),
                         RiskLevel.UNKNOWN)

    def test_requires_confirmation(self):
        self.assertFalse(requires_confirmation(RiskLevel.SAFE))
        self.assertTrue(requires_confirmation(RiskLevel.UNKNOWN))
        self.assertTrue(requires_confirmation(RiskLevel.STATE_CHANGING))
        self.assertTrue(requires_confirmation(RiskLevel.DANGEROUS))


class TestReport(unittest.TestCase):

    def test_generate_report_contains_key_info(self):
        bundle = EvidenceBundle(run_id="test-123", boot_id="boot-456",
                                 build_hash="build-789")
        bundle.add_part(EvidencePart(name="probe_test", source="probe",
                                     content=b'{"exit_code": 0}'))
        bundle.seal()

        report = generate_report(bundle)
        self.assertIn("test-123", report)
        self.assertIn("boot-456", report)
        self.assertIn("build-789", report)
        self.assertIn("SEALED", report)

    def test_generate_report_with_manifest(self):
        bundle = EvidenceBundle(run_id="test")
        bundle.add_part(EvidencePart(name="p", source="probe", content=b"x"))
        bundle.seal()

        manifest = TrustManifest(
            manifest_id="m-1", run_id="test",
            artifact_state="CERTIFIED",
            gates=[{"gate_name": "g", "state": "pass", "detail": "ok"}],
        )
        manifest.manifest_hash = manifest.compute_hash()

        report = generate_report(bundle, manifest=manifest)
        self.assertIn("CERTIFIED", report)
        self.assertIn("[PASS]", report)
        self.assertIn("g", report)


if __name__ == "__main__":
    unittest.main()
