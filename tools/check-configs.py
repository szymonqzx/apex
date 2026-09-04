#!/usr/bin/env python3
"""check-configs.py — verify the APEX kernel configuration (v0.2+).

The single source of truth is defconfig/apex_defconfig. Optional
profile overlays (defconfig/profile-*.config) are applied on top.

Checks:
  1. defconfig/apex_defconfig exists and has no duplicate CONFIG options
  2. Profile overlays have no internal duplicates and no key overlap with
     each other (they are mutually exclusive)
  3. Key dependencies are satisfied (e.g. CONFIG_SCHED_WALT needs CONFIG_SMP)
  4. Required configs are =y, forbidden configs are =n
  5. Feature summary for the merged configuration

Usage:
  python3 check-configs.py [--verbose]
"""

import re
import sys
import argparse
from pathlib import Path

APEX = Path(__file__).parent.parent
DEFCONFIG_DIR = APEX / "defconfig"
DEFCONFIG = DEFCONFIG_DIR / "apex_defconfig"

# Dependencies — key must be =y, deps must be =y or =m.
DEPENDENCIES = {
    "CONFIG_SCHED_WALT": ["CONFIG_SMP"],
    "CONFIG_APEX_SYSFS": ["CONFIG_SYSFS"],
    "CONFIG_APEX_CHARGE": ["CONFIG_APEX_SYSFS", "CONFIG_POWER_SUPPLY"],
    "CONFIG_ZRAM": ["CONFIG_ZSMALLOC", "CONFIG_SWAP"],
    "CONFIG_ZRAM_WRITEBACK": ["CONFIG_ZRAM"],
    "CONFIG_KSM": ["CONFIG_MMU"],
    "CONFIG_CFI_CLANG": ["CONFIG_CC_IS_CLANG"],
    "CONFIG_LTO_CLANG_THIN": ["CONFIG_CC_IS_CLANG"],
    "CONFIG_LRU_GEN": ["CONFIG_MMU"],
    "CONFIG_LRU_GEN_ENABLED": ["CONFIG_LRU_GEN"],
    "CONFIG_CPU_FREQ_GOV_SCHEDUTIL": ["CONFIG_CPU_FREQ"],
    "CONFIG_ARM_QCOM_CPUFREQ_HW": ["CONFIG_CPU_FREQ"],
    "CONFIG_UCLAMP_TASK": ["CONFIG_FAIR_GROUP_SCHED"],
    "CONFIG_BFQ_GROUP_IOSCHED": ["CONFIG_IOSCHED_BFQ", "CONFIG_BLK_CGROUP"],
    "CONFIG_SECURITY_LOCKDOWN_LSM": ["CONFIG_SECURITY"],
    "CONFIG_SHADOW_CALL_STACK": ["CONFIG_ARM64"],
    "CONFIG_SCHED_CONSERVATIVE_BOOST_LPM_BIAS": ["CONFIG_SCHED_WALT"],
    "CONFIG_BBG": ["CONFIG_SECURITY"],
    "CONFIG_KSU": ["CONFIG_KPROBES", "CONFIG_EXT4_FS"],
    "CONFIG_KSU_SUSFS": ["CONFIG_KSU"],
}

# Mutually exclusive pairs (only one may be =y)
CONFLICTS = [
    ("CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL", "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE"),
    ("CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL", "CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND"),
    ("CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS", "CONFIG_TRANSPARENT_HUGEPAGE_MADVISE"),
    ("CONFIG_PREEMPT", "CONFIG_PREEMPT_NONE"),
    ("CONFIG_PREEMPT", "CONFIG_PREEMPT_VOLUNTARY"),
]

# Must be built-in (=y)
REQUIRED_Y = [
    "CONFIG_CPU_FREQ",
    "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL",
    "CONFIG_CPU_FREQ_GOV_SCHEDUTIL",
    "CONFIG_SCHED_WALT",          # built-in for EAS from boot
    "CONFIG_ENERGY_MODEL",
    "CONFIG_APEX_SYSFS",
    "CONFIG_ZSMALLOC",            # built-in so ZRAM can be =y
    "CONFIG_ZRAM",                # built-in — essential at boot
    "CONFIG_CFI_CLANG",
    "CONFIG_SHADOW_CALL_STACK",
    "CONFIG_SECURITY_LOCKDOWN_LSM",
    "CONFIG_STACKPROTECTOR_STRONG",
    "CONFIG_SLAB_FREELIST_HARDENED",
    "CONFIG_BBG",
    "CONFIG_KSU",
    "CONFIG_KSU_SUSFS",
]

# Must be disabled (=n)
REQUIRED_N = [
    "CONFIG_USERFAULTFD",
    "CONFIG_HIBERNATION",
    "CONFIG_KEXEC",
    "CONFIG_KEXEC_FILE",
    "CONFIG_DEBUG_KMEMLEAK",
    "CONFIG_DEVMEM",
    "CONFIG_SECURITY_SELINUX_DEVELOP",
]

