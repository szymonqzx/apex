"""apex_cert.adb — Serial-pinned ADB executor with budgets.

Serializes all ADB/root commands per serial (one execution lock per device).
Parallelize only host-side transforms after raw parts are durable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .errors import (
    AdbNotFound, DeviceUnavailable, DeviceUnauthorized, AmbiguousDevice,
    CommandTimeout, CommandFailed, DeviceDisconnected, ResourceBudgetExceeded,
)


@dataclass
class CommandResult:
    """Result of a command execution."""
    command: str
    exit_code: int
    stdout: str = ""
    stderr: str = ""
    duration_ms: int = 0
    timed_out: bool = False
    truncated: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


class SerialLock:
    """Per-serial execution lock. Ensures only one command runs per device."""

    _locks: dict[str, threading.Lock] = {}
    _registry_lock = threading.Lock()

    @classmethod
    def get(cls, serial: str) -> threading.Lock:
        with cls._registry_lock:
            if serial not in cls._locks:
                cls._locks[serial] = threading.Lock()
            return cls._locks[serial]


class ADBExecutor:
    """Serial-pinned ADB executor with byte/time budgets."""

    def __init__(self, serial: str | None = None, *,
                 adb_path: str | None = None,
                 default_timeout: float = 30.0,
                 default_byte_budget: int = 10 * 1024 * 1024):
        self.serial = serial
        self.adb_path = adb_path or shutil.which("adb") or "adb"
        self.default_timeout = default_timeout
        self.default_byte_budget = default_byte_budget
        self._lock = SerialLock.get(serial or "default")

    def _build_adb_cmd(self, args: list[str]) -> list[str]:
        cmd = [self.adb_path]
        if self.serial:
            cmd += ["-s", self.serial]
        cmd += args
        return cmd

    def detect_devices(self) -> list[dict[str, str]]:
        """List connected devices. Returns list of {serial, state}."""
        if not shutil.which(self.adb_path):
            raise AdbNotFound(f"adb not found at {self.adb_path}")
        result = subprocess.run(
            [self.adb_path, "devices"],
            capture_output=True, text=True, timeout=10
        )
        devices = []
        for line in result.stdout.strip().splitlines()[1:]:  # skip header
            parts = line.split()
            if len(parts) >= 2:
                devices.append({"serial": parts[0], "state": parts[1]})
        return devices

    def resolve_serial(self) -> str:
        """Resolve exactly one authorized device, or raise."""
        devices = self.detect_devices()
        authorized = [d for d in devices if d["state"] == "device"]
        unauthorized = [d for d in devices if d["state"] == "unauthorized"]

        if not devices:
            raise DeviceUnavailable("No devices detected via adb")
        if unauthorized and not authorized:
            raise DeviceUnauthorized(
                f"Device {unauthorized[0]['serial']} is unauthorized"
            )
        if len(authorized) > 1:
            raise AmbiguousDevice(
                f"{len(authorized)} devices detected; specify --serial"
            )
        serial = authorized[0]["serial"]
        self.serial = serial
        self._lock = SerialLock.get(serial)
        return serial

    def run(self, args: list[str], *,
            timeout: float | None = None,
            byte_budget: int | None = None,
            stdin: str | None = None) -> CommandResult:
        """Execute an adb command with serial pinning and budgets."""
        timeout = timeout or self.default_timeout
        byte_budget = byte_budget or self.default_byte_budget

        with self._lock:
            cmd = self._build_adb_cmd(args)
            return self._execute(cmd, timeout, byte_budget, stdin)

    def shell(self, command: str, *,
              timeout: float | None = None,
              byte_budget: int | None = None,
              root: bool = False) -> CommandResult:
        """Execute a shell command on the device."""
        if root:
            args = ["shell", "su", "-c", command]
        else:
            args = ["shell", command]
        return self.run(args, timeout=timeout, byte_budget=byte_budget)

    def _execute(self, cmd: list[str], timeout: float,
                 byte_budget: int, stdin: str | None) -> CommandResult:
        """Execute a command with timeout and byte budget enforcement."""
        start = time.monotonic()
        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE if stdin else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except FileNotFoundError:
            raise AdbNotFound(f"adb not found: {cmd[0]}")

        try:
            stdout_bytes, stderr_bytes = proc.communicate(
                input=stdin.encode() if stdin else None,
                timeout=timeout
            )
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            elapsed = int((time.monotonic() - start) * 1000)
            raise CommandTimeout(
                f"Command timed out after {timeout}s: {' '.join(cmd)}",
            ) from None

        elapsed = int((time.monotonic() - start) * 1000)
        stdout = stdout_bytes.decode("utf-8", errors="replace")
        stderr = stderr_bytes.decode("utf-8", errors="replace")
        truncated = False

        if len(stdout) > byte_budget:
            stdout = stdout[:byte_budget]
            truncated = True
            # This is a budget-exceeded condition, not silent truncation
            # The caller sees truncated=True and can act on it

        result = CommandResult(
            command=" ".join(cmd),
            exit_code=proc.returncode,
            stdout=stdout,
            stderr=stderr,
            duration_ms=elapsed,
            truncated=truncated,
        )

        if proc.returncode != 0 and "device not found" in stderr.lower():
            raise DeviceDisconnected(f"Device disconnected: {stderr.strip()}")

        return result
