// ILindroid.aidl — Binder interface for Lindroid container manager
package com.apex.lindroid;

/** @hide */
interface ILindroid {
    /** Start the Linux container */
    String startContainer();

    /** Stop the Linux container */
    String stopContainer();

    /** Execute a command inside the container */
    String exec(String command);

    /** Install a package in the container (pacman) */
    String installPackage(String packageName);

    /** Launch a Linux GUI app via display bridge */
    String launchApp(String appName);

    /** Get container status as JSON */
    String getStatus();

    /** Check if container is running */
    boolean isRunning();

    /** Migrate existing chroot to container */
    String migrate();
}
