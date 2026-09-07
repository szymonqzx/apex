package io.apex.lineagehider;

import io.github.libxposed.api.XposedModule;
import io.github.libxposed.api.XposedModuleInterface;

import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

/**
 * APEX Lineage Hider — hides LineageOS artifacts from scoped apps.
 *
 * What it does (all hooks are installed in the scoped app's process only):
 *  1. ServiceManager.listServices()/getService()/checkService() — filters the
 *     LineageOS binder services (lineageglobalactions, lineagehardware,
 *     lineagehealth, lineagelivedisplay, lineagetrust, vendor.lineage.* HALs).
 *  2. AssetManager.LINEAGE_APK_PATH — wipes the static field's String contents
 *     in place (the field is a compile-time constant on LineageOS, so the
 *     backing char[] is patched, which Field.get() observes afterwards).
 *  3. SystemProperties.get() — returns spoofed values for ro.boot.* props
 *     (Java-layer reads; native reads are handled by susfs4ksu resetprop).
 *
 * Scope this module ONLY to the app(s) that must not see LineageOS. Never
 * scope it to the system framework or Google apps (Play Integrity will fail).
 */
public final class LineageHider extends XposedModule {

    private static final String TAG = "LineageHider";

    @Override
    public void onModuleLoaded(XposedModuleInterface.ModuleLoadedParam param) {
        // The system server is out of scope by design: hooking it would
        // ripple into Play Integrity and every other app on the device.
        if (param.isSystemServer()) {
            return;
        }
        log("loaded in process: " + param.getProcessName());
        hookServiceManager();
        hookPackageManager();
        hookAssetManagerPath();
        hookSystemProperties();
    }

    // ── 1b. PackageManager hiding (supplements HMA in-process) ───────────

    private void hookPackageManager() {
        try {
            Class<?> apm = Class.forName("android.app.ApplicationPackageManager");

            // getInstalledPackages(int) -> List<PackageInfo>
            hook(apm.getDeclaredMethod("getInstalledPackages", int.class)).intercept(chain -> {
                Object result = chain.proceed();
                return filterPackageInfoList(result);
            });

            // getInstalledApplications(int) -> List<ApplicationInfo>
            hook(apm.getDeclaredMethod("getInstalledApplications", int.class)).intercept(chain -> {
                Object result = chain.proceed();
                return filterPackageInfoList(result);
            });

            // getPackageInfo(String, int) -> PackageInfo (null for lineage)
            hook(apm.getDeclaredMethod("getPackageInfo", String.class, int.class)).intercept(chain -> {
                if (chain.getArg(0) instanceof String && isLineagePackage((String) chain.getArg(0))) {
                    return null;
                }
                return chain.proceed();
            });

            log("PackageManager hooks installed");
        } catch (Throwable t) {
            log("PackageManager hook failed: " + t);
        }
    }

    /** Removes LineageOS entries from a List<PackageInfo> or List<ApplicationInfo>. */
    private static Object filterPackageInfoList(Object result) {
        if (!(result instanceof List)) {
            return result;
        }
        List<?> list = (List<?>) result;
        Iterator<?> it = list.iterator();
        boolean changed = false;
        while (it.hasNext()) {
            Object item = it.next();
            String pkg = packageNameOf(item);
            if (pkg != null && isLineagePackage(pkg)) {
                it.remove();
                changed = true;
            }
        }
        return changed ? list : result;
    }

    private static String packageNameOf(Object item) {
        if (item == null) {
            return null;
        }
        try {
            Field f = item.getClass().getDeclaredField("packageName");
            f.setAccessible(true);
            Object v = f.get(item);
            return v instanceof String ? (String) v : null;
        } catch (Throwable t) {
            return null;
        }
    }

