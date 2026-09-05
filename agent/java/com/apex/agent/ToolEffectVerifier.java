package com.apex.agent;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

/**
 * Verifies that tool effects (sysfs/procfs writes) actually took effect
 * before reporting success to the agent or user.
 *
 * This implements the "tool-effect verification" security control:
 * after a tool writes to a sysfs/procfs path, we read it back and confirm
 * the value matches the expected result. If verification fails, the tool
 * reports failure — never claims success without proof.
 *
 * This is critical for consent audit integrity: the audit log must record
 * what actually happened, not what was attempted.
 */
public final class ToolEffectVerifier {

    public static final class VerificationResult {
        public final boolean success;
        public final String actualValue;
        public final String expectedValue;
        public final String path;

        VerificationResult(boolean success, String actualValue,
                          String expectedValue, String path) {
            this.success = success;
            this.actualValue = actualValue;
            this.expectedValue = expectedValue;
            this.path = path;
        }
    }

    private ToolEffectVerifier() {}

    /**
     * Read a sysfs/procfs value and compare to expected.
     *
     * @param path      The sysfs/procfs path to read
     * @param expected  The expected value (trimmed comparison)
     * @return VerificationResult with success/failure and actual value
     */
    public static VerificationResult verifySysfsWrite(String path, String expected) {
        if (path == null || expected == null) {
            return new VerificationResult(false, null, expected, path);
        }

        // Security: only allow reads from sysfs/procfs
        if (!path.startsWith("/sys/") && !path.startsWith("/proc/")) {
            return new VerificationResult(false, null, expected, path);
        }

        String actual = null;
        try (BufferedReader reader = new BufferedReader(new FileReader(path))) {
            actual = reader.readLine();
        } catch (IOException e) {
            return new VerificationResult(false, null, expected, path);
        }

        if (actual == null) {
            return new VerificationResult(false, null, expected, path);
        }

        boolean match = actual.trim().equals(expected.trim());
        return new VerificationResult(match, actual, expected, path);
    }

    /**
     * Verify a numeric sysfs write (e.g., charge threshold, governor).
     * Handles integer comparison with tolerance for rounding.
     *
     * @param path       The sysfs path to read
     * @param expected   The expected integer value
     * @return VerificationResult
     */
    public static VerificationResult verifySysfsInt(String path, int expected) {
        VerificationResult raw = verifySysfsWrite(path, String.valueOf(expected));
        if (raw.actualValue == null) {
            return raw;
        }
        try {
            int actual = Integer.parseInt(raw.actualValue.trim());
            boolean match = actual == expected;
            return new VerificationResult(
                match, raw.actualValue, String.valueOf(expected), path);
        } catch (NumberFormatException e) {
            return new VerificationResult(false, raw.actualValue,
                String.valueOf(expected), path);
        }
    }

    /**
     * Verify a boolean sysfs state (e.g., gaming mode toggle).
     *
     * @param path     The sysfs path
     * @param expected The expected state (true = 1, false = 0)
     * @return VerificationResult
     */
    public static VerificationResult verifySysfsBool(String path, boolean expected) {
        return verifySysfsInt(path, expected ? 1 : 0);
    }

    /**
     * Verify that a file exists at the given path.
     * Used for model download verification.
     *
     * @param path The file path to check
     * @return true if file exists and is readable
     */
    public static boolean verifyFileExists(String path) {
        if (path == null) {
            return false;
        }
        java.io.File f = new java.io.File(path);
        return f.exists() && f.canRead();
    }

    /**
     * Verify file size is non-zero (for download completion check).
     */
    public static boolean verifyFileNonEmpty(String path) {
        if (!verifyFileExists(path)) {
            return false;
        }
        return new java.io.File(path).length() > 0;
    }
}
