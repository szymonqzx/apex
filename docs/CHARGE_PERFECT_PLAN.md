# APEX Charge Manager — Perfect System Plan

## Status: 6 issues identified, 8 work items to fix them all

---

## Issue 1: No SELinux policy for /proc/apex_charge/

**Problem**: SELinux is Enforcing. `init` writes to `/proc/apex_charge/*` via
`apex_power.rc` on boot. Without an allow rule, every write is silently denied.
The kernel module creates the procfs entries, but userspace can't reach them.

**Root cause**: The only `.te` file (`apex_chown.te`) covers the chroot domain.
No policy exists for `init` → `/proc/apex_charge/` writes.

**Fix**: Create `rom-overlays/selinux/apex_charge.te` with allow rules for
`init` and `system_app` domains to read/write `/proc/apex_charge/*`. Ship it
alongside `apex_chown.te` via the same KSU `sepolicy.rule` mechanism.

**Policy content**:
```te
# Allow init to write charge manager procfs entries
allow init apex_charge_proc:file { read write open getattr setattr };
allow init apex_charge_proc:dir { search read };

# Allow system_app (Settings, charging apps) to read status
allow system_app apex_charge_proc:file { read open getattr };
allow system_app apex_charge_proc:dir { search read };

# Allow vendor.qti.hardware.charger@1.0-service (if present)
allow hal_charger_default apex_charge_proc:file { read open getattr };
allow hal_charger_default apex_charge_proc:dir { search read };

# Type definition
type apex_charge_proc, file_type, fs_type;
```

**Files touched**:
- NEW: `rom-overlays/selinux/apex_charge.te`
- PATCH: `tools/compile-selinux.sh` — compile both .te files
- PATCH: `anykernel3/anykernel.sh` — install `apex_charge.te` alongside `apex_chown.te`
- PATCH: `tools/apex-dirty-modify.sh` — install `apex_charge.te` in SELinux step
- PATCH: `tools/package-anykernel3.sh` — copy `apex_charge.te` into zip

---

## Issue 2: thermald.conf is not consumed by any code

**Problem**: `thermald.conf` is copied to `/system/etc/thermald.conf` but
nothing reads it. The charging-specific thermal zones (charger-skin-therm,
charging-policy, JEITA thresholds) are documentation-only.

**Root cause**: APEX has no userspace thermald daemon. All thermal policy lives
in the kernel (`apex_thermal_uclamp.c`, `apex.c` health tick). The `thermald.conf`
was designed as a config file for a daemon that was never written.

**Decision**: The kernel module (`apex_charge.c`) already has its own internal
JEITA logic and thermal mitigation via the PM7250B's 10-step ICC table. The
`thermald.conf` charging zones are redundant with the kernel's internal logic.

**Fix**: Make `thermald.conf` explicitly documentation/reference-only. Add a
header comment stating that charging thermal policy is enforced in-kernel by
`apex_charge.c` and this file is for human reference only. Remove the pretense
of a parser. The kernel module's `apex_charge_tick()` (called from `apex.c`
health tick) already does:
  - Reads battery temp from power_supply
  - Applies JEITA warm/cold FCC reduction
  - Steps thermal_mitigation_idx based on charger skin temp
  - Respects charge_limit_percent by suspending input at threshold

**Files touched**:
- PATCH: `rom-overlays/thermald/thermald.conf` — add header: "Reference only —
  charging thermal policy is enforced in-kernel by apex_charge.c"
- PATCH: `README.md` — clarify thermald.conf is reference documentation

---

## Issue 3: dirty-modify.sh doesn't install charging-specific files

**Problem**: `dirty-modify.sh` installs `thermald.conf`, `apex_power.rc`,
`apex_profiles.rc`, and `apex_chown.te`, but doesn't:
  - Install `apex_charge.te` SELinux policy
  - Set up `/proc/apex_charge` permissions (handled by SELinux, not chmod)
  - Disable `hvdcp_opti` if it conflicts
  - Report charging overlays in the install manifest

**Fix**: Add a charging-specific step to `dirty-modify.sh`:
  - Step 6b: Install `apex_charge.te` SELinux policy
  - Step 5b: Disable `hvdcp_opti` (see Issue 6 for rationale)
  - Update install manifest to include `apex_charge_te: true`
  - Update summary output to show charging overlays

