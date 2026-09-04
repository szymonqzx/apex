# Device-specific kernel backports

Fixes from ChicKernel (chickendrop89) and community for the SM6225-AD
(Redmi Note 12 4G, codename topaz/tapas) on Linux 5.15.

## Patches

| File | Fix | Source |
| :--- | :--- | :--- |
| `sm5602-fuelgauge.patch` | SM5602 fuel gauge probe failure after 5.15.149 merge | ChicKernel |
| `dwc3-msm-core.patch` | DWC3 USB controller not working after 5.15.149 merge | ChicKernel |
| `mi-thermald-wrong-core.patch` | mi_thermald shutting down wrong CPU core during thermal events | ChicKernel |
| `usb-tether-panic.patch` | Kernel panic during USB tethering disconnect | community |
| `kmsg-spam-suppress.patch` | Suppress vendor module kmsg spam | community |

## Apply order

```bash
./apply.sh /path/to/kernel
```

Patches apply in the order listed above. All are idempotent.
