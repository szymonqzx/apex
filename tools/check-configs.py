#!/usr/bin/env python3
"""check-configs.py — verify that the apex defconfig fragments are consistent.

Checks:
  1. No conflicting CONFIG options (both =y and =n in different fragments)
  2. All dependencies are satisfied (e.g., CPU_FREQ_GOV_APEX depends on CPU_FREQ)
  3. No duplicate CONFIG options within the same fragment
  4. Required configs that must be =y (not =m or =n)
  5. Configs that must be =n (security risks)
  6. version.config presence
  7. Feature summary

Usage:
  python3 check-configs.py [--verbose]
"""

import re
import sys
import argparse
from pathlib import Path

APEX = Path(__file__).parent.parent
DEFCONFIG_DIR = APEX / "defconfig"

# Known dependency rules
DEPENDENCIES = {
    "CPU_FREQ_GOV_APEX": ["CPU_FREQ", "CPU_FREQ_GOV_COMMON"],
    "CPU_FREQ_GOV_SCHEDUTIL": ["CPU_FREQ"],
    "SCHED_WALT": ["SMP"],
    "SCHED_CASS": [],
    "APEX": [],
    "APEX_WATCHDOG": ["APEX"],
    "APEX_IMMORTAL": ["APEX"],
    "APEX_USB_AUTOLOAD": ["USB"],
    "APEX_KCAL": ["FB"],
    "APEX_SIMPLE_LMK": [],
    "APEX_MEMFREQ": ["DEVFREQ", "INTERCONNECT"],
    "ZRAM_WRITEBACK": ["ZRAM"],
    "KSM": ["MMU"],
    "CFI_CLANG": ["CC_IS_CLANG"],
    "LTO_CLANG_THIN": ["CC_IS_CLANG"],
    "WIREGUARD": [],
    "EXFAT_FS": [],
    "NTFS3_FS": [],
    "LRU_GEN": [],
    "WQ_POWER_EFFICIENT": [],
    "RCU_LAZY": [],
    "NET_SCH_FQ": [],
    "TCP_CONG_BBR": [],
    "TCP_CONG_WESTWOOD": [],
}

# Known conflicts (can't both be default governor)
CONFLICTS = [
    ("CPU_FREQ_DEFAULT_GOV_APEX", "CPU_FREQ_DEFAULT_GOV_SCHEDUTIL"),
    ("CPU_FREQ_DEFAULT_GOV_APEX", "CPU_FREQ_DEFAULT_GOV_PERFORMANCE"),
    ("CPU_FREQ_DEFAULT_GOV_SCHEDUTIL", "CPU_FREQ_DEFAULT_GOV_PERFORMANCE"),
    ("TRANSPARENT_HUGEPAGE_ALWAYS", "TRANSPARENT_HUGEPAGE_MADVISE"),
]

# Configs that must be =y (built-in, not module)
REQUIRED_Y = [
    "CONFIG_PREEMPT",
    "CONFIG_CPU_FREQ",
    "CONFIG_CPU_FREQ_GOV_COMMON",
]

# Configs that must be disabled (=n)
REQUIRED_N = [
    "CONFIG_USERFAULTFD",
    "CONFIG_DEBUG_KMEMLEAK",
]

# Feature groups for summary
FEATURE_GROUPS = {
    "governor": ["CONFIG_CPU_FREQ_GOV_APEX", "CONFIG_CPU_FREQ_DEFAULT_GOV_APEX"],
    "scheduler": ["CONFIG_SCHED_WALT", "CONFIG_SCHED_CASS", "CONFIG_PREEMPT",
                  "CONFIG_WQ_POWER_EFFICIENT", "CONFIG_RCU_LAZY"],
    "root": ["CONFIG_KSU", "CONFIG_KSU_SUSFS"],
    "hardening": ["CONFIG_CFI_CLANG", "CONFIG_RANDOMIZE_BASE",
                  "CONFIG_STACKPROTECTOR_STRONG", "CONFIG_FORTIFY_SOURCE"],
    "pentest": ["CONFIG_APEX_USB_AUTOLOAD", "CONFIG_WIREGUARD"],
    "zram": ["CONFIG_ZRAM", "CONFIG_ZRAM_DEF_COMP_ZSTD",
             "CONFIG_ZRAM_WRITEBACK", "CONFIG_LRU_GEN"],
    "networking": ["CONFIG_TCP_CONG_BBR", "CONFIG_TCP_CONG_WESTWOOD",
                   "CONFIG_NET_SCH_FQ"],
    "filesystems": ["CONFIG_EXFAT_FS", "CONFIG_NTFS3_FS"],
    "display": ["CONFIG_APEX_KCAL"],
    "toolchain": ["CONFIG_LTO_CLANG_THIN", "CONFIG_BPF_JIT_ALWAYS_ON"],
    "memory": ["CONFIG_APEX_SIMPLE_LMK", "CONFIG_APEX_MEMFREQ",
               "CONFIG_KSM", "CONFIG_MEMCG"],
}


