# AnyKernel3 zip

Layout for the flashable kernel zip. **No zip is built yet.**

## Plan

```
apex-kernel-1.0.0-anykernel3.zip
├── anykernel.sh              # install hooks
├── zImage                    # kernel image (will be built in step 4)
├── dtb                       # matches stock DTB
├── modules/                  # all .ko files (will be built in step 3)
└── install/                  # post-install hooks
```

## Status

Empty. The zImage and module builds require the kernel clone in step 3, which
has not happened.