# Feature groups for the summary (checked against merged config)
FEATURE_GROUPS = {
    "scheduler": ["CONFIG_SCHED_WALT", "CONFIG_PREEMPT", "CONFIG_UCLAMP_TASK",
                  "CONFIG_SCHED_CONSERVATIVE_BOOST_LPM_BIAS"],
    "memory": ["CONFIG_LRU_GEN", "CONFIG_LRU_GEN_ENABLED", "CONFIG_KSM",
               "CONFIG_ZRAM", "CONFIG_ZRAM_DEF_COMP_ZSTD", "CONFIG_ZRAM_WRITEBACK"],
    "cpufreq": ["CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL", "CONFIG_ARM_QCOM_CPUFREQ_HW"],
    "io": ["CONFIG_IOSCHED_BFQ", "CONFIG_MQ_IOSCHED_DEADLINE", "CONFIG_BFQ_GROUP_IOSCHED"],
    "hardening": ["CONFIG_CFI_CLANG", "CONFIG_RANDOMIZE_BASE",
                  "CONFIG_STACKPROTECTOR_STRONG", "CONFIG_SHADOW_CALL_STACK",
                  "CONFIG_SECURITY_LOCKDOWN_LSM", "CONFIG_SLAB_FREELIST_HARDENED"],
    "networking": ["CONFIG_TCP_CONG_BBR", "CONFIG_WIREGUARD", "CONFIG_NET_SCH_FQ"],
    "power": ["CONFIG_CPU_IDLE_GOV_QCOM_LPM", "CONFIG_SUSPEND"],
    "thermal": ["CONFIG_THERMAL", "CONFIG_MI_THERMAL_INTERFACE",
                "CONFIG_SCHED_THERMAL_PRESSURE"],
    "apex": ["CONFIG_APEX_SYSFS", "CONFIG_APEX_CHARGE"],
    "baseband": ["CONFIG_BBG", "CONFIG_BBG_BLOCK_BOOT", "CONFIG_BBG_BLOCK_RECOVERY"],
    "root": ["CONFIG_KSU", "CONFIG_KSU_SUSFS", "CONFIG_KSU_SUSFS_SUS_PATH",
             "CONFIG_KSU_SUSFS_SUS_MOUNT", "CONFIG_KSU_SUSFS_SUS_KSTAT",
             "CONFIG_KSU_SUSFS_SUS_MAPS"],
    "device": ["CONFIG_INPUT_FINGERPRINT", "CONFIG_NOPMI_CHARGER",
               "CONFIG_ANT_CHECK", "CONFIG_BATT_VERIFY_BY_DS28E16"],
    "toolchain": ["CONFIG_LTO_CLANG_THIN", "CONFIG_BPF_JIT_ALWAYS_ON",
                  "CONFIG_DEBUG_INFO_DWARF5"],
}


def parse_config(path):
    """Parse a .config-style file; return {CONFIG_X: value}. Warn on dupes."""
    configs = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            m = re.match(r"#\s+(CONFIG_\w+)\s+is not set", line)
            if m:
                key = m.group(1)
                if key in configs:
                    print(f"  WARN: {path.name}: duplicate {key}")
                configs[key] = "n"
            continue
        m = re.match(r"(CONFIG_\w+)=(\w+)", line)
        if m:
            key, val = m.group(1), m.group(2)
            if key in configs:
                print(f"  WARN: {path.name}: duplicate {key}={configs[key]} -> {val}")
            configs[key] = val
    return configs


def main():
    parser = argparse.ArgumentParser(
        description="Verify APEX kernel configuration consistency")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    errors = 0
    warnings = 0

    # --- 1. Source of truth ------------------------------------------------
    if not DEFCONFIG.exists():
        print(f"  ERROR: {DEFCONFIG} not found — source of truth is untracked")
        return 1
    base = parse_config(DEFCONFIG)
    print(f"  [OK] defconfig/apex_defconfig: {len(base)} options")

    # --- 2. Profile overlays -----------------------------------------------
    # Compile-time profiles were removed in v0.2.1 — profile switching is
    # runtime-only via rom-overlays/init.d/apex_profiles.rc. Warn if stale
    # profile-*.config files reappear.
    profiles = {}
    for frag in sorted(DEFCONFIG_DIR.glob("profile-*.config")):
        profiles[frag.name] = parse_config(frag)
        print(f"  WARN: {frag.name} is a stale compile-time profile — removed in v0.2.1")
        warnings += 1

    # --- 3. Merge (base + any stale profiles) for dependency checks --------
    merged = dict(base)

    # --- 4. Dependencies ---------------------------------------------------
    for config, deps in DEPENDENCIES.items():
        if merged.get(config) == "y":
            for dep in deps:
                if merged.get(dep) not in ("y", "m"):
                    print(f"  MISSING DEP: {config}=y requires {dep}, not enabled")
                    errors += 1

    # --- 5. Conflicts ------------------------------------------------------
    for a, b in CONFLICTS:
        if merged.get(a) == "y" and merged.get(b) == "y":
            print(f"  CONFLICT: {a}=y and {b}=y cannot both be set")
            errors += 1

    # --- 6. Required =y ----------------------------------------------------
    for config in REQUIRED_Y:
        val = merged.get(config)
        if val is None:
            print(f"  MISSING: {config} not set (must be =y)")
            errors += 1
        elif val != "y":
            print(f"  ERROR: {config}={val} but must be =y")
            errors += 1
        elif args.verbose:
            print(f"  [OK] {config}=y")

    # --- 7. Required =n ----------------------------------------------------
    for config in REQUIRED_N:
        val = merged.get(config)
        if val in ("y", "m"):
            print(f"  WARN: {config}={val} should be disabled")
            warnings += 1
        elif args.verbose and val == "n":
            print(f"  [OK] {config}=n (disabled)")

    # BPF unprivileged must be OFF (this config is =y when default is off)
    if merged.get("CONFIG_BPF_UNPRIV_DEFAULT_OFF") != "y":
        print("  WARN: CONFIG_BPF_UNPRIV_DEFAULT_OFF != y (unprivileged BPF enabled)")
        warnings += 1

    # --- 8. Feature summary ------------------------------------------------
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
