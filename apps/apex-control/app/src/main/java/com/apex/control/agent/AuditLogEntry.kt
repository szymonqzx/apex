package com.apex.control.agent

/**
 * A single entry in the agent audit log.
 *
 * Records every tool invocation for transparency and post-hoc review.
 * The audit log is append-only, SELinux-protected, stored in SQLite
 * at /data/system/apex/consent_audit.db.
 */
data class AuditLogEntry(
  val id: Long,
  val timestamp: String,
  val toolName: String,
  val description: String,
  val action: String,
  val result: AuditResult,
  val durationMs: Long,
)

/**
 * Outcome of a consent-gated tool invocation.
 */
enum class AuditResult(val label: String) {
  APPROVED("Approved"),
  DENIED("Denied"),
  TIMEOUT("Denied by timeout"),
  ;

  companion object {
    fun fromString(s: String): AuditResult =
      entries.find { it.name.equals(s, ignoreCase = true) } ?: DENIED
  }
}
