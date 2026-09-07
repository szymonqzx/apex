# Native Binder Hiding — closing the servicemanager enumeration residual

Detection rows **LineageOS (10)/(11)/(12)** enumerate binder services
(`lineageglobalactions`, `lineagehardware`, `lineagehealth`, `lineagelivedisplay`,
`lineagetrust`, `vendor.lineage.health.*`, …). The Java path is closed by
`lineage-hider` (ServiceManager.listServices/getService/checkService/
waitForService/getDeclaredInstances hooks). What remains is *native*
enumeration — the app calling libbinder directly, or exec'ing `/system/bin/service`
— which no Java hook can reach.

Three countermeasures, in order of robustness:

## 1. Rename-at-build (RECOMMENDED — kills every vector at once)

The service names are registered by lineage-sdk code compiled into the ROM.
Renaming them at build time erases the strings from `service list` output,
native `listServices()`, Java listing, and dumpsys — no hooks, no in-process
footprint, nothing for an anti-Xposed scanner to find.

Where the names live (LineageOS 23.2 / lineage-sdk):

| Service | Registered by | Source to patch |
|---|---|---|
| `lineageglobalactions` | `LineageGlobalActionsService` | `lineage-sdk` SystemServer registration |
| `lineagehardware` | `LineageHardwareService` | same |
| `lineagehealth` | `LineageHealthService` | same |
| `lineagelivedisplay` | `LineageLiveDisplayService` | same |
| `lineagetrust` | `LineageTrustService` | same |
| `profile` (lineageos.app.IProfileManager) | `LineageProfileManagerService` | same |
| `vendor.lineage.health.*` | vendor HALs | device/vendor manifest + HAL .rc |

Patch surface (LineageOS source tree):
1. `lineage-sdk/lineage/res/res/values/config.xml` / `LineageContextConstants.java`
   — the `*_SERVICE` constants (`LINEAGE_GLOBAL_ACTIONS_SERVICE`, …).
2. `lineage-sdk` `LineageSystemServer.java` — registration names.
3. `frameworks/base` references to those constants.
4. Device/vendor `manifest.xml` + `compatibility_matrix.device.xml` + vendor
   `.rc` files for `vendor.lineage.health.*`.

Rename convention: `lineage*` → `vendor.<brand>.*` or a neutral prefix (e.g.
`apex*`). Keep the interface AIDL names (`lineageos.app.*`) renamed to match —
the *strings* are what ND greps, so interface + service + HAL names all matter.

Cost: ROM rebuild; zero runtime risk. This is the correct fix for the native
residual and doubles as the first step of the de-lineage endgame
(`tools/rebrand-lineage.sh` covers the string sweep).

## 2. Native hook module (runtime alternative — Zygisk + Dobby)

If a runtime-only fix is required (no ROM rebuild), a per-app Zygisk module can
hook libbinder in the target process.

Targets (Android 16 — AIDL service manager is primary):

| Symbol / entry | What it covers |
|---|---|
| `android.os.IServiceManager` BpServiceManager `transact` (AIDL stub) | all service queries incl. `listServices` |
| legacy `android::IServiceManager::checkService` / `getService` / `listServices` (libbinder C++) | non-AIDL callers |
| exec of `/system/bin/service` | the `service list` binary path |

Design:
- Zygisk module scoped to the target app; native lib loaded in
  `postAppSpecialize`; hook with Dobby (inline).
- Filter on the service-name String16 argument / transaction code for
  `listServices` (interface token + reply parcel filtering is the robust
  approach — return the parcel with lineage entries removed).
- Alternatively PLT-hook `android::String16` comparisons — brittle, avoid.
- Rebuild requirement: Android NDK (arm64), Zygisk API headers, Dobby. The
  module must be re-validated per ND release (parcel layout changes).

Why this is last: it is the most effort, the most fragile (Parcel format,
symbol changes per Android version), and it leaves an injection footprint that
anti-Xposed scanners can find. Prefer (1).

## 3. Why kernel-side filtering is not an option

servicemanager is a userspace process; binder transactions pass through the
kernel's binder driver, which has no per-service filtering. SUSFS cannot
selectively hide binder services (its SUS_PATH/SUS_MOUNT operate on the VFS,
not the binder domain). This is a hard boundary — service visibility is
decided in userspace, so the fix must be userspace (1) or (2).

## Verification

After (1) or (2): run `service list | grep -i lineage` from an adb shell
(user context) and from the target app — both must return nothing. ND rows
(10)/(11)/(12) must clear on the pinned version.
