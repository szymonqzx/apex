# Rebranding LineageOS — the source-level endgame

Purpose: eliminate every `lineage` string from the ROM so Native Detector's
string-based checks (files, sepolicy, vintf, services, packages, props) find
nothing to flag. This is the "de-lineage build" endgame — the only fix for the
native servicemanager enumeration residual (`docs/NATIVE_BINDER_HIDING.md`).

This is a rebuild of the ROM, not a flashable patch. Run it on a machine with
the LineageOS 23.2 source synced (tapas device tree).

## 0. Preconditions

- Synced tree: `repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 && repo sync`
- Kernel: the APEX kernel (the hiding stack stays — rebranding kills the
  *strings*; boot state / attestation / root hiding still need SUSFS + modules).
- Time budget: full ROM build (many hours). Everything here is a scriptable
  one-time cost.

## 1. String sweep — `tools/rebrand-lineage.sh`

```bash
tools/rebrand-lineage.sh <source-root> myntra --dry-run   # review
tools/rebrand-lineage.sh <source-root> myntra --apply     # commit
```

What it does and why it is safe (vs naive sed):
- text extensions only — no binary corruption
- ordered, longest-first (`org.lineageos` → `com.myntraos` before bare `lineage`)
- `vendor/lineage`, `lineage-sdk`, `device/lineage` directories are content-
  swept but NOT renamed (renaming them breaks `lunch`)
- `.git/.repo/out/prebuilts` excluded

## 2. What the script does NOT cover (do these manually)

1. **Signing keys** — the build signs with `vendor/lineage` keys (or the device
   tree's). Packages signed with known LineageOS release keys are themselves a
   detection vector. Generate your own:
   ```bash
   # keys in device/<vendor>/<device>/keys/ or a vendor/<brand> overlay;
   # set in device.mk: PRODUCT_DEFAULT_DEV_CERTIFICATE, PRODUCT_OTA_PUBLIC_KEYS
   subject='/C=XX/ST=X/O=<brand>/CN=<brand> Platform'
   for k in platform shared media networkkey releasekey; do
     subject -newkey rsa:4096 -nodes -keyout ${k}.pem -x509 -days 10000 -subj "$subject" -out ${k}.x509.pem
   done
   ```
   (adjust for the build system's expected key format — this is the pattern,
   not the exact invocation).
2. **Leftover props** — grep the built product for `ro.lineage.*`,
   `lineage.*` properties; replace in the product/vendor makefiles.
3. **Settings authorities** — `lineagesettings` provider authority; rename to
   match the new brand or keep internal (only the *strings* matter for ND).
4. **VINTF/HALs** — `vendor.lineage.health.*` requires manifest + HAL .rc
   renames (covered in `NATIVE_BINDER_HIDING.md` §1).
5. **`AssetManager.LINEAGE_APK_PATH`** — the constant lives in the LineageOS
   `frameworks_base` patch; the sweep covers the string, but verify the field
   no longer exists: after build, `adb shell` → reflect
   `android.content.res.AssetManager` and confirm no `LINEAGE_APK_PATH`.
6. **`org.lineageos.platform-res.apk`** — after the sweep + build it is gone
   from `/system/framework`; the runtime stack (sus_path + lineage-hider wipe)
   stays as defense-in-depth.

## 3. Build + verify

```bash
source build/envsetup.sh
lunch ${brand}_tapas-userdebug   # or -user for cleanest narrative
make bacon -j$(nproc)
```

Post-build verification, in order:
1. `grep -ri lineage <out>/target/product/tapas --include=*.prop --include=*.xml -l` → empty
2. On device: `service list | grep -i lineage` → empty (native residual closed)
3. Reflect `AssetManager.LINEAGE_APK_PATH` → NoSuchFieldException
4. `getprop | grep -i lineage` → empty
5. Run ND (pinned) → rows 6–14 must all be gone; rows 2–4 still need the
   SUSFS/attestation stack (boot state is bootloader, not ROM).

## 4. Maintenance

- ND updates: new checks may target new strings — add them to the sweep.
- Keep the runtime stack (SUSFS + lineage-hider) even after rebranding: it
  covers the boot-state + root vectors that rebranding cannot.
- The `com.apex.*` internal packages and the APEX kernel remain separate
  from the rebrand — they are already hidden via denylist/HMA.
