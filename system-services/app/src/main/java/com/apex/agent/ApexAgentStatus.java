/*
 * ApexAgentStatus.java
 *
 * Parcelable implementation for ApexAgentStatus.aidl.
 * Carries a snapshot of the agent daemon state across binder.
 */

package com.apex.agent;

import android.os.Parcel;
import android.os.Parcelable;

public class ApexAgentStatus implements Parcelable {
  public boolean daemonRunning;
  public String currentModel;
  public int loadedModelSizeMB;
  public float tokensPerSecond;
  public boolean fallbackMode;

  public ApexAgentStatus() {
    this.daemonRunning = false;
    this.currentModel = "";
    this.loadedModelSizeMB = 0;
    this.tokensPerSecond = 0.0f;
    this.fallbackMode = true;
  }

  public ApexAgentStatus(
      boolean daemonRunning,
      String currentModel,
      int loadedModelSizeMB,
      float tokensPerSecond,
      boolean fallbackMode) {
    this.daemonRunning = daemonRunning;
    this.currentModel = currentModel;
    this.loadedModelSizeMB = loadedModelSizeMB;
    this.tokensPerSecond = tokensPerSecond;
    this.fallbackMode = fallbackMode;
  }

  protected ApexAgentStatus(Parcel in) {
    daemonRunning = in.readByte() != 0;
    currentModel = in.readString();
    loadedModelSizeMB = in.readInt();
    tokensPerSecond = in.readFloat();
    fallbackMode = in.readByte() != 0;
  }

  @Override
  public int describeContents() {
    return 0;
  }

  @Override
  public void writeToParcel(Parcel dest, int flags) {
    dest.writeByte((byte) (daemonRunning ? 1 : 0));
    dest.writeString(currentModel);
    dest.writeInt(loadedModelSizeMB);
    dest.writeFloat(tokensPerSecond);
    dest.writeByte((byte) (fallbackMode ? 1 : 0));
  }

  public static final Creator<ApexAgentStatus> CREATOR =
      new Creator<ApexAgentStatus>() {
        @Override
        public ApexAgentStatus createFromParcel(Parcel in) {
          return new ApexAgentStatus(in);
        }

        @Override
        public ApexAgentStatus[] newArray(int size) {
          return new ApexAgentStatus[size];
        }
      };

  @Override
  public String toString() {
    return "ApexAgentStatus{"
        + "daemonRunning=" + daemonRunning
        + ", currentModel='" + currentModel + "'"
        + ", loadedModelSizeMB=" + loadedModelSizeMB
        + ", tokensPerSecond=" + tokensPerSecond
        + ", fallbackMode=" + fallbackMode
        + "}";
  }
}
