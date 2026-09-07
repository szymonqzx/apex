# 10 — Lindroid

## Overview

Lindroid is a Linux container manager for APEX ROM. It runs an Arch Linux ARM distribution alongside Android using Linux namespace isolation (pid, net, mount, user). Unlike a full VM, the container shares the Android kernel — there's no KVM on SM6225. The container is managed via shell scripts that call `unshare`/`nsenter` for namespace isolation, with a Java service handling lifecycle and providing a binder interface.

## Architecture

```
Android (host)
  ├── system_server
  │    └── LindroidManager (binder service: apex_lindroid)
  │         ├── lindroid-start.sh → unshare --pid --net --mount
  │         ├── lindroid-stop.sh  → kill container process
  │         ├── lindroid-exec.sh  → nsenter → run command in container
  │         ├── lindroid-init.sh  → download + extract Arch Linux ARM rootfs
  │         └── lindroid-migrate.sh → configure container
  │
  └── Container (Arch Linux ARM)
       ├── Rootfs: /data/adb/apex/arch
       ├── PID namespace: isolated process tree
       ├── Network namespace: veth pair, own IP
       ├── Mount namespace: own /proc, /sys, /dev
       └── Display: X11 forwarding to Termux:X11 or Wayland proxy
```

## LindroidManager (205 lines)

System service running in system_server. Binder service name: `apex_lindroid`.

### ILindroid.aidl (29 lines)
```java
interface ILindroid {
    String startContainer();
    String stopContainer();
    String exec(String command);
    String installPackage(String packageName);
    String launchApp(String appName);
    String getStatus();
    boolean isRunning();
    String migrate();
}
```

### Implementation Details

**Start**: executes `lindroid-start.sh` via `Runtime.exec()`. The script uses `unshare` to create new namespaces and `chroot` into the Arch Linux ARM rootfs.

**Stop**: executes `lindroid-stop.sh` which kills the container process and cleans up namespaces.

**Exec**: executes `lindroid-exec.sh <command>` which uses `nsenter` to enter the container's namespaces and run the command.

**Install**: calls `exec("pacman -Sy --noconfirm " + packageName)` — uses Arch's package manager.

**Launch app**: calls `exec("DISPLAY=:0 " + appName + " &")` — sets the X11 display and launches the app in background.

## ContainerConfig (197 lines)

Configuration data class for container parameters:
- **rootfs path**: `/data/adb/apex/arch`
- **network mode**: veth (virtual ethernet pair)
- **display**: X11 forwarding
- **shared mounts**: `/data/adb/apex/arch` accessible from both Android and container
- **capabilities**: CAP_SYS_ADMIN (for mount), CAP_NET_ADMIN (for veth setup)

## DisplayBridge (208 lines)

Handles display forwarding between the container and Android:
- **X11 mode**: forwards to Termux:X11 or a Wayland proxy
- **VNC mode**: optional VNC server for remote display
- **Input**: mouse/keyboard events from Android input subsystem

## Scripts

### lindroid-init.sh (58 lines)
One-time setup. Downloads Arch Linux ARM aarch64 rootfs from `os.archlinuxarm.org`, extracts to `/data/adb/apex/arch`, runs migration script.

Prerequisites:
- ~2GB free space on /data
- Network access
- Root access (KSU)

### lindroid-start.sh (75 lines)
Starts the container:
1. Verifies rootfs exists at `/data/adb/apex/arch`
2. Creates veth pair for network namespace
3. Calls `unshare --pid --net --mount --user`
4. `chroot` into rootfs
5. Starts init system (systemd or openrc)
6. Configures network interface inside container

### lindroid-stop.sh (38 lines)
Stops the container:
1. Sends SIGTERM to container init process
2. Waits 5s for graceful shutdown
3. Sends SIGKILL if still running
4. Cleans up veth interface
5. Unmounts container filesystems

### lindroid-exec.sh (34 lines)
Executes a command inside the running container:
1. Gets container PID from pidfile
2. Calls `nsenter --target <pid> --pid --net --mount -- <command>`
3. Returns stdout/stderr

### lindroid-migrate.sh (101 lines)
Configures a fresh or existing container:
1. Creates `/etc/lindroid.conf` configuration file
2. Sets up pacman repositories
3. Installs base packages (bash, coreutils, openssh)
4. Configures user account
5. Sets up X11 forwarding

## SELinux Policy (apex_lindroid.te)

```te
# LindroidManager runs in system_server. It launches shell scripts
# that use unshare/nsenter for container isolation.
#
# The container process needs:
#   - CAP_SYS_ADMIN (for unshare/mount)
#   - CAP_NET_ADMIN (for veth setup)
#   - Network access (container has its own net namespace)
#   - Access to /data/adb/apex/arch (container rootfs)

# system_server can exec shell scripts and has the needed capabilities.
```

## Agent Integration

The agent can control Lindroid via MCP tools:
- `apex-lindroid-start` — start the container (read-only, no consent)
- `apex-lindroid-stop` — stop the container (read-only, no consent)
- `apex-lindroid-exec` — execute command in container (read-only, no consent)
- `apex-lindroid-install` — install package via pacman (read-only, no consent)
- `apex-lindroid-launch-app` — launch Linux GUI app (read-only, no consent)

These are classified as read-only because the container is a sandboxed environment — commands inside the container cannot affect the Android host.

## Limitations

- No KVM — container, not VM. Kernel is shared with Android.
- `CONFIG_USER_NS` is disabled (security: user namespaces enable privilege escalation). Container uses `chroot` + `unshare --pid --net --mount` instead.
- `CONFIG_PID_NS` is disabled. The container's PID isolation is via `unshare --pid`, but without kernel PID namespace support, this is limited.
- No container image is pre-built — `lindroid-init.sh` downloads the rootfs on first use.
- No automatic startup — container must be manually started via Apex Control or agent.
- Display forwarding requires Termux:X11 or similar X11 server to be installed on Android.
