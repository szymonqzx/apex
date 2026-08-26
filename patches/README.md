# Kernel patches

Each subdirectory will hold one patch (or a series of patches) for a specific
kernel subsystem. Currently empty.

## Patches to draft

| Directory | Purpose | Source |
| :--- | :--- | :--- |
| `su-kernelsu/` | KernelSU-Next inline VFS + syscall hooks | https://kernelsu.org |
| `susfs/` | Mount/kallsyms/AVC spoof | https://gitlab.com/susfs/susfs |
| `kernelsu-hide-pid/` | `/proc/<pid>/attr/current` + loginuid hide | community patch |
| `kernelsu-tracepoint-remap/` | Disable `ksucalls` tracepoint | community patch |
| `apex-governor/` | Per-cluster governor (Bandido-class) | TBD |
| `apex-state/` | 4-input compiled state machine | TBD |
| `apex-watchdog/` | 5-min in-kernel self-heal | TBD |
| `apex-immortal/` | oom_score_adj=-1000 for desk clock | TBD |
| `apex-autoload/` | VID:PID → request_module | TBD |
| `device-backport-sm5602/` | Fuel-gauge fix (ChicKernel) | https://github.com/chickendrop89/device_xiaomi_gemstones-kernel |
| `device-backport-dwc3-msm-core/` | USB fix (ChicKernel) | same |
| `device-backport-mi-thermald/` | Wrong-core shutdown fix (ChicKernel) | same |

## Status

Empty. Theory only. No patches applied to any source tree.
