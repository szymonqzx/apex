#!/bin/bash
# patch-drivers.sh — Apply build-fix patches to out-of-tree drivers
#
# These patches fix common issues when building Realtek/MediaTek
# Wi-Fi drivers against a 5.15+ kernel with clang and CONFIG_EXPORT_NS.
#
# Usage: patch-drivers.sh <driver-src-dir> <driver-name>
#
# Environment:
#   KERNEL_SRC  kernel source tree (default: $PWD/../kernel)
#               — used to detect removed headers like net/ipx.h

set -euo pipefail

DRIVER_SRC="$1"
DRIVER_NAME="$2"
KERNEL_SRC="${KERNEL_SRC:-$(cd "$(dirname "$0")/.." && pwd)/kernel}"

case "$DRIVER_NAME" in
  rtl8812au|rtl8814au|rtl88x2bu|rtl8188eus)
    # Fix 1: Enable ARM64 platform. The switch name varies across Realtek
    # Makefiles: newer drops use CONFIG_PLATFORM_ANDROID_ARM64, the older
    # rtl8814au uses CONFIG_PLATFORM_ARM64. The ARM64 block also carries the
    # LITTLE_ENDIAN + CFG80211/RTW_USE_CFG80211_STA_EVENT flags, so enabling
    # the right one is load-bearing (not just cosmetic).
    if grep -q "CONFIG_PLATFORM_ANDROID_ARM64 = n" "$DRIVER_SRC/Makefile" 2>/dev/null; then
      sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$DRIVER_SRC/Makefile"
      sed -i 's/CONFIG_PLATFORM_ANDROID_ARM64 = n/CONFIG_PLATFORM_ANDROID_ARM64 = y/' "$DRIVER_SRC/Makefile"
    elif grep -q "CONFIG_PLATFORM_ARM64 = n" "$DRIVER_SRC/Makefile" 2>/dev/null; then
      sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$DRIVER_SRC/Makefile"
      sed -i 's/CONFIG_PLATFORM_ARM64 = n/CONFIG_PLATFORM_ARM64 = y/' "$DRIVER_SRC/Makefile"
    elif grep -q "CONFIG_PLATFORM_ARM64_RPI = n" "$DRIVER_SRC/Makefile" 2>/dev/null; then
      sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$DRIVER_SRC/Makefile"
      sed -i 's/CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' "$DRIVER_SRC/Makefile"
    elif grep -q "CONFIG_PLATFORM_I386_PC = y" "$DRIVER_SRC/Makefile" 2>/dev/null; then
      sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$DRIVER_SRC/Makefile"
    fi

    # Fix 1b: rtw_android.c pulls <linux/wlan_plat.h> when
    # RTW_ENABLE_WIFI_CONTROL_FUNC is set. That header is not in 5.15 and the
    # wifi-control platform interface is pointless for a USB adapter, so
    # undefine it in the driver Makefile (must be EXTRA_CFLAGS: it is
    # appended AFTER KCFLAGS in kbuild, so -U wins over the driver's -D).
    if grep -q "RTW_ENABLE_WIFI_CONTROL_FUNC" "$DRIVER_SRC/Makefile" 2>/dev/null; then
      if ! grep -q "EXTRA_CFLAGS += -URTW_ENABLE_WIFI_CONTROL_FUNC" "$DRIVER_SRC/Makefile" 2>/dev/null; then
        echo 'EXTRA_CFLAGS += -URTW_ENABLE_WIFI_CONTROL_FUNC' >> "$DRIVER_SRC/Makefile"
        echo "  [wlan_plat] disabled RTW_ENABLE_WIFI_CONTROL_FUNC (no wlan_plat.h in 5.15)"
      fi
    fi

    # Fix 2: Add MODULE_IMPORT_NS for VFS namespace (kernel 5.10+)
    VFS_NS="VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver"
    for cfile in "$DRIVER_SRC"/os_dep/linux/os_intfs.c "$DRIVER_SRC"/core/rtw_mem.c; do
      [ -f "$cfile" ] || continue
      if ! grep -q "MODULE_IMPORT_NS" "$cfile" 2>/dev/null; then
        sed -i "/MODULE_AUTHOR/a MODULE_IMPORT_NS($VFS_NS);" "$cfile" 2>/dev/null || true
      fi
    done

    # Fix 3: Replace <net/ipx.h> (removed upstream) with a local stub in the
    # NAT25 bridge code. The driver's rtw_br_ext.c casts raw frames onto
    # structs that used to live in net/ipx.h (IPX/AARP/DDP header layouts).
    fix_ipx_br_ext() {
      local br_ext="$DRIVER_SRC/core/rtw_br_ext.c"
      [ -f "$br_ext" ] || return 0
      grep -q "#include <net/ipx.h>" "$br_ext" || return 0
      # Kernel still ships the header? Nothing to do.
      [ -f "$KERNEL_SRC/include/net/ipx.h" ] && return 0
      # Idempotency: already patched?
      grep -q "APEX IPX compat stub" "$br_ext" && return 0

      python3 - "$br_ext" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# <net/ipx.h> was removed upstream; the only structs the driver needs from
# it that aren't already provided by <linux/atalk.h> are ipx_addr/ipxhdr.
# (atalk.h still defines elapaarp/ddpehdr/AARP_PA_ALEN with the exact field
# types this driver's NAT25 code accesses.)
stub = """\
\t/* APEX IPX compat stub — <net/ipx.h> was removed from the Linux kernel;
\t * only the IPX packet-header layout is needed here (elapaarp/ddpehdr
\t * come from <linux/atalk.h>). */
\tstruct ipx_addr {
\t\tunsigned int net;
\t\tunsigned char node[6];
\t\tunsigned short sock;
\t};
\tstruct ipxhdr {
\t\tunsigned short ipx_checksum;
\t\tunsigned short ipx_pktsize;
\t\tunsigned char ipx_tctrl;
\t\tunsigned char ipx_type;
\t\tstruct ipx_addr ipx_dest;
\t\tstruct ipx_addr ipx_source;
\t};
"""

old = "\t#include <net/ipx.h>\n"
if old not in src:
    sys.exit("net/ipx.h include not found with expected indentation")
src = src.replace(old, stub, 1)
with open(path, "w") as f:
    f.write(src)
PYEOF
      echo "  [ipx] replaced <net/ipx.h> with compat stub in rtw_br_ext.c"
    }
    fix_ipx_br_ext

    # Fix 4b: Realtek headers declare MAC helpers as `extern __inline`. With
    # clang those can be emitted as external references with no out-of-line
    # definition -> "undefined!" at modpost. Make them static inline (the
    # driver's own definitions, so no API change).
    fix_extern_inline() {
      local hdr="$DRIVER_SRC/include/ieee80211.h"
      [ -f "$hdr" ] || return 0
      grep -q "extern __inline" "$hdr" 2>/dev/null || return 0
      sed -i 's/extern __inline /static inline /g' "$hdr"
      echo "  [inline] converted extern __inline -> static inline in ieee80211.h"
    }
    fix_extern_inline

    # Fix 4: Port cfg80211 glue to the 5.15 API. The older Realtek code
    # drops (rtl8814au) call APIs removed/reshaped upstream; apply the
    # minimal mechanical migration. Each edit is applied only when the
    # old API text is present, so this is idempotent and a no-op for
    # drivers that already build against 5.15 (e.g. rtl8812au).
    port_cfg80211_515() {
      local f="$DRIVER_SRC/os_dep/linux/ioctl_cfg80211.c"
      local h="$DRIVER_SRC/os_dep/linux/ioctl_cfg80211.h"
      [ -f "$f" ] || return 0

      python3 - "$f" "$h" <<'PYEOF'
import re
import sys

c_path, h_path = sys.argv[1], sys.argv[2]
with open(c_path) as fh:
    c = fh.read()

applied = 0

# Style detection (decide on ORIGINAL content, stable across re-runs):
#   "aircrack" — rtl8812au v5.6.4.2: guards against RHEL_RELEASE_CODE, keeps
#                its < 6.0.0 roam_info guard (do NOT lower 6,0,0/5,19,0).
#   "newer"    — rtl88x2bu / rtl8188eus: 6.x guards with RHEL88/bare versions.
#   "legacy"   — rtl8814au: unguarded old API calls.
if "RHEL_RELEASE_CODE" in c:
    style = "aircrack"
elif "KERNEL_VERSION(6," in c:
    style = "newer"
else:
    style = "legacy"

# --- Universal: lower 6.x API guards to 5.15 (the link_id/punct reshapes are
# 5.15 in this CAF tree). Idempotent: no matching guards remain after.
lowers = {
    "aircrack": ["6, 1, 0", "6, 3, 0", "5, 19, 2"],
    "newer": ["6, 1, 0", "6, 0, 0", "6, 3, 0", "5, 19, 2", "5, 19, 0"],
}.get(style, [])
for v6 in lowers:
    c, n = re.subn(
        r"KERNEL_VERSION\(" + re.escape(v6) + r"\)",
        "KERNEL_VERSION(5, 15, 0)",
        c,
    )
    applied += n

# Universal: wdev->current_bss (both 5.19+ and legacy spellings) -> connected
c, n = re.subn(
    r"\tif \(wdev->(?:links\[0\]\.client\.)?current_bss\) \{",
    "\tif (wdev->connected) {",
    c,
)
applied += n

# Universal: del_key carries link_id in BOTH the 6.1 guard and the 2.6.37
# branch — after lowering the guard they collide. Drop the 2.6.37 duplicate.
c, n = re.subn(
    r"\t\t\t\tint link_id, u8 key_index, bool pairwise, const u8 \*mac_addr\)",
    "\t\t\t\tu8 key_index, bool pairwise, const u8 *mac_addr)",
    c,
)
applied += n

if style == "aircrack":
    # rtl8812au: roam_info top-level channel/bssid -> links[0] (5.15 moved
    # them into the MLO links array; its < 6.0.0 guard keeps this block
    # active for 5.15, so rewrite the fields in place).
    c, n = re.subn(
        r"\t\troam_info\.channel = notify_channel;\n"
        r"\t\troam_info\.bssid = cur_network->network\.MacAddress;",
        "\t\troam_info.links[0].channel = notify_channel;\n"
        "\t\troam_info.links[0].bssid = cur_network->network.MacAddress;",
        c,
    )
    applied += n
    c, n = re.subn(
        r"\t\troam_info\.bssid = cur_network->network\.MacAddress;",
        "\t\troam_info.links[0].bssid = cur_network->network.MacAddress;",
        c,
    )
    applied += n

if style == "legacy":
    # --- Older-style codebase (rtl8814au): unguarded old API calls.
    edits = [
        # cfg80211_ch_switch_started_notify gained count + punct_bitmap
        (
            "\t\tcfg80211_ch_switch_started_notify(adapter->pnetdev, &chdef, 0, false);",
            "\t\tcfg80211_ch_switch_started_notify(adapter->pnetdev, &chdef, 0, 0, false, 0);",
        ),
        # cfg80211_ch_switch_notify gained link_id + punct_bitmap
        (
            "\t\tcfg80211_ch_switch_notify(adapter->pnetdev, &chdef);",
            "\t\tcfg80211_ch_switch_notify(adapter->pnetdev, &chdef, 0, 0);",
        ),
        # cfg80211_roam_info.bssid moved to links[0].bssid (+ channel)
        (
            "\t\troam_info.bssid = cur_network->network.MacAddress;",
            "\t\troam_info.links[0].bssid = cur_network->network.MacAddress;\n"
            "\t\troam_info.links[0].channel = notify_channel;",
        ),
        # cfg80211_send_disassoc() removed in 5.15
        (
            "\tcfg80211_send_disassoc(padapter->pnetdev, mgmt_buf, frame_len);",
            "\t/* cfg80211_send_disassoc() removed upstream; cfg80211 handles this */\n"
            "\t(void)mgmt_buf;\n"
            "\t(void)frame_len;",
        ),
        # key ops gained an int link_id parameter in 5.15 (MLO)
        (
            "static int cfg80211_rtw_add_key(struct wiphy *wiphy, struct net_device *ndev\n\t, u8 key_index",
            "static int cfg80211_rtw_add_key(struct wiphy *wiphy, struct net_device *ndev\n\t, int link_id, u8 key_index",
        ),
        (
            "static int cfg80211_rtw_get_key(struct wiphy *wiphy, struct net_device *ndev\n\t, u8 keyid",
            "static int cfg80211_rtw_get_key(struct wiphy *wiphy, struct net_device *ndev\n\t, int link_id, u8 keyid",
        ),
        (
            "\t\t\t\tu8 key_index, bool pairwise, const u8 *mac_addr)",
            "\t\t\t\tint link_id, u8 key_index, bool pairwise, const u8 *mac_addr)",
        ),
        (
            "static int cfg80211_rtw_set_default_key(struct wiphy *wiphy,\n\tstruct net_device *ndev, u8 key_index",
            "static int cfg80211_rtw_set_default_key(struct wiphy *wiphy,\n\tstruct net_device *ndev, int link_id, u8 key_index",
        ),
        (
            "int cfg80211_rtw_set_default_mgmt_key(struct wiphy *wiphy,\n\tstruct net_device *ndev, u8 key_index)",
            "int cfg80211_rtw_set_default_mgmt_key(struct wiphy *wiphy,\n\tstruct net_device *ndev, int link_id, u8 key_index)",
        ),
        # stop_ap gained unsigned int link_id in 5.15
        (
            "static int cfg80211_rtw_stop_ap(struct wiphy *wiphy, struct net_device *ndev)",
            "static int cfg80211_rtw_stop_ap(struct wiphy *wiphy, struct net_device *ndev,\n\tunsigned int link_id)",
        ),
        # wdev->current_bss removed; wdev->connected is the public state
        (
            "\tif (wdev->current_bss) {",
            "\tif (wdev->connected) {",
        ),
    ]
    for old, new in edits:
        if old in c:
            c = c.replace(old, new, 1)
            applied += 1

with open(c_path, "w") as fh:
    fh.write(c)

# Header: cfg80211_send_rx_assoc() -> cfg80211_rx_assoc_resp() macro
with open(h_path) as fh:
    h = fh.read()
old_macro = (
    "#if (LINUX_VERSION_CODE < KERNEL_VERSION(3, 4, 0))  && !defined(COMPAT_KERNEL_RELEASE)\n"
    "#define rtw_cfg80211_send_rx_assoc(adapter, bss, buf, len) cfg80211_send_rx_assoc((adapter)->pnetdev, buf, len)\n"
    "#else\n"
    "#define rtw_cfg80211_send_rx_assoc(adapter, bss, buf, len) cfg80211_send_rx_assoc((adapter)->pnetdev, bss, buf, len)\n"
    "#endif"
)
new_macro = (
    "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0))\n"
    "/* cfg80211_send_rx_assoc() was removed; use cfg80211_rx_assoc_resp(). */\n"
    "#define rtw_cfg80211_send_rx_assoc(adapter, bss, buf_, len_) \\\n"
    "\t({ \\\n"
    "\t\tstruct cfg80211_rx_assoc_resp __resp = { \\\n"
    "\t\t\t.buf = (buf_), \\\n"
    "\t\t\t.len = (len_), \\\n"
    "\t\t}; \\\n"
    "\t\t__resp.links[0].bss = (bss); \\\n"
    "\t\tcfg80211_rx_assoc_resp((adapter)->pnetdev, &__resp); \\\n"
    "\t})\n"
    "#elif (LINUX_VERSION_CODE < KERNEL_VERSION(3, 4, 0))  && !defined(COMPAT_KERNEL_RELEASE)\n"
    "#define rtw_cfg80211_send_rx_assoc(adapter, bss, buf, len) cfg80211_send_rx_assoc((adapter)->pnetdev, buf, len)\n"
    "#else\n"
    "#define rtw_cfg80211_send_rx_assoc(adapter, bss, buf, len) cfg80211_send_rx_assoc((adapter)->pnetdev, bss, buf, len)\n"
    "#endif"
)
if old_macro in h:
    h = h.replace(old_macro, new_macro, 1)
    applied += 1
with open(h_path, "w") as fh:
    fh.write(h)

print(f"  [cfg80211] {applied} 5.15 API edits applied")
PYEOF
    }
    port_cfg80211_515
    ;;
esac

echo "  patched $DRIVER_NAME"
