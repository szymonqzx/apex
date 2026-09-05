# rom-overlays/device/apex_device.mk
#
# APEX ROM device configuration for topaz/tapas (Redmi Note 12 4G).
# This file is included by the topaz device makefile to add APEX-specific
# configuration: Virtual A/B updates, APEX kernel requirement, agent service.
#
# Brick-safety: no partition table modifications, no bootloader changes.

# ── APEX ROM identity ─────────────────────────────────────────────

PRODUCT_NAME := apex_$(TARGET_DEVICE)
PRODUCT_BRAND := Xiaomi
PRODUCT_DEVICE := $(TARGET_DEVICE)
PRODUCT_MANUFACTURER := Xiaomi
PRODUCT_MODEL := Redmi Note 12 4G

# APEX version properties
PRODUCT_SYSTEM_PROPERTIES += \
    ro.apex.version=1.0.0 \
    ro.apex.rom_base=lineage-23.2 \
    ro.apex.kernel_required=true \
    ro.apex.device=$(TARGET_DEVICE)

# ── Virtual A/B update configuration ──────────────────────────────
# topaz supports Virtual A/B (snapshot updates). Enable it explicitly.

# Virtual A/B metadata
PRODUCT_VIRTUAL_AB_OTA := true
PRODUCT_VIRTUAL_AB_OTA_RETROFIT := false

# Update engine configuration
PRODUCT_PACKAGES += \
    update_engine \
    update_verifier \
    update_engine_client

# A/B slot configuration
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS := \
    boot \
    system \
    vendor \
    product

# Boot control HAL
PRODUCT_PACKAGES += \
    android.hardware.boot@1.2-service \
    android.hardware.boot@1.2-impl

# OTA package configuration
TARGET_OTA_ASSERT_DEVICE := topaz,tapas

# ── A/B post-install scripts ──────────────────────────────────────

AB_OTA_POSTINSTALL_CONFIG += \
    postinstall:system/bin/apex_ab_verify.sh

# ── APEX kernel prebuilt ──────────────────────────────────────────
# The APEX kernel is pre-built and installed as the boot image kernel.

LOCAL_KERNEL := device/xiaomi/topaz/prebuilt/kernel
TARGET_PREBUILT_KERNEL := $(LOCAL_KERNEL)

# Kernel modules
PRODUCT_COPY_FILES += \
    $(foreach f,$(wildcard device/xiaomi/topaz/prebuilt/modules/*.ko),\
    $(f):$(TARGET_COPY_OUT_VENDOR)/lib/modules/$(notdir $(f)))

# ── APEX agent service ────────────────────────────────────────────

# Agent AIDL + Java sources
PRODUCT_PACKAGES += \
    apex-agent \
    apexagentd

# Agent JNI libraries (pre-built or built via external makefiles)
PRODUCT_PACKAGES += \
    libllm_jni \
    libwhisper_jni

# Agent init scripts
PRODUCT_COPY_FILES += \
    vendor/apex/rom-overlays/init.d/apex_agent.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/apex_agent.rc \
    vendor/apex/rom-overlays/update/apex_update_engine.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/apex_update_engine.rc

# A/B verification scripts
PRODUCT_COPY_FILES += \
    vendor/apex/rom-overlays/update/apex_ab_verify.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/apex_ab_verify.sh \
    vendor/apex/rom-overlays/update/apex_ota_fallback.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/apex_ota_fallback.sh

# ── SELinux policy for agent ──────────────────────────────────────

PRODUCT_SEPOLICY += \
    vendor/apex/agent/sepolicy/apex_agent.te

# ── Apex Control app ──────────────────────────────────────────────

PRODUCT_PACKAGES += \
    ApexControl

# ── Kernel detection overlay ──────────────────────────────────────

PRODUCT_COPY_FILES += \
    vendor/apex/rom-overlays/init.d/apex_kernel_detect.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/apex_kernel_detect.rc \
    vendor/apex/rom-overlays/init.d/apex_kernel_detect.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/apex_kernel_detect.sh

# ── Brick-safety: explicitly NOT included ─────────────────────────
# The following are NEVER touched by APEX ROM:
# - bootloader (aboot)
# - partition tables (GPT)
# - modem/radio partition
# - tz/hyp/sbl
# Only boot, system, vendor, product partitions are updated.
