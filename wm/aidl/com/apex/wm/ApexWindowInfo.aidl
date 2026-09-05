// ApexWindowInfo.aidl — parcelable for window info
package com.apex.wm;

parcelable ApexWindowInfo {
    String windowId;
    String packageName;
    String title;
    int x;
    int y;
    int width;
    int height;
    int zOrder;
    boolean minimized;
    boolean focused;
}
