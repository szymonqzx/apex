# libxposed API module rules (active when minification is enabled).
# Mirrors https://github.com/libxposed/api — keep the entry class and adapt
# the registration file when obfuscation rewrites class names.
-dontwarn io.github.libxposed.annotation.**
-adaptresourcefilecontents META-INF/xposed/java_init.list
-keep,allowoptimization,allowobfuscation public class * extends io.github.libxposed.api.XposedModule {
    public <init>();
}
