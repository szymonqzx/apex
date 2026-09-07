#!/system/bin/sh
# apex_configure_hiding.sh — configures the hiding stack after module install.
#
# This script:
#   1. Generates the susfs4ksu-module config (configure_susfs.sh)
#   2. Enables the susfs4ksu + TrickyStore(OSS) modules
#   3. Configures HMA-OSS package hiding from denylist.conf
#   4. Verifies TrickyStore keybox presence
#   5. Checks lineage-hider (LSPosed module) is installed and scoped
#   6. Restarts KSU daemon
#
# Run manually after first boot, or from Apex Control "Configure Hiding" button.
#
# Shamiko is intentionally NOT part of this stack (Native Detector v7.7.0
# detects it). Kernel hiding is provided by susfs (manual-hook KSU + susfs4ksu).

set -eu

DENYLIST_CONF="/data/adb/apex/denylist.conf"
SUSFS_CONF="/data/adb/apex/configure_susfs.sh"
HMA_DIR="/data/adb/modules/hma_oss"
TRICKY_STORE_DIR=""
KEYBOX_PATH="/data/adb/tricky_store/keybox.xml"
SUSFS4KSU_DIR="/data/adb/modules/susfs4ksu"
KSU_BIN="/data/adb/ksu/bin/ksud"

log() {
    echo "apex_configure_hiding: $*" >&2
    command log -t apex_configure_hiding -p i "$*"
}

err() {
    echo "apex_configure_hiding ERROR: $*" >&2
    command log -t apex_configure_hiding -p e "$*"
}

# ── Step 1: Generate susfs4ksu-module config ────────────────────────────

if [ -d "$SUSFS4KSU_DIR" ]; then
    rm -f "$SUSFS4KSU_DIR/disable"
    if [ -x "$SUSFS_CONF" ]; then
        sh "$SUSFS_CONF"
        log "susfs4ksu config generated"
    else
        err "configure_susfs.sh not found at $SUSFS_CONF"
        exit 1
    fi
else
    err "susfs4ksu module not installed at $SUSFS4KSU_DIR"
    exit 1
fi

# ── Step 2: Enable TrickyStore(OSS) + verify keybox ─────────────────────

# Accept either the FOSS fork (tricky_store_oss) or the proprietary module.
for d in "/data/adb/modules/tricky_store_oss" "/data/adb/modules/tricky_store"; do
    if [ -d "$d" ]; then
        TRICKY_STORE_DIR="$d"
        break
    fi
done
if [ -n "$TRICKY_STORE_DIR" ]; then
    rm -f "$TRICKY_STORE_DIR/disable"
    if [ -f "$KEYBOX_PATH" ]; then
        log "TrickyStore enabled + keybox present"
    else
        err "TrickyStore enabled but NO KEYBOX at $KEYBOX_PATH"
        err "User must install keybox via Yurikey before STRONG tier passes"
    fi
else
    err "TrickyStore module not installed"
    exit 1
fi

# ── Step 3: Configure HMA-OSS ───────────────────────────────────────────

if [ -d "$HMA_DIR" ]; then
    rm -f "$HMA_DIR/disable"
    mkdir -p /data/adb/hma
    # HMA's hide list = the [hidden-apps] section of denylist.conf only
    # (tool apps to hide from the targets). The [denylist] section is the
    # KSU per-app "Umount modules" list, applied manually in the KSU manager.
    if [ -f "$DENYLIST_CONF" ]; then
        sed -n '/\[hidden-apps\]/,$p' "$DENYLIST_CONF" \
            | grep -v '^#' | grep -v '^$' > /data/adb/hma/hide.list
        log "HMA-OSS enabled; hide.list seeded from [hidden-apps] section"
    else
        err "denylist.conf not found at $DENYLIST_CONF"
        exit 1
    fi
    log "reminder: add HMA's own /data/app dir to sus_path.txt (raw /data/app scans)"
else
    err "HMA-OSS not installed — lineage package hiding unavailable"
    exit 1
fi

# ── Step 4: lineage-hider (LSPosed module) check ────────────────────────

LH_APK="/data/app/io.apex.lineagehider"
if pm path io.apex.lineagehider >/dev/null 2>&1 || [ -d "$LH_APK" ]; then
    log "lineage-hider installed — scope it to the target app(s) in LSPosed"
    log "  NEVER scope it to system framework or Google apps"
else
    err "lineage-hider not installed — adb install hiding/prebuilt/lineage_hider.apk"
fi

# ── Step 5: Restart KSU to apply module changes ─────────────────────────

if [ -x "$KSU_BIN" ]; then
    log "restarting KSU daemon to apply modules"
    "$KSU_BIN" restart 2>/dev/null || log "ksud restart failed (may need reboot)"
fi

log "hiding stack configured — reboot recommended for full effect"
log "after reboot: test with Native Detector (pin version) + Play Integrity checker"
exit 0
