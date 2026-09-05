# APEX ROM — Deferred Items and Future Modules

Items explicitly deferred from the initial APEX ROM Agent-Spine build (T1-T8).
Each item will be implemented as a separate module extending the APEX agent spine.

## Deferred from CEO Plan (2026-09-05)

### Agent-Driven Charge Control (E3) — SKIPPED
- **Status**: Deferred — agent stays read-only over hardware for now
- **Rationale**: Safety-first approach. The agent can READ charge status via
  the `apex-charge` MCP tool, but cannot WRITE charge parameters. Charge
  control remains via Apex Control UI (direct sysfs writes).
- **Future**: When enabled, will require a new `apex-charge-write` MCP tool
  with elevated consent (dual-confirmation: on-screen + physical button).

### ALOS/DSU Dual-Boot — OUT OF SCOPE
- **Status**: Out of scope (user decision)
- **Rationale**: The Arch Linux ARM chroot with apex-bridge is the current
  Linux story. ALOS/DSU dual-boot is a future upgrade path.

## Future Modules (from Design Doc)

### APEX WM — Freeform Window Manager
- **Priority**: P3
- **Description**: VXWM-style freeform window manager for Android, enabling
  multi-window on phone form factor. Exposes `apex-wm` MCP tools to the agent.
- **Depends on**: Agent spine (T1-T8) complete
- **Design**: Freeform overlays first (no SurfaceFlinger changes), then
  integrated tiling mode.

### Desktop Mode (scrcpy)
- **Priority**: P3
- **Description**: Desktop experience via scrcpy (USB-C is USB 2.0 only —
  no wired display output). Agent can launch desktop mode via MCP tool.
- **Depends on**: APEX WM
- **Constraint**: scrcpy/Miracast only — USB-C display is not wired.

### Lindroid
- **Priority**: P4
- **Description**: Full Linux desktop environment running alongside Android,
  replacing the current chroot+bridge approach. Upgrade path from the
  existing Arch Linux ARM chroot.
- **Depends on**: APEX WM, Desktop Mode
- **Note**: The current chroot/bridge/apex-bridge.c is the interim solution.

## Future Agent Capabilities

### GPU Inference — NOT POSSIBLE
- **Status**: Hardware limitation — Adreno 610 is OpenGL ES 3.2 only,
  no Vulkan 1.1, very limited compute. Agent inference is CPU-only (llama.cpp
  on Cortex-A73/A53). This will not change.

### USB-C Display — NOT POSSIBLE
- **Status**: Hardware limitation — USB-C is wired USB 2.0 only.
  No wired display output, ever. scrcpy/Miracast only if display output needed.

### Remote Model (OmniRoute-compatible)
- **Status**: Planned — design includes optional remote model support
  with explicit per-request opt-in. The ModelManager has a `REMOTE` tier
  placeholder. Implementation requires:
  1. HTTP client in apexagentd (OkHttp or HttpURLConnection)
  2. Per-request consent for remote inference (data leaves device)
  3. OmniRoute-compatible API endpoint configuration
  4. Fallback to local model on network failure

## Scope Boundaries (from CEO Plan)

The following are explicitly OUT OF SCOPE for the APEX ROM:

- **No WM** (deferred to future module)
- **No desktop** (deferred to future module)
- **No Lindroid** (deferred to future module)
- **No ALOS dual-boot** (out of scope)
- **No GPU inference** (hardware limitation)
- **No USB-C display** (hardware limitation)
- **Agent is READ-ONLY over hardware** (no write tools in MVP)
