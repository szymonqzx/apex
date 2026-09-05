# rom-overlays/device/apex_lineage_topaz.mk
#
# This file is sourced by device/xiaomi/topaz/lineage_topaz.mk.
# It pulls in all APEX ROM overlays, agent packages, and configuration.
#
# Include this at the END of lineage_topaz.mk so APEX properties
# override any conflicting LineageOS defaults.

# ── APEX ROM core ─────────────────────────────────────────────────
$(call inherit-product, vendor/apex/rom-overlays/device/apex_device.mk)

# ── APEX WM framework overlay (freeform window support) ───────────
# Enables config_freeformWindowManagement in the framework.
PRODUCT_COPY_FILES += \
    vendor/apex/wm/overlay/ApexWmOverlay.apk:$(TARGET_COPY_OUT_PRODUCT)/overlay/ApexWmOverlay.apk

# ── APEX Desktop Mode (scrcpy server) ─────────────────────────────
PRODUCT_COPY_FILES += \
    vendor/apex/desktop/scrcpy-server.jar:$(TARGET_COPY_OUT_SYSTEM)/bin/scrcpy-server.jar

# ── Remote model proxy (separate SELinux domain for network) ──────
PRODUCT_PACKAGES += \
    apex-remote-proxy

PRODUCT_COPY_FILES += \
    vendor/apex/agent/sepolicy/apex_remote_proxy.te:$(TARGET_COPY_OUT_SYSTEM)/etc/selinux/apex_remote_proxy.te \
    vendor/apex/rom-overlays/init.d/apex_remote_proxy.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/apex_remote_proxy.rc

# ── Lindroid container manager (P4, optional) ─────────────────────
# Uncomment when Lindroid is enabled:
# PRODUCT_PACKAGES += apex-lindroid
# PRODUCT_COPY_FILES += \
#     vendor/apex/lindroid/sepolicy/apex_lindroid.te:$(TARGET_COPY_OUT_SYSTEM)/etc/selinux/apex_lindroid.te \
#     vendor/apex/rom-overlays/init.d/apex_lindroid.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/apex_lindroid.rc

# ── Hiding stack (KSU modules, installed post-boot) ───────────────
# These are NOT installed via PRODUCT_PACKAGES — they are KSU modules
# that get installed to /data/adb/modules/ on first boot via a
# one-time init script.
PRODUCT_COPY_FILES += \
    vendor/apex/hiding/zygisk_next.zip:$(TARGET_COPY_OUT_SYSTEM)/apex/modules/zygisk_next.zip \
    vendor/apex/hiding/shamiko.zip:$(TARGET_COPY_OUT_SYSTEM)/apex/modules/shamiko.zip \
    vendor/apex/hiding/hma_oss.zip:$(TARGET_COPY_OUT_SYSTEM)/apex/modules/hma_oss.zip \
    vendor/apex/hiding/tricky_store.zip:$(TARGET_COPY_OUT_SYSTEM)/apex/modules/tricky_store.zip

# One-time module installer: extracts KSU modules on first boot
PRODUCT_COPY_FILES += \
    vendor/apex/hiding/install_modules.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/apex_install_modules.sh

# ── APEX ROM feature flags ────────────────────────────────────────
PRODUCT_SYSTEM_PROPERTIES += \
    ro.apex.wm_enabled=true \
    ro.apex.desktop_enabled=true \
    ro.apex.remote_model_enabled=false \
    ro.apex.lindroid_enabled=false

# ── Disable LineageOS features that conflict with APEX ────────────
# APEX handles its own power profiles, tuning, and charging.
# Don't let LineageOS duplicate these.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.lineage.power_profile=0 \
    ro.lineage.charging.enabled=0
