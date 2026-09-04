"""apex_cert.errors — Named exception taxonomy.

Every error in the certification platform has a named class so callers
can catch specific failures rather than guessing from string messages.
The taxonomy mirrors the Error & Rescue Registry in the CEO plan.
"""

from __future__ import annotations


class ApexCertError(Exception):
    """Base class for all apex-cert errors."""

    def __init__(self, message: str, *, run_id: str | None = None,
                 step_id: str | None = None):
        super().__init__(message)
        self.run_id = run_id
        self.step_id = step_id


# ── Preflight & environment ──────────────────────────────────────────

class AdbNotFound(ApexCertError):
    """adb binary is not installed or not on PATH."""


class DeviceUnavailable(ApexCertError):
    """No device detected via adb."""


class DeviceUnauthorized(ApexCertError):
    """Device is present but unauthorized for ADB."""


class AmbiguousDevice(ApexCertError):
    """Multiple devices detected; serial pinning required."""


class RootUnavailable(ApexCertError):
    """su is denied or unavailable; privileged probes blocked."""


# ── Test spec & command ──────────────────────────────────────────────

class TestSpecInvalid(ApexCertError):
    """Test specification is nil, empty, or wrong schema."""

    def __init__(self, message: str, *, field: str | None = None, **kw):
        super().__init__(message, **kw)
        self.field = field


class CommandRiskUnknown(ApexCertError):
    """Command could not be classified; requires explicit confirmation."""

    def __init__(self, message: str, *, command: str = "", origin: str = "", **kw):
        super().__init__(message, **kw)
        self.command = command
        self.origin = origin


class CommandNotApproved(ApexCertError):
    """User declined the risk confirmation for a command."""


class CommandTimeout(ApexCertError):
    """Command exceeded its time budget."""


class CommandFailed(ApexCertError):
    """Command returned nonzero exit."""

    def __init__(self, message: str, *, exit_code: int = -1, **kw):
        super().__init__(message, **kw)
        self.exit_code = exit_code


class DeviceDisconnected(ApexCertError):
    """Device disconnected mid-probe."""


# ── Probe & parser ───────────────────────────────────────────────────

class ProbeOutputInvalid(ApexCertError):
    """Probe output is malformed."""

    def __init__(self, message: str, *, probe: str = "", **kw):
        super().__init__(message, **kw)
        self.probe = probe


class ProbeOutputEmpty(ApexCertError):
    """Probe produced no output."""

    def __init__(self, message: str, *, probe: str = "", **kw):
        super().__init__(message, **kw)
        self.probe = probe


# ── Bundle & persistence ─────────────────────────────────────────────

class BundleWriteFailed(ApexCertError):
    """Disk full, permission denied, or partial write during bundle assembly."""


class BundleIntegrityFailed(ApexCertError):
    """Hash mismatch or missing part after seal."""


# ── Schema & migration ───────────────────────────────────────────────

class SchemaVersionUnsupported(ApexCertError):
    """Artifact schema version is not supported by this tool version."""

    def __init__(self, message: str, *, version: str = "", **kw):
        super().__init__(message, **kw)
        self.version = version


class SchemaMigrationFailed(ApexCertError):
    """Migration transformation failed; original preserved."""


# ── Normalize & diff ─────────────────────────────────────────────────

class NormalizationFailed(ApexCertError):
    """Normalizer rule error or resource limit exceeded."""


class ResourceBudgetExceeded(ApexCertError):
    """Per-probe byte/time/sample budget exceeded."""

    def __init__(self, message: str, *, budget: int = 0, consumed: int = 0, **kw):
        super().__init__(message, **kw)
        self.budget = budget
        self.consumed = consumed


class BaselineMissing(ApexCertError):
    """No golden baseline available for comparison."""


class BaselineIncompatible(ApexCertError):
    """Golden baseline is from a different device/ROM/kernel/profile."""


class DiffInputInvalid(ApexCertError):
    """Diff engine received unexpected structure."""


# ── Profile ──────────────────────────────────────────────────────────

class ProfileEvidenceMissing(ApexCertError):
    """Profile field has no provenance evidence."""


class ProfileConflict(ApexCertError):
    """Conflicting provenance for a profile field."""


class ProfileHashChanged(ApexCertError):
    """Profile content changed after approval; approval invalidated."""


class CapabilityMismatch(ApexCertError):
    """Device topology does not match the profile."""

    def __init__(self, message: str, *, expected: str = "", actual: str = "", **kw):
        super().__init__(message, **kw)
        self.expected = expected
        self.actual = actual


# ── Gate & waiver ────────────────────────────────────────────────────

class GateEvidenceMissing(ApexCertError):
    """Required evidence for a gate is absent."""

    def __init__(self, message: str, *, gate: str = "", **kw):
        super().__init__(message, **kw)
        self.gate = gate


class GateFailed(ApexCertError):
    """Gate evaluation produced a fail result."""

    def __init__(self, message: str, *, gate: str = "", **kw):
        super().__init__(message, **kw)
        self.gate = gate


class WaiverInvalid(ApexCertError):
    """Waiver record is missing reason, actor, or scope."""

    def __init__(self, message: str, *, field: str = "", **kw):
        super().__init__(message, **kw)
        self.field = field


# ── Package & canary ─────────────────────────────────────────────────

class PackageIdentityMismatch(ApexCertError):
    """Artifact, profile, or build identity mismatch in package preflight."""


class BootControlUnsupported(ApexCertError):
    """Boot-control HAL does not support slot switching."""


class CanaryRehearsalRequired(ApexCertError):
    """Canary activation requires explicit destructive rehearsal."""


class CanaryHealthTimeout(ApexCertError):
    """Canary health checkpoint timed out; fallback should act."""


# ── Trust manifest ───────────────────────────────────────────────────

class TrustManifestInvalid(ApexCertError):
    """Trust manifest is missing, malformed, or hash-mismatched."""


class TrustManifestStale(ApexCertError):
    """Trust manifest is stale relative to current build identity."""


# ── Capability backend ───────────────────────────────────────────────

class CapabilityDenied(ApexCertError):
    """Capability write denied by backend preconditions."""


class ValueOutOfRange(ApexCertError):
    """Capability write value is outside the verified range."""

    def __init__(self, message: str, *, value: int = 0, lo: int = 0, hi: int = 0, **kw):
        super().__init__(message, **kw)
        self.value = value
        self.lo = lo
        self.hi = hi


class ReadbackMismatch(ApexCertError):
    """Capability write readback did not match the written value."""

    def __init__(self, message: str, *, written: int = 0, readback: int = 0, **kw):
        super().__init__(message, **kw)
        self.written = written
        self.readback = readback
