package com.apex.wm;

import android.os.Parcel;
import android.os.Parcelable;

/**
 * Parcelable for window info returned by IApexWindowManager.
 */
public class ApexWindowInfo implements Parcelable {
    public String windowId;
    public String packageName;
    public String title;
    public int x;
    public int y;
    public int width;
    public int height;
    public int zOrder;
    public boolean minimized;
    public boolean focused;

    public ApexWindowInfo() {}

    protected ApexWindowInfo(Parcel in) {
        windowId = in.readString();
        packageName = in.readString();
        title = in.readString();
        x = in.readInt();
        y = in.readInt();
        width = in.readInt();
        height = in.readInt();
        zOrder = in.readInt();
        minimized = in.readByte() != 0;
        focused = in.readByte() != 0;
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
        dest.writeString(windowId);
        dest.writeString(packageName);
        dest.writeString(title);
        dest.writeInt(x);
        dest.writeInt(y);
        dest.writeInt(width);
        dest.writeInt(height);
        dest.writeInt(zOrder);
        dest.writeByte((byte) (minimized ? 1 : 0));
        dest.writeByte((byte) (focused ? 1 : 0));
    }

    @Override
    public int describeContents() {
        return 0;
    }

    public static final Creator<ApexWindowInfo> CREATOR = new Creator<ApexWindowInfo>() {
        @Override
        public ApexWindowInfo createFromParcel(Parcel in) {
            return new ApexWindowInfo(in);
        }

        @Override
        public ApexWindowInfo[] newArray(int size) {
            return new ApexWindowInfo[size];
        }
    };
}
