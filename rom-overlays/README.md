# ROM overlays

Dirty-applied overlays for the existing LineageOS install. **None of these are
written yet.**

## Files (to be created)

| Path | Purpose |
| :--- | :--- |
| `build.prop/system.build.prop.append` | Stock-equivalent `ro.build.*` for PIF |
| `build.prop/vendor.build.prop.append` | Vendor build props for PIF |
| `init.d/apex_power.rc` | BT cgroup + sensor cap + wifi watchdog |
| `thermald/thermald.conf` | 45/55/65°C trip + adaptive learner |
| `selinux/apex_chown.te` | Chroot raw-HW SELinux policy (Enforcing) |
| `bin/apex-alarmkeeper.c` | Alarm-mirror source (will be compiled) |
| `bin/apex-alarmkeeper` | Compiled binary (will be at /vendor/bin) |
| `bin/apex-bridge.c` | Bridge source (will be compiled) |
| `bin/apex-bridge` | Compiled binary (will be at /vendor/bin) |
| `hidden_packages.list` | HMA blacklist |

## Status

Empty. Theory only. Nothing will be applied to the device until the
verification checklist in `docs/BUILD_PLAN.md` step 9 is ready to run.
