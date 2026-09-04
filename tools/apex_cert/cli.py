"""apex_cert.cli — Command-line interface for the certification platform.

Usage:
  python3 -m tools.apex_cert <command> [options]

Commands:
  inventory    — Run read-only probes and seal an evidence bundle
  diff         — Compare a candidate bundle against a golden baseline
  gates        — Evaluate certification gates against a bundle
  profile      — Generate or approve a capability profile
  package      — Slot-aware canary boot orchestration
  report       — Generate a human-readable certification report
  version      — Show version information
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__
from .model import (
    EvidenceBundle, EvidencePart, generate_run_id, SCHEMA_VERSION,
    ProfileField,
)
from .errors import ApexCertError
from .adb import ADBExecutor
from .probes import run_inventory, INVENTORY_PROBES
from .bundles import create_bundle, add_part, seal_bundle, save_bundle, load_bundle
from .normalize import normalize_bundle
from .diff import diff_bundles
from .gates import evaluate_all, build_manifest, CERTIFICATION_GATES, Waiver, validate_waiver
from .profiles import draft_profile, approve_profile, save_profile, load_profile
from .package import get_slot_info, activate_canary, verify_identity
from .report import generate_report, save_report


def cmd_inventory(args: argparse.Namespace) -> int:
    """Run read-only probes and seal an evidence bundle."""
    executor = ADBExecutor(serial=args.serial)
    if not args.serial:
        executor.resolve_serial()

    print(f"Running {len(INVENTORY_PROBES)} probes...")
    results = run_inventory(executor, include_root=not args.no_root)

    bundle = create_bundle(build_hash=args.build_hash or "",
                           profile_hash=args.profile_hash or "")
    for result in results:
        probe = next((p for p in INVENTORY_PROBES if p.name == result.probe_name), None)
        if probe:
            part = probe.to_part(result)
            add_part(bundle, part)

    seal_bundle(bundle)
    manifest_path = save_bundle(bundle, Path(args.output_dir))
    print(f"Bundle sealed: {manifest_path}")
    print(f"Run ID: {bundle.run_id}")
    print(f"Parts: {len(bundle.parts)}")
    print(f"Hash: {bundle.bundle_hash}")
    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    """Compare a candidate bundle against a golden baseline."""
    golden = load_bundle(Path(args.golden))
    candidate = load_bundle(Path(args.candidate))

    if args.normalize:
        golden = normalize_bundle(golden)
        candidate = normalize_bundle(candidate)

    report = diff_bundles(golden, candidate)
    print(json.dumps(report.to_dict(), indent=2))
    return 0 if report.compatible else 1


def cmd_gates(args: argparse.Namespace) -> int:
    """Evaluate certification gates against a bundle."""
    bundle = load_bundle(Path(args.bundle))

    waivers = []
    if args.waivers:
        waiver_data = json.loads(Path(args.waivers).read_text())
        for w in waiver_data:
            waiver = Waiver(
                gate_name=w["gate_name"],
                reason=w["reason"],
                actor=w["actor"],
                scope=w["scope"],
                timestamp=w.get("timestamp", ""),
            )
            validate_waiver(waiver)
            waivers.append(waiver)

    results = evaluate_all(bundle, waivers=waivers)
    manifest = build_manifest(bundle, results, waivers)

    print(json.dumps(json.loads(manifest.to_json()), indent=2))
    return 0 if "CERTIFIED" in manifest.artifact_state else 1


def cmd_profile(args: argparse.Namespace) -> int:
    """Generate or approve a capability profile."""
    if args.action == "draft":
        # Draft from a bundle
        bundle = load_bundle(Path(args.bundle))
        fields = []
        for part in bundle.parts:
            probe_name = part.metadata.get("probe", part.name)
            try:
                content = part.content.decode("utf-8", errors="replace").strip()
            except Exception:
                content = ""
            fields.append(ProfileField(
                name=probe_name,
                value=content,
                provenance="observed",
                source=f"bundle:{bundle.run_id}",
            ))
        profile = draft_profile(args.device, args.topology or "", fields)
        path = save_profile(profile, Path(args.output_dir))
        print(f"Profile drafted: {path}")
        print(f"Hash: {profile.profile_hash}")
        return 0

    elif args.action == "approve":
        profile = load_profile(Path(args.profile))
        profile = approve_profile(profile, actor=args.actor,
                                  expected_hash=args.expected_hash)
        path = save_profile(profile, Path(args.output_dir))
        print(f"Profile approved: {path}")
        return 0

    else:
        print(f"Unknown profile action: {args.action}")
        return 1


def cmd_package(args: argparse.Namespace) -> int:
    """Slot-aware canary boot orchestration."""
    executor = ADBExecutor(serial=args.serial)
    if not args.serial:
        executor.resolve_serial()

    if args.action == "slots":
        info = get_slot_info(executor)
        print(f"Active slot:   {info.active} ({info.suffix})")
        print(f"Inactive slot: {info.inactive}")
        return 0

    elif args.action == "canary":
        if not args.rehearsal:
            print("ERROR: Canary activation requires --rehearsal flag")
            return 1
        result = activate_canary(executor, rehearsal=True,
                                 health_timeout=args.health_timeout)
        print(json.dumps(result, indent=2))
        return 0 if result.get("healthy") else 1

    elif args.action == "verify":
        verify_identity(
            build_hash=args.build_hash,
            profile_hash=args.profile_hash,
            expected_build=args.expected_build,
            expected_profile=args.expected_profile,
        )
        print("Identity verified")
        return 0

    else:
        print(f"Unknown package action: {args.action}")
        return 1


def cmd_report(args: argparse.Namespace) -> int:
    """Generate a human-readable certification report."""
    bundle = load_bundle(Path(args.bundle))
    manifest = None
    profile = None
    diff = None

    if args.manifest:
        from .model import TrustManifest
        data = json.loads(Path(args.manifest).read_text())
        manifest = TrustManifest(
            manifest_id=data.get("manifest_id", ""),
            run_id=data.get("run_id", ""),
            build_hash=data.get("build_hash", ""),
            profile_hash=data.get("profile_hash", ""),
            artifact_state=data.get("artifact_state", ""),
            gates=data.get("gates", []),
            waivers=data.get("waivers", []),
            manifest_hash=data.get("manifest_hash", ""),
            timestamp=data.get("timestamp", ""),
        )

    if args.profile:
        profile = load_profile(Path(args.profile))

    if args.golden:
        golden = load_bundle(Path(args.golden))
        from .normalize import normalize_bundle
        from .diff import diff_bundles
        diff = diff_bundles(normalize_bundle(golden), normalize_bundle(bundle))

    report = generate_report(bundle, manifest, profile, diff)
    path = save_report(report, Path(args.output_dir), bundle.run_id)
    print(f"Report saved: {path}")
    print()
    print(report)
    return 0


def cmd_version(args: argparse.Namespace) -> int:
    """Show version information."""
    print(f"apex-cert version {__version__}")
    print(f"Schema version: {SCHEMA_VERSION}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser."""
    parser = argparse.ArgumentParser(
        prog="apex-cert",
        description="Apex Device Reliability Lab certification platform",
    )
    parser.add_argument("--serial", "-s", help="Device serial (for multi-device)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # inventory
    p_inv = subparsers.add_parser("inventory", help="Run probes and seal bundle")
    p_inv.add_argument("--output-dir", "-o", default="./evidence")
    p_inv.add_argument("--build-hash", help="Build identity hash")
    p_inv.add_argument("--profile-hash", help="Capability profile hash")
    p_inv.add_argument("--no-root", action="store_true", help="Skip root probes")
    p_inv.set_defaults(func=cmd_inventory)

    # diff
    p_diff = subparsers.add_parser("diff", help="Compare bundles")
    p_diff.add_argument("golden", help="Golden bundle directory")
    p_diff.add_argument("candidate", help="Candidate bundle directory")
    p_diff.add_argument("--normalize", action="store_true", help="Normalize before diff")
    p_diff.set_defaults(func=cmd_diff)

    # gates
    p_gates = subparsers.add_parser("gates", help="Evaluate gates")
    p_gates.add_argument("bundle", help="Bundle directory")
    p_gates.add_argument("--waivers", help="Waivers JSON file")
    p_gates.set_defaults(func=cmd_gates)

    # profile
    p_prof = subparsers.add_parser("profile", help="Manage capability profiles")
    p_prof.add_argument("action", choices=["draft", "approve"])
    p_prof.add_argument("--bundle", help="Bundle for drafting")
    p_prof.add_argument("--profile", help="Profile file for approval")
    p_prof.add_argument("--device", help="Device codename")
    p_prof.add_argument("--topology", help="Device topology")
    p_prof.add_argument("--actor", help="Approving actor")
    p_prof.add_argument("--expected-hash", help="Expected profile hash")
    p_prof.add_argument("--output-dir", "-o", default="./profiles")
    p_prof.set_defaults(func=cmd_profile)

    # package
    p_pkg = subparsers.add_parser("package", help="Canary boot orchestration")
    p_pkg.add_argument("action", choices=["slots", "canary", "verify"])
    p_pkg.add_argument("--rehearsal", action="store_true", help="Confirm destructive op")
    p_pkg.add_argument("--health-timeout", type=float, default=120.0)
    p_pkg.add_argument("--build-hash", help="Artifact build hash")
    p_pkg.add_argument("--profile-hash", help="Artifact profile hash")
    p_pkg.add_argument("--expected-build", help="Expected build hash")
    p_pkg.add_argument("--expected-profile", help="Expected profile hash")
    p_pkg.set_defaults(func=cmd_package)

    # report
    p_rep = subparsers.add_parser("report", help="Generate report")
    p_rep.add_argument("bundle", help="Bundle directory")
    p_rep.add_argument("--manifest", help="Trust manifest JSON")
    p_rep.add_argument("--profile", help="Capability profile JSON")
    p_rep.add_argument("--golden", help="Golden bundle for diff")
    p_rep.add_argument("--output-dir", "-o", default="./reports")
    p_rep.set_defaults(func=cmd_report)

    # version
    p_ver = subparsers.add_parser("version", help="Show version")
    p_ver.set_defaults(func=cmd_version)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Main CLI entry point."""
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except ApexCertError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nAborted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
