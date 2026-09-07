#!/usr/bin/env bash
# apply.sh — redirect mi_thermald's low-battery hotplug targets to P-cores
#
# Ported from ChicKernel commit 3e85c4293b4d
# ("drivers: base: cpu: redirect mi_thermald to disable 2 P-cores",
# chickendrop89/device_xiaomi_gemstones-kernel, 2026-08).
#
# On this device mi_thermald is misconfigured: below ~5% battery it hotplugs
# cpu2+cpu3 (efficient cores) offline via the CPU online sysfs, making the
# phone nearly unusable. When the writer is mi_thermald, redirect the target
# to cpu4/cpu5 (the P-cores) so the power-hungry cores go offline instead.
# All other writers and all other CPUs behave exactly as before.
#
# Upstream reference: patches/apex-new/apex-thermald-cores/src/3e85c42.diff
#
# Idempotent: skips when the "mi_thermald" marker is already present.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"
CORE="$KERNEL/drivers/base/core.c"

[ -f "$CORE" ] || {
  echo "ERROR: $CORE not found" >&2
  exit 1
}

if grep -q "mi_thermald" "$CORE"; then
  echo "  [skip] apex-thermald-cores: already applied"
  exit 0
fi

python3 - "$CORE" <<'PYEOF'
import sys

p = sys.argv[1]
s = open(p).read()

OLD = """static ssize_t online_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	bool val;
	int ret;

	ret = strtobool(buf, &val);
	if (ret < 0)
		return ret;

	ret = lock_device_hotplug_sysfs();
	if (ret)
		return ret;

	ret = val ? device_online(dev) : device_offline(dev);
	unlock_device_hotplug();
	return ret < 0 ? ret : count;
}
static DEVICE_ATTR_RW(online);"""

NEW = """static ssize_t online_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	bool val;
	int ret;
	struct device *target_dev = dev;
	int requested_cpuid = dev->id;
	int target_cpuid = requested_cpuid;

	ret = strtobool(buf, &val);
	if (ret < 0)
		return ret;

	/*
	 * mi_thermald is misconfigured: below ~5% battery it disables the
	 * efficient cores (cpu2/cpu3) via hotplug sysfs, making the phone
	 * nearly unusable. Redirect it to the P-cores (cpu4/cpu5) instead.
	 * All other writers and all other CPUs behave exactly as before.
	 */
	if (!strcmp(current->comm, "mi_thermald")) {
		if (requested_cpuid == 2)
			target_cpuid = 4;
		else if (requested_cpuid == 3)
			target_cpuid = 5;
	}

	if (requested_cpuid != target_cpuid) {
		target_dev = get_cpu_device(target_cpuid);
		if (!target_dev)
			return -ENODEV;
	}

	ret = lock_device_hotplug_sysfs();
	if (ret)
		return ret;

	ret = val ? device_online(target_dev) : device_offline(target_dev);
	unlock_device_hotplug();
	return ret < 0 ? ret : count;
}
static DEVICE_ATTR_RW(online);"""

if OLD not in s:
    print(f"ERROR: online_store pattern not found in {p} (tree drift?)", file=sys.stderr)
    sys.exit(1)

open(p, "w").write(s.replace(OLD, NEW, 1))
print("  [ok] apex-thermald-cores: online_store redirects mi_thermald to P-cores")
PYEOF
