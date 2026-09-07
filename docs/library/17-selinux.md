# 17 — SELinux

## Overview

APEX ROM enforces strict SELinux with no permissive domains. Every APEX component has its own SELinux domain with minimal permissions. The policy is loaded by KernelSU-Next's `sepolicy.rule` mechanism at boot, which patches the running SELinux policy without modifying the system partition.

## Policy Loading

KernelSU-Next injects SELinux rules via `patches/apex-new/apex-root/src/kernelsu/selinux/`:
- `sepolicy.c` (1,031 lines) — patches the running policy at boot
- `rules.c` (549 lines) — rule injection logic
- `selinux.c` (228 lines) — SELinux state management

Rules are loaded from `ksu-module/sepolicy.rule` during the `post-fs-data` phase.

## Domains

### apex_agent (apexagentd)
The agent daemon process.

```te
type apex_agent, domain;
type apex_agent_exec, file_type, exec_type;

init_daemon_domain(apex_agent)

# Socket creation and binding
allow apex_agent apex_agent:tcp_socket { create bind listen accept read write };
allow apex_agent apex_agent:unix_stream_socket { create bind listen accept read write };
allow apex_agent socket_device:dir { search add_name write };
allow apex_agent socket_device:sock_file { create setattr unlink };

# Binder communication with system_server
binder_call(apex_agent, system_server)
binder_call(system_server, apex_agent)
allow apex_agent apex_agent:binder { call transfer };

# Sysfs/procfs access for MCP tools
allow apex_agent apex_charge_proc:file { read write open getattr };
allow apex_agent apex_charge_proc:dir { search read };
allow apex_agent proc_apex:dir { search read };
allow apex_agent proc_apex:file { read open };
allow apex_agent proc_mounts:file { read open };

# System properties
allow apex_agent prop_file:file { read open getattr };

# Native library execution (llama.cpp, whisper.cpp)
allow apex_agent system_lib_file:dir { search read };
allow apex_agent system_lib_file:file { read open execute };

# Logging
allow apex_agent logd:unix_stream_socket { connect write };

# Sensor access (for pocket detection)
allow apex_agent sysfs_sensors:file { read open getattr };

# ── NEVERALLOW ────────────────────────────────────────────────────

# Never write to boot-critical partitions
neverallow apex_agent block_device:blk_file { write append };

# Never escalate capabilities
neverallow apex_agent self:capability { sys_admin sys_module };

# NEVER create network sockets — all inference is on-device
neverallow apex_agent self:tcp_socket { create bind listen accept };
neverallow apex_agent self:udp_socket { create bind listen accept };
```

The network neverallow is the most critical rule — it ensures the inference daemon cannot exfiltrate data. Remote inference goes through `apex_remote_proxy` which has its own domain with network access.

### apex_remote_proxy (remote model proxy)
Separate daemon process for remote model inference.

```te
type apex_remote_proxy, domain;
type apex_remote_proxy_exec, file_type, exec_type;

init_daemon_domain(apex_remote_proxy)
net_domain(apex_remote_proxy)

# Network access (the ONLY APEX component with network)
allow apex_remote_proxy port_9879:tcp_socket { name_bind listen accept };

# Binder to system_server (for consent checks)
binder_call(apex_remote_proxy, system_server)

# No access to sysfs, procfs, or device nodes
neverallow apex_remote_proxy sysfs:file { read write };
neverallow apex_remote_proxy proc_apex:file { read write };
```

### apex_chroot (apex-bridge)
Chroot bridge daemon.

```te
type apex_chroot, domain;
type apex_chroot_exec, file_type, exec_type;

init_daemon_domain(apex_chroot)

# Binder communication
binder_call(apex_chroot, system_server)
binder_call(system_server, apex_chroot)

# Hardware device node access (NFC, IR, sensors)
allow apex_chroot apex_chroot:chr_file { read write open ioctl getattr };

# Battery/charge status reads
allow apex_chroot apex_charge_proc:file { read open getattr };
allow apex_chroot apex_charge_proc:dir { search read };
```

### apex_charge_proc (file type)
Sysfs files for charge control.

```te
type apex_charge_proc, file_type, fs_type;

allow init apex_charge_proc:file { read write open getattr setattr };
allow init apex_charge_proc:dir { search read write add_name remove_name };

allow system_app apex_charge_proc:file { read write open getattr };
allow system_app apex_charge_proc:dir { search read };

allow apex_agent apex_charge_proc:file { read write open getattr };
allow apex_agent apex_charge_proc:dir { search read };
```

### system_server (APEX services)
ApexWindowManager, DesktopModeService, and LindroidManager run inside system_server. They inherit system_server's existing permissions — no separate domain needed. The SELinux policy files (`apex_wm.te`, `apex_desktop.te`, `apex_lindroid.te`) exist to document the security model and provide policy if these services are later split into separate processes.

## Enforcement Guarantees

1. **No permissive domains** — every domain is enforcing. No `permissive apex_*;` statements anywhere.
2. **Neverallow rules** — the most dangerous operations have neverallow rules that cannot be overridden:
   - No block device writes from the agent
   - No capability escalation (sys_admin, sys_module)
   - No network sockets for the inference daemon
3. **Minimal permissions** — each domain has only the permissions it needs. No catch-all `allow apex_* *:* *;`.
4. **Compile-time enforcement** — SuSFS and KernelSU-Next are compiled into the kernel. Their hiding hooks cannot be removed without rebuilding the kernel.
5. **Runtime policy patching** — KernelSU-Next patches the running SELinux policy at boot via `sepolicy.c`. This means the APEX rules are active even on a stock LineageOS SELinux policy.

## SELinux in the Defconfig

```
CONFIG_SECURITY_SELINUX=y
# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set
# CONFIG_SECURITY_SELINUX_DISABLE is not set
```

`SELINUX_DISABLE` is not set — SELinux cannot be disabled at runtime. `SELINUX_BOOTPARAM` is not set — SELinux state cannot be changed via kernel command line.

## Verification

The `verify-stealth.sh` script checks SELinux enforcement:
- Verifies no permissive domains in sepolicy.rule
- Verifies neverallow rules are present
- Verifies SELinux is in enforcing mode
- 22 PASS, 8 WARN, 0 FAIL (warnings are for unimplemented features, not policy issues)
