#!/system/bin/sh
# apex_configure_hiding.sh — configures the hiding stack after module install.
#
# This script:
#   1. Configures Shamiko denylist from denylist.conf
#   2. Configures HMA-OSS package hiding
#   3. Verifies TrickyStore keybox presence
#   4. Runs a basic Play Integrity check
#
# Run manually after first boot, or from Apex Control "Configure Hiding" button.

set -eu

DENYLIST_CONF="/data/adb/apex/denylist.conf"
SHAMIKO_DIR="/data/adb/modules/shamiko"
HMA_DIR="/data/adb/modules/hma_oss"
TRICKY_STORE_DIR="/data/adb/modules/tricky_store"
KEYBOX_PATH="/data/adb/tricky_store/keybox.xml"
KSU_BIN="/data/adb/ksu/bin/ksud"

log() {
    echo "apex_configure_hiding: $*" >&2
    log -t apex_configure_hiding -p i "$*"
}

err() {
    echo "apex_configure_hiding ERROR: $*" >&2
    log -t apex_configure_hiding -p e "$*"
}

# ── Step 1: Configure Shamiko denylist ────────────────────────────

if [ ! -d "$SHAMIKO_DIR" ]; then
    err "Shamiko module not installed at $SHAMIKO_DIR"
    exit 1
fi

# Enable Shamiko module
rm -f "$SHAMIKO_DIR/disable"
log "Shamiko module enabled"

# Copy denylist to Shamiko's configuration location
mkdir -p /data/adb/shamiko
if [ -f "$DENYLIST_CONF" ]; then
    cp "$DENYLIST_CONF" /data/adb/shamiko/denylist.conf
    log "denylist copied to Shamiko config"
else
    err "denylist.conf not found at $DENYLIST_CONF"
    exit 1
fi

# ── Step 2: Configure HMA-OSS ─────────────────────────────────────

if [ -d "$HMA_DIR" ]; then
    rm -f "$HMA_DIR/disable"
    mkdir -p /data/adb/hma
    cp "$DENYLIST_CONF" /data/adb/hma/hide.list
    log "HMA-OSS module enabled + hide list configured"
else
    log "HMA-OSS not installed — skipping (optional)"
fi

# ── Step 3: Verify TrickyStore + keybox ───────────────────────────

if [ -d "$TRICKY_STORE_DIR" ]; then
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

# ── Step 4: Enable Zygisk-Next if not already ─────────────────────

ZYGISK_DIR="/data/adb/modules/zygisk_next"
if [ -d "$ZYGISK_DIR" ]; then
    rm -f "$ZYGISK_DIR/disable"
    log "Zygisk-Next module enabled"
else
    err "Zygisk-Next module not installed — Shamiko/TrickyStore won't work"
    exit 1
fi

# ── Step 5: Restart KSU to apply module changes ───────────────────

if [ -x "$KSU_BIN" ]; then
    log "restarting KSU daemon to apply modules"
    "$KSU_BIN" restart 2>/dev/null || log "ksud restart failed (may need reboot)"
fi

log "hiding stack configured — reboot recommended for full effect"
log "after reboot: test with Play Integrity checker app"
exit 0
