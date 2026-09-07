package io.apex.lineagehider;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Central configuration for the LineageOS hiding module.
 *
 * Edit BOOT_HASH to match your device's real TEE boot hash (the value shown by
 * Native Detector / Key Attestation under "Boot hash"). It must be the REAL
 * hash so that the property and the TEE attestation stay consistent — never
 * invent one.
 *
 * PROP_SPOOFS maps a system property name to the value scoped apps should see
 * when they read it through android.os.SystemProperties (Java layer). Native
 * (libc __system_property_get) reads are covered by the susfs4ksu module's
 * service.sh resetprop block instead.
 */
public final class HiderConfig {

    private HiderConfig() {
    }

    /** Real boot hash from TEE attestation (Native Detector -> "Boot hash"). */
    public static final String BOOT_HASH =
            "102ae65d6eee19a6f5624ed88d9d87375391e763340d378b2c6f316d8ef11da5";

    /** Service names treated as LineageOS-internal and hidden from scoped apps. */
    public static final String[] LINEAGE_SERVICE_PREFIXES = {
            "lineage",
            "vendor.lineage.",
    };

    /**
     * Package/interface prefixes treated as LineageOS-internal and filtered
     * from PackageManager queries (getInstalledPackages / getInstalledApplications
     * / getPackageInfo / getDeclaredInstances) in scoped apps.
     * "org.lineageos." covers every LineageOS package from the ND report:
     * platform, jelly, etar, twelve, recorder, aperture, camelot, backgrounds,
     * glimse, lineageparts, updater, setupwizard, settingsconfig, profiles,
     * lineagesettings, settings.device, dspvolume.xiaomi, overlay.* and the
     * platform-res package itself (org.lineageos.platform).
     */
    public static final String[] LINEAGE_PACKAGE_PREFIXES = {
            "org.lineageos.",
    };

    /** Property spoof table (key -> value shown to scoped apps via SystemProperties). */
    public static final Map<String, String> PROP_SPOOFS = createPropSpoofs();

    private static Map<String, String> createPropSpoofs() {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("ro.boot.verifiedbootstate", "green");
        m.put("ro.boot.flash.locked", "1");
        m.put("ro.boot.vbmeta.device_state", "locked");
        m.put("ro.boot.warranty_bit", "0");
        m.put("ro.warranty_bit", "0");
        m.put("ro.boot.vbmeta.digest", BOOT_HASH);
        // Optional: populate the remaining vbmeta props the "Abnormal Boot
        // State" check reads. Leave empty ("") to not spoof them.
        m.put("ro.boot.vbmeta.hash_alg", "sha256");
        m.put("ro.boot.vbmeta.avb_version", "");
        m.put("ro.boot.vbmeta.size", "");
        // adb root service — the durable fix is disabling LineageOS root in
        // developer settings; this only covers Java readers.
        m.put("init.svc.adb_root", "");
        return Collections.unmodifiableMap(m);
    }
}
