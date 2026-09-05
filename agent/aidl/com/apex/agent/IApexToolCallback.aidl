// IApexToolCallback.aidl
//
// Callback interface for MCP tool consent flow.
// Implemented by the Apex Control app (or any system UI component) and
// registered with LlmManagerService via IApexAgent.registerToolCallback().
//
// When apexagentd generates a response containing a tool-call JSON block,
// LlmManagerService invokes onToolConsentRequested() on the registered
// callback. The callback implementation displays a consent dialog to the
// user and returns the user's decision through the ConsentGate state machine.

package com.apex.agent;

/** @hide */
oneway interface IApexToolCallback {
    /**
     * Called when a tool invocation requires human approval.
     *
     * @param toolName       Name of the MCP tool (e.g. "contacts", "apex-charge")
     * @param description    Human-readable description of the tool
     * @param proposedAction The specific action the model wants to perform
     *
     * The implementer should display a consent UI and then call back into
     * the ConsentGate (via IApexAgent or a direct binder call) to record
     * the user's decision. This method is oneway to avoid blocking the
     * system_server binder thread.
     */
    void onToolConsentRequested(String toolName, String description, String proposedAction);

    /**
     * Health check: returns true if the daemon (apexagentd) is alive
     * from the callback implementer's perspective. Used by LlmManagerService
     * to cross-check daemon liveness.
     */
    boolean isDaemonAlive();
}
