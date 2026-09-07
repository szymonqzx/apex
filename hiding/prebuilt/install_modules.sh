#!/system/bin/sh
# apex_install_modules.sh — one-time KSU module installer for APEX ROM.
#
# Runs on first boot (triggered by apex_modules.rc) and installs the
# hiding stack KSU modules from /system/apex/modules/*.zip into
# /data/adb/modules/. Only runs once — creates a sentinel file.
#
# Modules installed:
#   1. zygisk_next  — Zygisk runtime for KSU-Next
#   2. shamiko      — denylist-based root hiding
#   3. hma_oss      — HMA package/path hiding
#   4. tricky_store — hardware-backed KeyStore keybox injection
#   5. yurikey      — keybox manager (one-time setup)
#
# After installation, the user must:
#   - Configure denylist via Apex Control or hidden_packages.list
#   - Install their keybox via Yurikey (separate, one-time)
#
# Brick-safety: this script only writes to /data/adb/modules/ (KSU
# module directory). It does NOT touch system partitions, bootloader,
# or any persistent state outside /data.

set -eu

MODULE_SRC_DIR="/system/apex/modules"
MODULE_DST_DIR="/data/adb/modules"
SENTINEL="/data/adb/apex_modules_installed"
KSU_BIN="/data/adb/ksu/bin/ksud"

log() {
    echo "apex_install_modules: $*" >&2
    log -t apex_install_modules -p i "$*"
}

# Already installed?
if [ -f "$SENTINEL" ]; then
    log "modules already installed (sentinel exists), skipping"
    exit 0
fi

# Wait for KSU to be ready
if [ ! -d "$MODULE_DST_DIR" ]; then
    log "KSU module directory not found — KSU not installed?"
    # Create it if KSU is compiled into kernel
    mkdir -p "$MODULE_DST_DIR" 2>/dev/null || {
        log "cannot create module directory — aborting"
        exit 1
    }
fi

# Install each module zip
for zip in "$MODULE_SRC_DIR"/*.zip; do
    [ -f "$zip" ] || continue
    modname=$(basename "$zip" .zip)
    log "installing module: $modname"

    # Try ksud module install first (proper KSU API)
    if [ -x "$KSU_BIN" ]; then
        if "$KSU_BIN" module install "$zip" >/dev/null 2>&1; then
            log "  installed via ksud: $modname"
            continue
        fi
        log "  ksud install failed, trying manual extraction"
    fi

    # Manual extraction fallback: unzip to module directory
    moddir="$MODULE_DST_DIR/$modname"
    mkdir -p "$moddir"
    cd "$moddir"
    if command -v unzip >/dev/null 2>&1; then
        unzip -o "$zip" -d "$moddir" >/dev/null 2>&1
    else
        # Android doesn't always have unzip — use toybox
        toybox unzip -o "$zip" -d "$moddir" >/dev/null 2>&1
    fi

    # Verify module.prop exists (valid KSU module)
    if [ -f "$moddir/module.prop" ]; then
        log "  installed via extraction: $modname"
        # Disable by default — user enables via Apex Control
        touch "$moddir/disable"
    else
        log "  ERROR: $modname missing module.prop — extraction failed"
        rm -rf "$moddir"
    fi
done

# Create sentinel
touch "$SENTINEL"
log "all modules installed — user must configure denylist + keybox"
log "sentinel created at $SENTINEL"

exit 0