**Files touched**:
- PATCH: `tools/apex-dirty-modify.sh` — add charging step, update manifest

---

## Issue 4: Battery data DTSI mismatch (3600mAh vs 5000mAh)

**Problem**: The device tree ships `qg-batterydata-alium-3600mah.dtsi` with:
  - `fastchg-current-ma = <5400>` (5.4A)
  - `max-voltage-uv = <4350000>` (4.35V)
  - `design_cap` not in the DTSI (it's in the tapas DTS: 3000 mAh)

The actual battery is 5000 mAh BN5M. The Qualcomm QG fuel gauge uses the DT
batterydata profile for SoC estimation. With wrong design capacity:
  - SoC% will be wrong (thinks battery is 3600 mAh)
  - Charge full design will be wrong
  - Cycle count estimation will be wrong

**Root cause**: The xiaomi-6225-AD device tree repos are community/WIP and
ship a QRD (Qualcomm Reference Design) battery profile, not the commercial
device profile. Xiaomi's closed-source kernel likely has a different DTSI.

**Fix**: Create a corrected batterydata DTSI as a device-backport patch:
  - NEW: `patches/device-backports/bn5m-5000mah-batterydata.dtsi` — correct
    battery profile for the 5000 mAh BN5M cell
  - NEW: `patches/device-backports/batterydata-5000mah.patch` — patch the
    device tree to include the corrected DTSI instead of the 3600mAh one

**Corrected battery data values**:
  - `qcom,max-voltage-uv = <4350000>` (same — 4.35V is correct for BN5M)
  - `qcom,fg-cc-cv-threshold-uv = <4340000>` (same)
  - `qcom,fastchg-current-ma = <5400>` (same — 5.4A at 4.35V ≈ 23.5W via HVDCP3;
    33W is achieved via PD negotiation at higher voltage, not raw cell current)
  - `qcom,design-capacity-mah = <5000>` (NEW — correct design capacity)
  - JEITA FCC: same ranges (temperature-based, not capacity-based)
  - JEITA FV: same ranges (temperature-based, not capacity-based)
  - Step charging: same voltage steps (voltage-based, not capacity-based)
  - `qcom,batt-id-kohm`: keep existing (battery ID resistor is hardware)
  - `qcom,battery-beta`: keep existing (NTC thermistor beta value is hardware)
  - `qcom,battery-therm-kohm`: keep existing (NTC resistance is hardware)

**Key insight**: Most of the batterydata values are hardware-physical (NTC
thermistor, battery ID resistor, max voltage, JEITA temp ranges) and don't
change with capacity. The only value that MUST change is `design-capacity-mah`.
The QG driver uses this for SoC estimation and cycle count.

**How 33W works**: 33W is the charger input power, not cell power. At 5.4A
cell current × 4.35V = 23.5W cell power. The 33W comes from USB input at
~9V/3A (HVDCP3) or ~11V/3A (PD), with conversion efficiency losses in the
SMB5 charger IC. The cell never sees 33W — it sees 5.4A × 4.35V max.

**Files touched**:
- NEW: `patches/device-backports/bn5m-5000mah-batterydata.dtsi`
- NEW: `patches/device-backports/batterydata-5000mah.patch`
- PATCH: `patches/device-backports/apply.sh` — apply the batterydata patch
- PATCH: `patches/apex-charge/src/apex_charge.c` — add comment explaining
  the 33W vs 5.4A relationship

---

## Issue 5: Dead Kconfig symbols (CONFIG_APEX_CHARGE_LIMIT_*)

**Problem**: Profile configs define:
  - `CONFIG_APEX_CHARGE_LIMIT_BATTERY=80`
  - `CONFIG_APEX_CHARGE_LIMIT_BALANCED=90`
  - `CONFIG_APEX_CHARGE_LIMIT_PERFORMANCE=100`

No Kconfig or C code reads these. The actual charge limits are set at runtime
via `apex_profiles.rc` writing to `/proc/apex_charge/charge_limit_percent`.

**Fix**: Remove the dead symbols from profile configs. The runtime sysfs
approach is correct — compile-time charge limits would be inflexible and
redundant with the rc file.

**Files touched**:
- PATCH: `defconfig/profile-battery.config` — remove CONFIG_APEX_CHARGE_LIMIT_BATTERY
- PATCH: `defconfig/profile-balanced.config` — remove CONFIG_APEX_CHARGE_LIMIT_BALANCED
- PATCH: `defconfig/profile-performance.config` — remove CONFIG_APEX_CHARGE_LIMIT_PERFORMANCE

---

## Issue 6: hvdcp_opti daemon conflict potential

**Problem**: Stock ROM runs `hvdcp_opti` (`/system/vendor/bin/hvdcp_opti`)
for HVDCP3 optimization. `init.target.rc` starts it when charger=running.
The APEX Charge Manager's thermal mitigation writes to
`/sys/class/power_supply/main/thermal_mitigation`, which controls the SMB5
charger's ICC (input current control). `hvdcp_opti` may also try to negotiate
HVDCP3 voltage steps independently.

**Analysis**: `hvdcp_opti` handles USB-side HVDCP3 protocol negotiation
(requesting 9V/12V from the charger). The APEX Charge Manager handles
cell-side current limiting and thermal mitigation. These operate at different
layers:
  - `hvdcp_opti`: USB PD/HVDCP protocol layer (what voltage to request from charger)
  - `apex_charge`: charger IC layer (how much current to allow into the cell)

They should coexist without conflict. `hvdcp_opti` negotiates the input power,
and `apex_charge` limits how much of that power reaches the battery.

**Decision**: Keep `hvdcp_opti` running. Do NOT disable it. Add a comment in
`apex_charge.c` documenting the layering. The APEX Charge Manager operates
below `hvdcp_opti` in the stack.

**Files touched**:
- PATCH: `patches/apex-charge/src/apex_charge.c` — add architecture comment
  about hvdcp_opti coexistence
- PATCH: `rom-overlays/init.d/apex_power.rc` — do NOT stop hvdcp_opti

---

## Issue 7 (discovered during audit): apex_charge.c has no health tick integration

**Problem**: `apex_charge.c` exports `apex_charge_tick()` but `apex.c` (the
APEX state manager) never calls it. The health tick in `apex.c` runs every
10 seconds and handles CPU/GPU/thermal/battery monitoring, but doesn't call
the charge manager's tick function. This means the charge manager's internal
JEITA logic and thermal mitigation never runs automatically — only when a
user manually writes to `/proc/apex_charge/thermal_mitigation_idx`.

**Fix**: Add `extern void apex_charge_tick(void)` declaration and call it from
the health tick in `apex.c`. Guard with `#ifdef CONFIG_APEX_CHARGE`.

**Files touched**:
- PATCH: `patches/apex-state/src/apex.c` — call `apex_charge_tick()` from
  health tick
- PATCH: `patches/apex-charge/src/apex_charge.c` — ensure `apex_charge_tick()`
  is properly exported with `EXPORT_SYMBOL_GPL`

---

## Issue 8 (discovered during audit): No charging.config exclusion in check-configs.py

**Problem**: `check-configs.py` excludes `profile-*.config` but NOT
`charging.config`. The glob `*.config` picks up `charging.config` and merges
it with all other fragments. This currently works (no conflicts), but it's
fragile — if any other fragment defines `CONFIG_POWER_SUPPLY` or
`CONFIG_THERMAL` differently, it would report a false conflict.

**Fix**: No change needed. `charging.config` should be merged into every build
(unlike profile configs which are mutually exclusive). The current behavior is
correct. Document this in `charging.config` header.

---

## Implementation Order

1. **Issue 1** — SELinux policy (`apex_charge.te`) — without this, nothing works
2. **Issue 7** — Health tick integration — without this, auto JEITA/thermal doesn't run
3. **Issue 4** — Battery data DTSI — without this, fuel gauge reports wrong capacity
4. **Issue 5** — Remove dead Kconfig symbols — cleanup
5. **Issue 6** — hvdcp_opti coexistence comment — documentation
6. **Issue 2** — thermald.conf documentation clarification — documentation
7. **Issue 3** — dirty-modify.sh charging step — tooling
8. **Issue 8** — No change needed — documentation only

After all 8: run full verification (expect 70+ checks), update README, update verify.sh.

---

## Architecture After Fixes

```
┌─────────────────────────────────────────────────────┐
│ Userspace                                           │
│                                                     │
│  Android Settings / charging apps                   │
│    ↓ reads /proc/apex_charge/status                 │
│                                                     │
│  apex_power.rc (init)                               │
│    ↓ writes /proc/apex_charge/{charge_mode, ...}    │
│    ↓ (allowed by apex_charge.te SELinux policy)     │
│                                                     │
│  apex_profiles.rc (init)                            │
│    ↓ writes /proc/apex_charge/charge_mode per profile│
│                                                     │
│  hvdcp_opti (vendor)                                │
│    ↓ negotiates HVDCP3 voltage (9V/12V from charger)│
│    ↓ operates at USB protocol layer                 │
│    ↓ does NOT conflict with apex_charge             │
├─────────────────────────────────────────────────────┤
│ Kernel                                              │
│                                                     │
│  apex_charge.c (APEX Charge Manager)                │
│    /proc/apex_charge/* — sysfs control + status     │
│    ↓ reads/writes power_supply class                │
│    ↓ JEITA-aware thermal mitigation (10-step ICC)   │
│    ↓ charge limit (suspend input at threshold)      │
│    ↓ bypass charging (disable SMB5, pass to SMB1355)│
│    ↓ SoH estimation (charge_full / design_cap)      │
│    ↓ called from apex.c health tick every 10s       │
│                                                     │
│  apex.c (APEX State Manager)                        │
│    health_tick() → calls apex_charge_tick()         │
│                                                     │
│  Qualcomm SMB5 driver (drivers/power/supply/qcom/)  │
│    PM7250B charger IC — hardware level              │
│    Reads batterydata DTSI (corrected 5000mAh)       │
│    HVDCP3, step charging, SW JEITA, FCC stepping    │
│    Exposes /sys/class/power_supply/{battery,main,usb}│
│    Exposes /sys/class/qcom-battery/*                │
│                                                     │
│  Qualcomm QG fuel gauge (drivers/power/supply/qcom/)│
│    PM7250B QG — SoC estimation                      │
│    Uses corrected design_cap=5000mAh                │
│    Reports SoC, voltage, current, temp, cycle count │
│                                                     │
│  SMB1355 parallel charger (I2C)                     │
│    Activated in bypass mode                         │
│    Direct charge path bypassing SMB5                │
├─────────────────────────────────────────────────────┤
│ Hardware                                            │
│                                                     │
│  PM7250B SMB5 — main charger (QC3.0/HVDCP3)         │
│  SMB1355 — parallel charger                         │
│  PM7250B QG — fuel gauge                            │
│  RT1711H — USB-C TCPC                               │
│  BN5M — 5000mAh Li-Po, 4.35V, 33W fast charge       │
└─────────────────────────────────────────────────────┘
```

## Data Flow

```
Charger plugged in
  → hvdcp_opti negotiates HVDCP3 (9V/3A = 27W input)
  → SMB5 driver receives power, starts charging
  → QG fuel gauge reports SoC/temp/voltage to power_supply class
  → apex.c health tick (every 10s) calls apex_charge_tick()
  → apex_charge_tick():
      1. Read battery temp from power_supply
      2. Apply JEITA: if temp > 40°C → reduce FCC to 2.5A
                      if temp > 45°C → stop charging
                      if temp < 5°C  → reduce FCC to 2.5A, FV to 4.25V
      3. Check charge_limit_percent: if SoC >= limit → input_suspend=1
      4. Check charger skin temp: if > 55°C → thermal_mitigation_idx=4
                                   if > 65°C → thermal_mitigation_idx=7
      5. Apply mode preset: if charge_mode=eco → FCC=1.5A, ICL=1.5A
      6. Write to /sys/class/power_supply/main/thermal_mitigation
      7. Write to /sys/class/power_supply/main/input_suspend (if needed)
      8. Update /proc/apex_charge/status with current state
  → SMB5 driver applies thermal_mitigation_idx to hardware ICC
  → Battery charges at controlled rate
```
