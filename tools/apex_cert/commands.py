"""apex_cert.commands — Arbitrary command origin/risk/approval/audit.

Arbitrary commands execute only through a distinct command path, never
profile parsing or ordinary probes.  Any run containing one becomes
TAINTED; its data may diagnose but cannot directly promote an untainted
artifact.
"""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any

from .errors import CommandRiskUnknown, CommandNotApproved
from .model import RunTaint


class RiskLevel(str, Enum):
    """Risk classification for arbitrary commands."""
    SAFE = "safe"          # read-only, no state change
    STATE_CHANGING = "state_changing"  # writes to device state
    UNKNOWN = "unknown"    # could not classify
    DANGEROUS = "dangerous"  # known hazardous pattern


# Patterns that are always safe (read-only)
SAFE_PATTERNS = [
    "getprop", "dumpsys", "cat /proc", "cat /sys", "ls ",
    "uname", "uptime", "df ", "free ", "ps ",
    "head ", "tail ", "grep ", "wc ", "stat ",
    "find ", "mount",  # mount without args is read-only
]

# Patterns that are state-changing
STATE_CHANGING_PATTERNS = [
    "echo ", "setprop", "settings ", "am ", "pm ",
    "reboot", "kill ", "stop ", "start ",
    "chmod", "chown", "rm ", "mv ", "cp ",
    "dd ", "flash", "write",
]

# Patterns that are always dangerous
DANGEROUS_PATTERNS = [
    "rm -rf", "mkfs", "flash_image", "dd if=",
    "format", "wipe", "fastboot",
]


@dataclass
class CommandRecord:
    """Audit record for an arbitrary command."""
    command: str
    origin: str  # "user", "test-spec", "probe-adapter"
    risk_level: str
    approved: bool = False
    timestamp: str = ""
    exit_code: int = -1
    output_hash: str = ""
    taint: str = RunTaint.CLEAN

    def to_dict(self) -> dict[str, Any]:
        return {
            "command": self.command,
            "origin": self.origin,
            "risk_level": self.risk_level,
            "approved": self.approved,
            "timestamp": self.timestamp,
            "exit_code": self.exit_code,
            "output_hash": self.output_hash,
            "taint": self.taint,
        }


def classify_risk(command: str) -> RiskLevel:
    """Classify a command's risk level based on pattern matching."""
    cmd_lower = command.lower().strip()

    for pat in DANGEROUS_PATTERNS:
        if pat in cmd_lower:
            return RiskLevel.DANGEROUS

    for pat in STATE_CHANGING_PATTERNS:
        if pat in cmd_lower:
            return RiskLevel.STATE_CHANGING

    for pat in SAFE_PATTERNS:
        if pat in cmd_lower:
            return RiskLevel.SAFE

    return RiskLevel.UNKNOWN


def requires_confirmation(risk: RiskLevel) -> bool:
    """Whether a command at this risk level requires explicit confirmation."""
    return risk in (RiskLevel.UNKNOWN, RiskLevel.STATE_CHANGING,
                    RiskLevel.DANGEROUS)


def confirm_command(command: str, origin: str, risk: RiskLevel,
                    *, auto_approve: bool = False,
                    prompt_fn=None) -> bool:
    """Present a command for user confirmation.

    Returns True if approved, False if declined.
    In non-interactive mode (auto_approve=False, no prompt_fn), raises
    CommandNotApproved.
    """
    if not requires_confirmation(risk):
        return True

    if auto_approve:
        return True

    if prompt_fn is None:
        raise CommandNotApproved(
            f"Command requires confirmation but no prompt function provided: {command}"
        )

    prompt = (
        f"RISK: {risk.value}\n"
        f"ORIGIN: {origin}\n"
        f"COMMAND: {command}\n"
        f"Approve? (yes/no): "
    )
    response = prompt_fn(prompt)
    return response.strip().lower() in ("yes", "y", "true", "1")


def execute_arbitrary(command: str, origin: str, *,
                      auto_approve: bool = False,
                      prompt_fn=None,
                      executor=None) -> CommandRecord:
    """Execute an arbitrary command with full risk classification and audit.

    The resulting run is marked TAINTED.
    """
    risk = classify_risk(command)
    approved = confirm_command(command, origin, risk,
                               auto_approve=auto_approve,
                               prompt_fn=prompt_fn)

    record = CommandRecord(
        command=command,
        origin=origin,
        risk_level=risk.value,
        approved=approved,
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        taint=RunTaint.TAINTED,
    )

    if not approved:
        raise CommandNotApproved(
            f"Command not approved: {command}",
        )

    if executor is not None:
        result = executor.shell(command)
        record.exit_code = result.exit_code
        record.output_hash = hashlib.sha256(
            result.stdout.encode()
        ).hexdigest()

    return record
