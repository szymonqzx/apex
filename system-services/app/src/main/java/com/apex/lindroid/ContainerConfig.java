/*
 * ContainerConfig.java
 *
 * Configuration for the Lindroid Linux container.
 * Defines namespace isolation, network, display bridge, and
 * filesystem mount options for the Arch Linux ARM container
 * running alongside Android.
 *
 * Architecture:
 *   - PID namespace: isolated (container sees only its own processes)
 *   - Network namespace: veth pair (container gets own IP)
 *   - Mount namespace: isolated (container has own mount table)
 *   - User namespace: mapped (container root → unprivileged on host)
 *   - IPC namespace: isolated (container has own IPC namespace)
 *   - UTS namespace: isolated (container has own hostname)
 *
 * No KVM on SM6225 — this is container-based, not VM-based.
 */

package com.apex.lindroid;

import android.util.Log;

import org.json.JSONObject;

public class ContainerConfig {
  private static final String TAG = "ContainerConfig";

  // Container root filesystem
  private String containerRoot = "/data/adb/apex/arch";

  // Network configuration
  private boolean networkEnabled = true;
  private String containerIp = "10.0.3.2";
  private String hostBridgeIp = "10.0.3.1";
  private String vethHost = "apex-veth0";
  private String vethContainer = "apex-veth1";
  private int subnetPrefix = 24;

  // Display bridge
  private String displayMode = "x11";  // "x11" or "wayland"
  private String displaySocket = "/tmp/.X11-unix/X0";
  private int displayWidth = 1920;
  private int displayHeight = 1080;

  // Namespace isolation
  private boolean pidNamespace = true;
  private boolean netNamespace = true;
  private boolean mountNamespace = true;
  private boolean userNamespace = true;
  private boolean ipcNamespace = true;
  private boolean utsNamespace = true;

  // Resource limits
  private int cpuQuota = 0;       // 0 = no limit, percentage of total
  private int memoryLimitMb = 0;  // 0 = no limit
  private int processLimit = 256; // max processes in container

  // Shared filesystem mounts (bind mounts from host)
  private String[] sharedMounts = {
      "/data/adb/apex/arch/home",
      "/data/adb/apex/arch/tmp"
  };

  // Hostname for the container
  private String hostname = "apex-lindroid";

  // Init command (run inside container on start)
  private String initCommand = "/sbin/init";

  public ContainerConfig() {
    Log.d(TAG, "Default container config created");
  }

  /**
   * Build the unshare command line for namespace isolation.
   */
  public String[] buildUnshareArgs() {
    StringBuilder flags = new StringBuilder();
    if (pidNamespace) flags.append("--pid ");
    if (netNamespace) flags.append("--net ");
    if (mountNamespace) flags.append("--mount ");
    if (userNamespace) flags.append("--user ");
    if (ipcNamespace) flags.append("--ipc ");
    if (utsNamespace) flags.append("--uts ");

    return new String[]{
        "unshare",
        "--fork",
        flags.toString().trim(),
        "--root", containerRoot,
        "--propagation", "private",
        initCommand
    };
  }

  /**
   * Build the network setup commands for the veth pair.
   * These run on the host side after container start.
   */
  public String[] buildNetworkSetupCommands() {
    if (!networkEnabled) return new String[0];

    return new String[]{
        "ip link add " + vethHost + " type veth peer name " + vethContainer,
        "ip link set " + vethHost + " up",
        "ip addr add " + hostBridgeIp + "/" + subnetPrefix + " dev " + vethHost,
        "ip link set " + vethContainer + " netns $(pgrep -f lindroid-init)",
        "nsenter -t $(pgrep -f lindroid-init) -n ip link set lo up",
        "nsenter -t $(pgrep -f lindroid-init) -n ip link set " + vethContainer + " up",
        "nsenter -t $(pgrep -f lindroid-init) -n ip addr add "
            + containerIp + "/" + subnetPrefix + " dev " + vethContainer,
        "nsenter -t $(pgrep -f lindroid-init) -n ip route add default via " + hostBridgeIp,
        "echo 1 > /proc/sys/net/ipv4/ip_forward",
        "iptables -t nat -A POSTROUTING -s " + containerIp + "/32 -j MASQUERADE"
    };
  }

  /**
   * Build the display bridge environment variables.
   * These are set inside the container so X11/Wayland apps
   * connect to the display bridge.
   */
  public String[] buildDisplayEnv() {
    if ("x11".equals(displayMode)) {
      return new String[]{
          "DISPLAY=:0",
          "XDG_RUNTIME_DIR=/tmp",
          "PULSE_SERVER=tcp:" + hostBridgeIp
      };
    } else {
      return new String[]{
          "WAYLAND_DISPLAY=wayland-0",
          "XDG_RUNTIME_DIR=/tmp",
          "PULSE_SERVER=tcp:" + hostBridgeIp
      };
    }
  }

  /**
   * Serialize to JSON for status reporting.
   */
  public String toJson() {
    try {
      JSONObject json = new JSONObject();
      json.put("containerRoot", containerRoot);
      json.put("networkEnabled", networkEnabled);
      json.put("containerIp", containerIp);
      json.put("hostBridgeIp", hostBridgeIp);
      json.put("displayMode", displayMode);
      json.put("displayResolution", displayWidth + "x" + displayHeight);
      json.put("pidNamespace", pidNamespace);
      json.put("netNamespace", netNamespace);
      json.put("mountNamespace", mountNamespace);
      json.put("userNamespace", userNamespace);
      json.put("hostname", hostname);
      json.put("cpuQuota", cpuQuota);
      json.put("memoryLimitMb", memoryLimitMb);
      json.put("processLimit", processLimit);
      return json.toString();
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  // ── Getters and Setters ──────────────────────────────────────────

  public String getContainerRoot() { return containerRoot; }
  public void setContainerRoot(String root) { this.containerRoot = root; }

  public boolean isNetworkEnabled() { return networkEnabled; }
  public void setNetworkEnabled(boolean enabled) { this.networkEnabled = enabled; }

  public String getContainerIp() { return containerIp; }
  public void setContainerIp(String ip) { this.containerIp = ip; }

  public String getDisplayMode() { return displayMode; }
  public void setDisplayMode(String mode) { this.displayMode = mode; }

  public int getDisplayWidth() { return displayWidth; }
  public void setDisplayWidth(int w) { this.displayWidth = w; }

  public int getDisplayHeight() { return displayHeight; }
  public void setDisplayHeight(int h) { this.displayHeight = h; }

  public String getHostname() { return hostname; }
  public void setHostname(String hostname) { this.hostname = hostname; }

  public int getCpuQuota() { return cpuQuota; }
  public void setCpuQuota(int quota) { this.cpuQuota = quota; }

  public int getMemoryLimitMb() { return memoryLimitMb; }
  public void setMemoryLimitMb(int mb) { this.memoryLimitMb = mb; }

  public int getProcessLimit() { return processLimit; }
  public void setProcessLimit(int limit) { this.processLimit = limit; }
}
