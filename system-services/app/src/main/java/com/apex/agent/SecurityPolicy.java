package com.apex.agent;

import java.util.Collections;
import java.util.Set;
import java.util.HashSet;

/**
 * Central security policy enforcement for the APEX agent.
 *
 * Enforces hard constraints from the design doc:
 *   S2: Malformed LLM output → re-prompt, max 2 retries → degrade to text
 *   S4: Tool inputs from app content are untrusted data
 *   S5: Consent gate — 60s timeout → auto-deny + audit
 *   Brick-safety: no tool may touch bootloader/aboot/partition tables
 *
 * This class is referenced by ApexAgentDaemon before any tool dispatch.
 */
public final class SecurityPolicy {

    // S2: Re-prompt policy
    public static final int MAX_REPROMPT_RETRIES = 2;

    // S5: Consent timeout
    public static final int CONSENT_TIMEOUT_SECONDS = 60;

    // Tool categories
    public enum ToolCategory {
        READ_ONLY,    // contacts, status queries
        SYSFS_WRITE,  // charge threshold, governor, kcal
        SYSTEM_ACTION, // chroot start/stop
        BLOCKED       // never allowed
    }

    // Tools that are strictly read-only (no sysfs writes)
    private static final Set<String> READ_ONLY_TOOLS;
    static {
        Set<String> s = new HashSet<>();
        s.add("contacts.lookup");
        s.add("contacts.list");
        s.add("apex.status");
        s.add("apex.battery");
        s.add("apex.thermal");
        READ_ONLY_TOOLS = Collections.unmodifiableSet(s);
    }

    // Tools that write to sysfs (verified after write)
    private static final Set<String> SYSFS_WRITE_TOOLS;
    static {
        Set<String> s = new HashSet<>();
        s.add("apex.charge");
        s.add("apex.tune");
        s.add("apex.kcal");
        SYSFS_WRITE_TOOLS = Collections.unmodifiableSet(s);
    }

    // Tools that perform system actions
    private static final Set<String> SYSTEM_ACTION_TOOLS;
    static {
        Set<String> s = new HashSet<>();
        s.add("apex.chroot.start");
        s.add("apex.chroot.stop");
        SYSTEM_ACTION_TOOLS = Collections.unmodifiableSet(s);
    }

    // Paths that must NEVER be touched by any tool
    private static final Set<String> FORBIDDEN_PATH_PREFIXES;
    static {
        Set<String> s = new HashSet<>();
        s.add("/dev/block/");
        s.add("/dev/by-name/");
        s.add("/bootloader");
        s.add("/aboot");
        s.add("/sbl");
        s.add("/tz");
        s.add("/hyp");
        s.add("/modem");
        s.add("/persist");
        s.add("/frp");
        s.add("/misc");
        s.add("/metadata");
        s.add("/xbl");
        s.add("/aop");
        s.add("/qupv3");
        s.add("/shrm");
        s.add("/cmnlib");
        s.add("/dev/mem");
        s.add("/dev/kmem");
        s.add("/dev/port");
        FORBIDDEN_PATH_PREFIXES = Collections.unmodifiableSet(s);
    }

    private SecurityPolicy() {}

    /**
     * Classify a tool by its category for consent and verification rules.
     */
    public static ToolCategory classifyTool(String toolName) {
        if (toolName == null) {
            return ToolCategory.BLOCKED;
        }
        if (READ_ONLY_TOOLS.contains(toolName)) {
            return ToolCategory.READ_ONLY;
        }
        if (SYSFS_WRITE_TOOLS.contains(toolName)) {
            return ToolCategory.SYSFS_WRITE;
        }
        if (SYSTEM_ACTION_TOOLS.contains(toolName)) {
            return ToolCategory.SYSTEM_ACTION;
        }
        return ToolCategory.BLOCKED;
    }

    /**
     * Check if a path is forbidden by brick-safety rules.
     */
    public static boolean isForbiddenPath(String path) {
        if (path == null) {
            return false;
        }
        String lower = path.toLowerCase();
        for (String prefix : FORBIDDEN_PATH_PREFIXES) {
            if (lower.startsWith(prefix.toLowerCase())) {
                return true;
            }
        }
        return false;
    }

    /**
     * Check if a tool is allowed to be called.
     * Blocked tools and forbidden paths are rejected.
     */
    public static boolean isToolAllowed(String toolName, String toolArgs) {
        ToolCategory cat = classifyTool(toolName);
        if (cat == ToolCategory.BLOCKED) {
            return false;
        }
        if (toolArgs != null && isForbiddenPath(toolArgs)) {
            return false;
        }
        // Check for injection in args
        if (UntrustedInputSanitizer.hasInjectionMarkers(toolArgs)) {
            return false;
        }
        return true;
    }

    /**
     * Determine if a tool requires consent (all non-read-only tools do).
     */
    public static boolean requiresConsent(String toolName) {
        ToolCategory cat = classifyTool(toolName);
        return cat != ToolCategory.READ_ONLY;
    }

    /**
     * Determine if a tool requires effect verification after execution.
     */
    public static boolean requiresEffectVerification(String toolName) {
        return classifyTool(toolName) == ToolCategory.SYSFS_WRITE;
    }

    /**
     * Get the consent timeout in seconds (S5: 60s).
     */
    public static int getConsentTimeout() {
        return CONSENT_TIMEOUT_SECONDS;
    }

    /**
     * Get the max re-prompt retries for malformed LLM output (S2: 2).
     */
    public static int getMaxRepromptRetries() {
        return MAX_REPROMPT_RETRIES;
    }
}
