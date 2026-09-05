// IApexAgent.aidl
//
// Binder interface for the APEX LLM Agent service (LlmManagerService).
// Lives in system_server; dispatches inference to apexagentd via local socket.
//
// Clients (Apex Control app, system UI, other system services) obtain this
// interface via ServiceManager.getService("apex.agent").

package com.apex.agent;

import com.apex.agent.IApexToolCallback;
import com.apex.agent.ApexAgentStatus;

/** @hide */
interface IApexAgent {
    // --- Chat ---

    /**
     * Send a chat prompt using the currently active model tier.
     * Returns the generated text, or an error string in fallback mode.
     */
    String chat(String prompt);

    /**
     * Send a chat prompt with an explicit model override.
     * The modelId must be present in listAvailableModels().
     */
    String chatWithModel(String prompt, String modelId);

    // --- Model tier management ---

    /**
     * Set the active model tier. Valid values: "nano", "small", "medium", "large".
     * The tier determines which GGUF model apexagentd loads on next request.
     */
    void setModelTier(String tier);

    /**
     * Get the currently active model tier.
     */
    String getModelTier();

    /**
     * List all available model IDs known to the registry.
     */
    List<String> listAvailableModels();

    // --- Status ---

    /**
     * Get the current agent status (daemon state, model, throughput, fallback).
     */
    ApexAgentStatus getStatus();

    // --- Audit log ---

    /**
     * Query the consent audit log. Returns the most recent `limit` entries
     * as a list of newline-delimited records.
     */
    String getAuditLog(int limit);

    // --- MCP tool callback registration ---

    /**
     * Register a callback to receive MCP tool consent requests.
     * The callback's onToolConsentRequested() is invoked when apexagentd
     * produces a response containing a tool call that requires human approval.
     */
    void registerToolCallback(IApexToolCallback cb);

    /**
     * Unregister a previously registered tool callback.
     */
    void unregisterToolCallback(IApexToolCallback cb);
}
