# Touch Processing Pipeline — Research Notes

## Background

Sultan Kernel added a "twoshay" touchscreen processing pipeline for Pixel
devices that improved touch quality and reduced power. This document
researches what's possible for the SM6225-AD (Redmi Note 12 4G).

## Sultan's twoshay Pipeline

twoshay is a custom touchscreen processing pipeline that:
- Implements palm rejection (large contact area detection)
- Edge touch suppression (ignore touches near screen edges during gaming)
- Power reduction (reduce touch scan rate when screen is idle)
- Touch latency reduction (bypass userspace processing, handle in kernel)

It is deeply tied to the Pixel's specific touchscreen driver (Goodix/Focaltech
via SPI bus) and not portable to other devices without significant adaptation.

## SM6225-AD Touchscreen

The Redmi Note 12 4G uses either:
- **Focaltech FT3652** (most common variant) — I2C interface
- **Goodix GT9886** (some batches) — I2C interface

Both are I2C-based touch controllers, not SPI like Pixel devices.

### Driver Location in CAF bengal-5.15

The touch driver is typically at:
- `drivers/input/touchscreen/focaltech_ft3652.c` (or similar)
- `drivers/input/touchscreen/goodix_gt9886.c`

In the CAF tree, it may be in:
- `drivers/input/touchscreen/xiaomi/` (vendor-specific)

### What Can Be Done

1. **Palm rejection in kernel**: Read the contact area (ABS_MT_TOUCH_MAJOR)
   from the touch events. If contact area exceeds a threshold (e.g., 15mm
   diameter), suppress the event. This prevents accidental palm touches
   during gaming.

2. **Edge suppression**: Define an edge zone (e.g., 10px from each edge).
   During gaming mode, suppress touch events that start in the edge zone.
   Configurable via sysfs.

3. **Scan rate control**: The Focaltech/Goodix controllers support
   configurable scan rates via I2C commands. During screen-off or idle,
   reduce the scan rate from 120Hz to 60Hz to save power. During gaming,
   increase to 240Hz if supported.

4. **Touch boost integration**: APEX already has input boost in the
   governor. The touch pipeline could also signal the governor to boost
   CPU frequency on first touch event, reducing touch-to-frame latency.

### Implementation Approach

```
patches/apex-touch/
├── apply.sh              — copy source, patch Kconfig/Makefile
├── src/
│   └── apex_touch.c      — touch processing module
└── README.md
```

The module would:
1. Register an input handler (not a full driver — sits on top of existing
   touch driver events)
2. Filter events based on palm/edge rules
3. Expose sysfs tunables:
   - `/sys/class/apex_touch/palm_reject` (0/1)
   - `/sys/class/apex_touch/edge_suppress` (0/1)
   - `/sys/class/apex_touch/edge_width` (pixels)
   - `/sys/class/apex_touch/scan_rate_idle` (Hz)
   - `/sys/class/apex_touch/scan_rate_gaming` (Hz)
4. Integrate with apex gaming mode (enable edge suppression + high scan rate)

### Risks

- Touch driver is device-specific. Need to verify exact driver and I2C
  commands for scan rate control on the actual device.
- Palm rejection thresholds need tuning with real usage.
- Edge suppression could interfere with games that use edge gestures.
- Must be tested on the actual device — cannot be verified off-device.

### Status

**Not implemented.** Requires device-specific research:
1. Identify exact touch controller (Focaltech vs Goodix)
2. Read existing driver source in kernel tree
3. Determine I2C commands for scan rate control
4. Build and test on device

This is the highest-effort item in the synthesis and should only be
attempted after all P0-P2 items are deployed and stable.