    private static boolean isLineagePackage(String name) {
        if (name == null) {
            return false;
        }
        for (String prefix : HiderConfig.LINEAGE_PACKAGE_PREFIXES) {
            if (name.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    // ── 1. Binder service hiding ─────────────────────────────────────────

    private void hookServiceManager() {
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");

            // listServices() -> String[] (deprecated, but what detectors use)
            Method listServices = sm.getDeclaredMethod("listServices");
            hook(listServices).intercept(chain -> {
                Object result = chain.proceed();
                if (!(result instanceof String[])) {
                    return result;
                }
                String[] all = (String[]) result;
                List<String> kept = new ArrayList<>(all.length);
                for (String name : all) {
                    if (!isLineageService(name)) {
                        kept.add(name);
                    }
                }
                return kept.toArray(new String[0]);
            });

            // getService(String) / checkService(String) / waitForService(String)
            // -> null for lineage
            Method getService = sm.getDeclaredMethod("getService", String.class);
            Method checkService = sm.getDeclaredMethod("checkService", String.class);
            Method waitForService = sm.getDeclaredMethod("waitForService", String.class);
            for (Method m : new Method[]{getService, checkService, waitForService}) {
                hook(m).intercept(chain -> {
                    if (chain.getArg(0) instanceof String && isLineageService((String) chain.getArg(0))) {
                        return null;
                    }
                    return chain.proceed();
                });
            }

            // getDeclaredInstances(String iface) -> List<String> (A11+)
            try {
                Method declaredInstances = sm.getDeclaredMethod("getDeclaredInstances", String.class);
                hook(declaredInstances).intercept(chain -> {
                    Object result = chain.proceed();
                    if (!(result instanceof List)) {
                        return result;
                    }
                    List<?> list = (List<?>) result;
                    Iterator<?> it = list.iterator();
                    while (it.hasNext()) {
                        Object name = it.next();
                        if (name instanceof String && isLineageService((String) name)) {
                            it.remove();
                        }
                    }
                    return list;
                });
            } catch (NoSuchMethodException ignored) {
                // pre-A11 — getDeclaredInstances does not exist
            }

            log("ServiceManager hooks installed");
        } catch (Throwable t) {
            log("ServiceManager hook failed: " + t);
        }
    }

    private static boolean isLineageService(String name) {
        if (name == null) {
            return false;
        }
        for (String prefix : HiderConfig.LINEAGE_SERVICE_PREFIXES) {
            if (name.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    // ── 2. AssetManager.LINEAGE_APK_PATH ─────────────────────────────────

    private void hookAssetManagerPath() {
        try {
            Class<?> am = Class.forName("android.content.res.AssetManager");
            Field field;
            try {
                field = am.getDeclaredField("LINEAGE_APK_PATH");
            } catch (NoSuchFieldException e) {
                log("AssetManager.LINEAGE_APK_PATH not present (already de-lineaged?)");
                return;
            }
            field.setAccessible(true);
            Object value = field.get(null);
            if (!(value instanceof String)) {
                log("AssetManager.LINEAGE_APK_PATH is not a String; skipping");
                return;
            }
            wipeString((String) value);
            log("AssetManager.LINEAGE_APK_PATH wiped");
        } catch (Throwable t) {
            log("AssetManager path wipe failed: " + t);
        }
    }

    /**
     * Wipes a String's backing storage in place. The field is a compile-time
     * constant on LineageOS, so Field.set() would be a no-op (the constant is
     * folded); patching the char[]/byte[] the String object points at makes
     * every later read — including Field.get() — observe the new contents.
     */
    private static void wipeString(String s) {
        try {
            Field valueField = String.class.getDeclaredField("value");
            valueField.setAccessible(true);
            Object backing = valueField.get(s);
            if (backing instanceof char[]) {
                char[] chars = (char[]) backing;
                for (int i = 0; i < chars.length; i++) {
                    Array.setChar(chars, i, '\0');
                }
            } else if (backing instanceof byte[]) {
                byte[] bytes = (byte[]) backing;
                for (int i = 0; i < bytes.length; i++) {
                    Array.setByte(bytes, i, (byte) 0);
                }
            }
        } catch (Throwable t) {
            // Fallback for non-folded builds (e.g. de-constantized ROMs):
            // swap the backing array outright.
            try {
                Field valueField = String.class.getDeclaredField("value");
                valueField.setAccessible(true);
                valueField.set(s, new char[0]);
            } catch (Throwable ignored) {
            }
        }
    }

    // ── 3. Boot property spoofing (Java layer) ───────────────────────────

    private void hookSystemProperties() {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");

            // get(String)
            hook(sp.getDeclaredMethod("get", String.class)).intercept(chain -> {
                String key = (String) chain.getArg(0);
                String spoofed = HiderConfig.PROP_SPOOFS.get(key);
                if (spoofed != null) {
                    return spoofed;
                }
                return chain.proceed();
            });

            // get(String, String)
            hook(sp.getDeclaredMethod("get", String.class, String.class)).intercept(chain -> {
                String key = (String) chain.getArg(0);
                String spoofed = HiderConfig.PROP_SPOOFS.get(key);
                if (spoofed != null) {
                    return spoofed;
                }
                return chain.proceed();
            });

            log("SystemProperties hooks installed");
        } catch (Throwable t) {
            log("SystemProperties hook failed: " + t);
        }
    }

    private void log(String message) {
        log(android.util.Log.INFO, TAG, message);
    }
}