def parse_config(path):
    """Parse a .config fragment file, return dict of CONFIG_X -> value."""
    configs = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                # Check for "# CONFIG_X is not set"
                m = re.match(r"#\s+(CONFIG_\w+)\s+is not set", line)
                if m:
                    configs[m.group(1)] = "n"
                continue
            m = re.match(r"(CONFIG_\w+)=(\w+)", line)
            if m:
                key = m.group(1)
                val = m.group(2)
                if key in configs:
                    print(
                        f"  WARN: {path.name}: duplicate {key}={configs[key]} -> {val}"
                    )
                configs[key] = val
    return configs


def main():
    parser = argparse.ArgumentParser(
        description="Verify apex defconfig fragment consistency")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show detailed output for each check")
    args = parser.parse_args()

    all_configs = {}
    errors = 0
    warnings = 0

    # Check for version.config presence
    version_config = DEFCONFIG_DIR / "version.config"
    if not version_config.exists():
        print("  ERROR: version.config not found in defconfig/")
        errors += 1
    else:
        if args.verbose:
            print("  [OK] version.config present")

    # Parse all fragments (exclude profile-*.config — they are mutually exclusive
# and only one is applied per build, so they intentionally conflict with each other)
    for frag in sorted(DEFCONFIG_DIR.glob("*.config")):
        if frag.name.startswith("profile-"):
            continue
        configs = parse_config(frag)
        all_configs[frag.name] = configs
        if args.verbose:
            print(f"  {frag.name}: {len(configs)} options")

    # Merge all configs
    merged = {}
    for frag_name, configs in all_configs.items():
        for key, val in configs.items():
            if key in merged and merged[key] != val:
                print(
                    f"  CONFLICT: {key}={merged[key]} (earlier) vs "
                    f"{key}={val} (in {frag_name})"
                )
                errors += 1
            merged[key] = val

    # Check dependencies
    for config, deps in DEPENDENCIES.items():
        if config in merged and merged[config] == "y":
            for dep in deps:
                if dep not in merged or merged[dep] not in ("y", "m"):
                    print(
                        f"  MISSING DEP: {config}=y requires {dep}, "
                        f"which is not enabled"
                    )
                    errors += 1

    # Check conflicts
    for a, b in CONFLICTS:
        if merged.get(a) == "y" and merged.get(b) == "y":
            print(f"  CONFLICT: {a}=y and {b}=y cannot both be set")
            errors += 1

    # Check required =y configs
    for config in REQUIRED_Y:
        val = merged.get(config)
        if val is None:
            print(f"  MISSING: {config} not set in any fragment (must be =y)")
            errors += 1
        elif val != "y":
            print(f"  ERROR: {config}={val} but must be =y")
            errors += 1
        elif args.verbose:
            print(f"  [OK] {config}=y")

    # Check required =n configs
    for config in REQUIRED_N:
        val = merged.get(config)
        if val == "y":
            print(f"  WARN: {config}=y should be disabled (=n)")
            warnings += 1
        elif val == "m":
            print(f"  WARN: {config}=m should be disabled (=n)")
            warnings += 1
        elif args.verbose and val == "n":
            print(f"  [OK] {config}=n (disabled)")

    # Check for USERFAULTFD (legacy check, also in REQUIRED_N)
    if merged.get("USERFAULTFD") == "y":
        warnings += 1  # Already counted above

    # Feature summary
    print("\n  --- Feature Summary ---")
    for feature, configs in FEATURE_GROUPS.items():
        enabled = []
        for config in configs:
            val = merged.get(config)
            if val == "y":
                enabled.append(config.replace("CONFIG_", ""))
            elif val == "m":
                enabled.append(config.replace("CONFIG_", "") + "(m)")
        status = ", ".join(enabled) if enabled else "disabled"
        print(f"  {feature:12s}: {status}")

    print(f"\n  Total: {errors} errors, {warnings} warnings")
    return 1 if errors > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
