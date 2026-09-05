// ApexAgentStatus.aidl
//
// Parcelable status snapshot returned by IApexAgent.getStatus().
// Reflects the current state of the agent daemon and inference layer.

package com.apex.agent;

parcelable ApexAgentStatus {
  boolean daemonRunning;
  String currentModel;
  int loadedModelSizeMB;
  float tokensPerSecond;
  boolean fallbackMode;
}
