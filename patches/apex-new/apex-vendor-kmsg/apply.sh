#!/usr/bin/env bash
# apply.sh — suppress vendor module debug spam in printk
#
# Ported from ChicKernel commit 06af5ac88a95
# ("kernel: printk: add a way of suppressing GKI module debugging",
# chickendrop89/device_xiaomi_gemstones-kernel, 2026-08).
#
# Some vendor modules for this device are built with debugging compiled in
# ([bq2589x], [sm5602], nopmi_chg, [sc8551], st21nfc, Awinic). They spam the
# console and cover up important logs — the exact situation when diagnosing a
# boot hang. Adds CONFIG_SUPPRESS_VENDOR_MODULE_DEBUGGING (default n) plus a
# printk filter that drops matching messages when enabled.
#
# Upstream reference: patches/apex-new/apex-vendor-kmsg/src/06af5ac8.diff
#
# Idempotent: skips when the "SUPPRESS_VENDOR_MODULE_DEBUGGING" marker is
# already present in both files.
set -euo pipefail
KERNEL="${1:?usage: apply.sh <kernel-dir>}"
KCONFIG="$KERNEL/init/Kconfig"
PRINTK="$KERNEL/kernel/printk/printk.c"

[ -f "$KCONFIG" ] || {
  echo "ERROR: $KCONFIG not found" >&2
  exit 1
}
[ -f "$PRINTK" ] || {
  echo "ERROR: $PRINTK not found" >&2
  exit 1
}

if grep -q "SUPPRESS_VENDOR_MODULE_DEBUGGING" "$KCONFIG" &&
  grep -q "SUPPRESS_VENDOR_MODULE_DEBUGGING" "$PRINTK"; then
  echo "  [skip] apex-vendor-kmsg: already applied"
  exit 0
fi

# --- 1. init/Kconfig: new config before "endif # MODULES" ---
python3 - "$KCONFIG" <<'PYEOF'
import sys

p = sys.argv[1]
s = open(p).read()

BLOCK = """
config SUPPRESS_VENDOR_MODULE_DEBUGGING
	bool "Suppress vendor module debugging"
	help
	  Some vendor GKI modules were built with debugging compiled in; this
	  spams the console with info we don't need and covers up important
	  logs.

	  This hack is specific to xiaomi devices. The modules affected can
	  be found in the filtered_modules[] array in kernel/printk/printk.c

	  Do not select this if you are debugging, or planning to build the
	  modules into the kernel image.

	  If unsure, say N.
"""

ANCHOR = "\nendif # MODULES\n"
if "SUPPRESS_VENDOR_MODULE_DEBUGGING" in s:
    print("  [skip] Kconfig: already present")
elif ANCHOR not in s:
    print("ERROR: 'endif # MODULES' anchor not found in init/Kconfig", file=sys.stderr)
    sys.exit(1)
else:
    s = s.replace(ANCHOR, BLOCK + ANCHOR, 1)
    open(p, "w").write(s)
    print("  [ok] Kconfig: SUPPRESS_VENDOR_MODULE_DEBUGGING added")
PYEOF

# --- 2. kernel/printk/printk.c: filter helper + call in vprintk_store ---
python3 - "$PRINTK" <<'PYEOF'
import sys

p = sys.argv[1]
s = open(p).read()

if "should_filter_vendor_message" in s:
    print("  [skip] printk.c: already present")
    sys.exit(0)

HELPER = """
__maybe_unused static bool should_filter_vendor_message(const char *text)
{
	const char *const *module;

	/*
	 * The fmt string in question needs to be truncated to 5 characters
	 * due to the prefix_buf buffer being 8 bytes.
	 */
	static const char *const filtered_modules[] = {
#if !IS_ENABLED(CONFIG_POWER_SUPPLY_DEBUG)
		"[bq25", /* [bq2589x] */
		"[sm56", /* [sm5602]  */
		"nopmi", /* nopmi_chg */
		"[sc85", /* [sc8551-STANDALONE] */
#endif
		"st21n", /* st21nfc  */
		"[Awin", /* [Awinic] */
		NULL
	};

	for (module = filtered_modules; likely(*module); module++) {
		/*
		 * The PSU logs are the largest and most repeated portion of
		 * what is printed to the console most of the time; adjust
		 * branch prediction accordingly.
		 */
#if !IS_ENABLED(CONFIG_POWER_SUPPLY_DEBUG)
		if (likely(strstr(text, *module)))
			return true;
#else
		if (unlikely(strstr(text, *module)))
			return true;
#endif
	}

	return false;
}
"""

# 2a. helper after printk_sprint()'s closing brace, before vprintk_store()
VPRINTK_ANCHOR = "__printf(4, 0)\nint vprintk_store(int facility, int level,"
if VPRINTK_ANCHOR not in s:
    print("ERROR: vprintk_store anchor not found in printk.c", file=sys.stderr)
    sys.exit(1)
s = s.replace(VPRINTK_ANCHOR, HELPER + "\n" + VPRINTK_ANCHOR, 1)

# 2b. filter call after the prefix_buf vsnprintf in vprintk_store()
VSNPRINTF_ANCHOR = "reserve_size = vsnprintf(&prefix_buf[0], sizeof(prefix_buf), fmt, args2) + 1;\n\tva_end(args2);"
FILTER_CALL = """
#if IS_ENABLED(CONFIG_SUPPRESS_VENDOR_MODULE_DEBUGGING)
	if (should_filter_vendor_message(prefix_buf)) {
		ret = 0;
		goto out;
	}
#endif
"""
if VSNPRINTF_ANCHOR not in s:
    print("ERROR: prefix_buf vsnprintf anchor not found in printk.c", file=sys.stderr)
    sys.exit(1)
s = s.replace(VSNPRINTF_ANCHOR, VSNPRINTF_ANCHOR + FILTER_CALL, 1)

open(p, "w").write(s)
print("  [ok] printk.c: should_filter_vendor_message + vprintk_store hook added")
PYEOF
