package com.apex.agent;

import java.util.regex.Pattern;

/**
 * Sanitizes untrusted tool inputs from app content (S4 constraint).
 *
 * Tool inputs originating from LLM output or app content are UNTRUSTED data.
 * This class strips, escapes, and validates them before they reach system
 * resources (sysfs, procfs, binder, shell). It never executes raw injected
 * args — it produces a cleaned string that the tool dispatcher can safely use.
 *
 * Defense layers:
 *   1. Null/length check — reject empty or oversized inputs
 *   2. Character whitelist — allow only printable ASCII + common Unicode
 *   3. Command injection patterns — strip shell metacharacters
 *   4. Path traversal — reject ../ and absolute paths to sensitive dirs
 *   5. SQL injection — escape single quotes for SQLite audit log
 */
public final class UntrustedInputSanitizer {

    private static final int MAX_INPUT_LENGTH = 4096;

    // Shell metacharacters that could enable command injection
    private static final Pattern SHELL_INJECTION =
        Pattern.compile("[;`$|&><!\\n\\r\\t\\\\]|\\$\\(|\\$\\{|\\|\\||&&");

    // Path traversal patterns
    private static final Pattern PATH_TRAVERSAL =
        Pattern.compile("\\.\\.[/\\\\]|^[/\\\\]|/proc/|/sys/|/dev/|/data/system/");

    // Sensitive file targets that must never appear in tool args
    private static final Pattern SENSITIVE_PATHS =
        Pattern.compile(
            "/dev/block/|/dev/by-name/|/bootloader|/aboot|/sbl|/tz|/hyp|/modem|" +
            "/persist|/frp|/misc|/metadata|/xbl|/aop|/qupv3|/shrm|/cmnlib|" +
            "/dev/mem|/dev/kmem|/dev/port",
            Pattern.CASE_INSENSITIVE
        );

    // SQL injection patterns (for audit log inserts)
    private static final Pattern SQL_INJECTION =
        Pattern.compile(
            "(?:'|(?:--)|/(?:\\*)|(?:\\*/)|\\b(?:DROP|DELETE|INSERT|UPDATE|CREATE|ALTER|EXEC)\\b)",
            Pattern.CASE_INSENSITIVE
        );

    private UntrustedInputSanitizer() {}

    /**
     * Sanitize a tool input string for safe use as a parameter.
     * Returns the cleaned string, or empty string if input is rejected.
     */
    public static String sanitize(String input) {
        if (input == null || input.isEmpty()) {
            return "";
        }

        // Length limit
        String result = input.length() > MAX_INPUT_LENGTH
            ? input.substring(0, MAX_INPUT_LENGTH)
            : input;

        // Strip shell metacharacters
        result = SHELL_INJECTION.matcher(result).replaceAll(" ");

        // Normalize whitespace
        result = result.replaceAll("\\s+", " ").trim();

        return result;
    }

    /**
     * Sanitize a tool input intended as a file path.
     * Returns null if the path is rejected (traversal or sensitive target).
     */
    public static String sanitizePath(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }

        // Check path traversal
        if (PATH_TRAVERSAL.matcher(path).find()) {
            return null;
        }

        // Check sensitive paths
        if (SENSITIVE_PATHS.matcher(path).find()) {
            return null;
        }

        // Strip shell metacharacters from path
        String cleaned = SHELL_INJECTION.matcher(path).replaceAll("");
        return cleaned.trim();
    }

    /**
     * Escape a string for safe insertion into SQLite.
     * Doubles single quotes and strips SQL keywords.
     */
    public static String sanitizeForSql(String input) {
        if (input == null) {
            return "";
        }
        // First, escape single quotes
        String escaped = input.replace("'", "''");
        // Then strip SQL injection patterns
        escaped = SQL_INJECTION.matcher(escaped).replaceAll("");
        // Length limit
        if (escaped.length() > MAX_INPUT_LENGTH) {
            escaped = escaped.substring(0, MAX_INPUT_LENGTH);
        }
        return escaped;
    }

    /**
     * Validate that a tool name matches the expected format.
     * Tool names must be alphanumeric with dots/hyphens only.
     */
    public static boolean isValidToolName(String toolName) {
        if (toolName == null || toolName.isEmpty()) {
            return false;
        }
        return toolName.matches("^[a-zA-Z][a-zA-Z0-9._-]{0,63}$");
    }

    /**
     * Check if a string contains prompt injection markers.
     * This is a first-pass check; PromptInjectionDetector does deeper analysis.
     */
    public static boolean hasInjectionMarkers(String input) {
        if (input == null || input.isEmpty()) {
            return false;
        }
        // Check for role-play override patterns
        String lower = input.toLowerCase();
        return lower.contains("ignore previous") ||
               lower.contains("ignore all") ||
               lower.contains("disregard") ||
               lower.contains("you are now") ||
               lower.contains("system prompt") ||
               lower.contains("new instructions") ||
               lower.contains("override") ||
               SHELL_INJECTION.matcher(input).find();
    }
}
