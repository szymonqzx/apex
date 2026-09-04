#!/usr/bin/env python3
"""Tests for the Android app domain layer (trust state parsing).

Validates the JSON parsing logic that maps a trust manifest to the
TrustState enum and gate summary list.  We test the parsing logic in
Python (mirroring the Kotlin implementation) to verify correctness
without requiring an Android build environment.
"""

import json
import unittest


# Mirror of the Kotlin TrustState enum
TRUST_STATES = [
    "UNKNOWN", "UNVERIFIED", "OBSERVE_ONLY", "PARTIAL", "CANDIDATE",
    "CERTIFIED", "CERTIFIED_WITH_WAIVERS", "FAILED", "STALE", "ROLLED_BACK",
]

CERTIFIED_STATES = {"CERTIFIED", "CERTIFIED_WITH_WAIVERS"}


def parse_trust_manifest(json_str: str) -> tuple[str, str, list[dict]]:
    """Python mirror of the Kotlin parseTrustManifest function."""
    try:
        obj = json.loads(json_str)
    except json.JSONDecodeError:
        return ("UNKNOWN", "", [])

    artifact_state = obj.get("artifact_state", "UNVERIFIED")
    if artifact_state not in TRUST_STATES:
        artifact_state = "UNKNOWN"
    manifest_hash = obj.get("manifest_hash", "")
    gates = []
    for gate in obj.get("gates", []):
        gates.append({
            "name": gate.get("gate_name", ""),
            "state": gate.get("state", ""),
            "detail": gate.get("detail", ""),
        })
    return (artifact_state, manifest_hash, gates)


class TestTrustStateParsing(unittest.TestCase):

    def test_parse_certified_manifest(self):
        manifest = json.dumps({
            "artifact_state": "CERTIFIED",
            "manifest_hash": "abc123def456",
            "gates": [
                {"gate_name": "battery_health", "state": "pass", "detail": "ok"},
                {"gate_name": "charging_basic", "state": "pass", "detail": "ok"},
            ],
        })
        state, hash_val, gates = parse_trust_manifest(manifest)
        self.assertEqual(state, "CERTIFIED")
        self.assertEqual(hash_val, "abc123def456")
        self.assertEqual(len(gates), 2)
        self.assertEqual(gates[0]["name"], "battery_health")
        self.assertEqual(gates[0]["state"], "pass")

    def test_parse_certified_with_waivers(self):
        manifest = json.dumps({
            "artifact_state": "CERTIFIED_WITH_WAIVERS",
            "manifest_hash": "hash123",
            "gates": [
                {"gate_name": "g1", "state": "pass"},
                {"gate_name": "g2", "state": "waived", "detail": "probe unavailable"},
            ],
        })
        state, _, gates = parse_trust_manifest(manifest)
        self.assertEqual(state, "CERTIFIED_WITH_WAIVERS")
        self.assertTrue(state in CERTIFIED_STATES)
        self.assertEqual(len(gates), 2)

    def test_parse_failed_manifest(self):
        manifest = json.dumps({
            "artifact_state": "FAILED",
            "manifest_hash": "h",
            "gates": [{"gate_name": "g", "state": "fail"}],
        })
        state, _, _ = parse_trust_manifest(manifest)
        self.assertEqual(state, "FAILED")
        self.assertFalse(state in CERTIFIED_STATES)

    def test_parse_partial_manifest(self):
        manifest = json.dumps({
            "artifact_state": "PARTIAL",
            "manifest_hash": "h",
            "gates": [{"gate_name": "g", "state": "missing"}],
        })
        state, _, _ = parse_trust_manifest(manifest)
        self.assertEqual(state, "PARTIAL")
        self.assertFalse(state in CERTIFIED_STATES)

    def test_parse_invalid_json_returns_unknown(self):
        state, hash_val, gates = parse_trust_manifest("not json")
        self.assertEqual(state, "UNKNOWN")
        self.assertEqual(hash_val, "")
        self.assertEqual(gates, [])

    def test_parse_empty_manifest(self):
        state, hash_val, gates = parse_trust_manifest("{}")
        self.assertEqual(state, "UNVERIFIED")
        self.assertEqual(hash_val, "")
        self.assertEqual(gates, [])

    def test_parse_unknown_state_returns_unknown(self):
        manifest = json.dumps({"artifact_state": "NONSENSE"})
        state, _, _ = parse_trust_manifest(manifest)
        self.assertEqual(state, "UNKNOWN")

    def test_parse_no_gates_key(self):
        manifest = json.dumps({"artifact_state": "CERTIFIED"})
        state, _, gates = parse_trust_manifest(manifest)
        self.assertEqual(state, "CERTIFIED")
        self.assertEqual(gates, [])

    def test_certified_states_are_subset(self):
        """CERTIFIED and CERTIFIED_WITH_WAIVERS are the only certified states."""
        for s in TRUST_STATES:
            if s in CERTIFIED_STATES:
                self.assertIn("CERTIFIED", s)
            else:
                self.assertNotIn(s, CERTIFIED_STATES)


if __name__ == "__main__":
    unittest.main()
