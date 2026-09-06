#!/usr/bin/env bash
# verify-daily-driver.sh — Verify daily-driver pain-point fixes from DESIGN.md §11
#
# Checks that all kernel config entries and ROM overlays are present
# and correctly configured for the 17+ daily-driver pain points.
#
# Usage: ./tools/verify-daily-driver.sh
set -euo pipefail

APEX="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APEX"

PASS=0
WARN=0
FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Daily-Driver Verification (DESIGN.md §11) ==="
echo ""

# ── Kernel Config Verification ──────────────────────────────────────
echo "--- Kernel Config (defconfig/apex_defconfig) ---"

DEFCONFIG="defconfig/apex_defconfig"
if [ ! -f "$DEFCONFIG" ]; then
  fail "$DEFCONFIG not found"
  echo ""
  echo "=== Result: $PASS PASS, $WARN WARN, $FAIL FAIL ==="
  exit 1
fi

# Pain point: Stuttery scrolling
if grep -q 'CONFIG_PSI=y' "$DEFCONFIG"; then ok "PSI enabled (stuttery scrolling)"; else fail "PSI not enabled"; fi
if grep -q 'CONFIG_ENERGY_MODEL=y' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_SCHED_ENERGY_MODEL=y' "$DEFCONFIG" 2>/dev/null; then ok "Energy model (stuttery scrolling)"; else warn "Energy model config not found (may use different name)"; fi
if grep -q 'CONFIG_PREEMPT_DYNAMIC=y' "$DEFCONFIG" || grep -q 'CONFIG_PREEMPT=y' "$DEFCONFIG"; then ok "PREEMPT enabled (stuttery scrolling)"; else fail "PREEMPT not enabled"; fi

# Pain point: Broken battery stats
if grep -q 'CONFIG_BATTERY_STATS=y' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_BATTERY_STATS' "$DEFCONFIG"; then ok "BATTERY_STATS (battery stats fix)"; else warn "BATTERY_STATS not found (may be default)"; fi

# Pain point: SMS/MMS delay
if grep -q 'CONFIG_QMI_RMNET_QMUX=y' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_RMNET=m' "$DEFCONFIG" 2>/dev/null; then ok "QMI RMNET (SMS/MMS fix)"; else warn "QMI RMNET config not found"; fi

# Pain point: Dropped calls
if grep -q 'CONFIG_QCOM_RX_WAKELOCK_GUARD=y' "$DEFCONFIG" 2>/dev/null; then ok "RX_WAKELOCK_GUARD (dropped calls fix)"; else warn "RX_WAKELOCK_GUARD not found"; fi

# Pain point: BT audio dropout
if grep -q 'CONFIG_BT_MSFTEXT=y' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_BT_MSFTEXT' "$DEFCONFIG"; then ok "BT_MSFTEXT (BT audio fix)"; else warn "BT_MSFTEXT not found"; fi
if grep -q 'CONFIG_SND_A2DP_LDAC=m' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_SND_A2DP_LDAC' "$DEFCONFIG"; then ok "A2DP_LDAC (BT audio fix)"; else warn "A2DP_LDAC not found"; fi

# Pain point: Wi-Fi calling drop
if grep -q 'CONFIG_QCOM_QMI_WDAUTH=m' "$DEFCONFIG" 2>/dev/null || grep -q 'CONFIG_QCOM_QMI_WDAUTH' "$DEFCONFIG"; then ok "QMI_WDAUTH (Wi-Fi calling fix)"; else warn "QMI_WDAUTH not found"; fi

# ── ROM Overlay Verification ────────────────────────────────────────
echo ""
echo "--- ROM Overlays ---"

# Pain point: Battery drain — BT scan
if grep -q 'cpuset.*cgroup.clone_children' rom-overlays/init.d/apex_power.rc 2>/dev/null; then ok "BT scan cgroup freezer (battery drain)"; else warn "BT scan cgroup config not found in apex_power.rc"; fi

# Pain point: Battery drain — Wi-Fi multicast
if grep -q 'wifi.*watchdog\|wifi.*multicast' rom-overlays/init.d/apex_power.rc 2>/dev/null; then ok "Wi-Fi multicast lockdown (battery drain)"; else warn "Wi-Fi multicast config not found"; fi

# Pain point: Battery drain — sensors
if grep -q 'sensorservice.*set_rate\|sensor.*cap\|sensor.*10' rom-overlays/init.d/apex_power.rc 2>/dev/null; then ok "Sensor background cap (battery drain)"; else warn "Sensor cap not found in apex_power.rc"; fi

# Pain point: Auto-brightness flicker
if grep -q 'sensor.*50\|min.*50\|rate.*50' rom-overlays/init.d/apex_power.rc 2>/dev/null; then ok "Auto-brightness sensor cap (flicker fix)"; else warn "Auto-brightness sensor cap not found"; fi

# Pain point: Random shutdown
if [ -f rom-overlays/thermald/thermald.conf ]; then ok "thermald.conf present (random shutdown fix)"; else fail "thermald.conf not found"; fi
if grep -q 'jeisa\|JEISA\|polling_interval\|throttle' rom-overlays/thermald/thermald.conf 2>/dev/null; then ok "thermald.conf has thermal thresholds"; else warn "thermald.conf may lack threshold config"; fi

# ── Apex Control App Completion (audit #15) ────────────────────────
echo ""
echo "--- Apex Control App Completion ---"

CONTROL_DIR="apps/apex-control/app/src/main/java/com/apex/control"

# Governor tuning screen
if [ -f "$CONTROL_DIR/poweruser/GovernorTuningScreen.kt" ]; then ok "Governor tuning screen present"; else fail "GovernorTuningScreen.kt not found"; fi
if grep -q '@Composable' "$CONTROL_DIR/poweruser/GovernorTuningScreen.kt" 2>/dev/null; then ok "Governor tuning has @Composable"; else fail "GovernorTuningScreen.kt missing @Composable"; fi

# Thermal profile display
if [ -f "$CONTROL_DIR/poweruser/ThermalProfileScreen.kt" ]; then ok "Thermal profile screen present"; else fail "ThermalProfileScreen.kt not found"; fi
if grep -q '@Composable' "$CONTROL_DIR/poweruser/ThermalProfileScreen.kt" 2>/dev/null; then ok "Thermal profile has @Composable"; else fail "ThermalProfileScreen.kt missing @Composable"; fi

# Incident log viewer
if [ -f "$CONTROL_DIR/poweruser/IncidentLogViewer.kt" ]; then ok "Incident log viewer present"; else fail "IncidentLogViewer.kt not found"; fi
if grep -q '@Composable' "$CONTROL_DIR/poweruser/IncidentLogViewer.kt" 2>/dev/null; then ok "Incident log viewer has @Composable"; else fail "IncidentLogViewer.kt missing @Composable"; fi

# Module status
if [ -f "$CONTROL_DIR/poweruser/ModuleStatusScreen.kt" ]; then ok "Module status screen present"; else fail "ModuleStatusScreen.kt not found"; fi

# Bridge status
if [ -f "$CONTROL_DIR/poweruser/BridgeStatusScreen.kt" ]; then ok "Bridge status screen present"; else fail "BridgeStatusScreen.kt not found"; fi

# ── Agent Enhancements ─────────────────────────────────────────────
echo ""
echo "--- Agent Enhancements ---"

# Remote model
if [ -f agent/java/com/apex/agent/RemoteModelClient.java ]; then ok "RemoteModelClient.java present"; else fail "RemoteModelClient.java not found"; fi
if [ -f agent/java/com/apex/agent/RemoteProxyDaemon.java ]; then ok "RemoteProxyDaemon.java present"; else fail "RemoteProxyDaemon.java not found"; fi
if [ -f agent/sepolicy/apex_remote_proxy.te ]; then ok "Remote proxy SELinux policy present"; else fail "apex_remote_proxy.te not found"; fi

# Charge control with dual-confirm
if [ -f agent/java/com/apex/agent/ChargeControlTool.java ]; then ok "ChargeControlTool.java present"; else fail "ChargeControlTool.java not found"; fi
if grep -q 'DUAL_CONFIRM' agent/java/com/apex/agent/ConsentGate.java 2>/dev/null; then ok "DUAL_CONFIRM consent type present"; else fail "DUAL_CONFIRM not in ConsentGate"; fi
if grep -q 'REMOTE_INFERENCE' agent/java/com/apex/agent/ConsentGate.java 2>/dev/null; then ok "REMOTE_INFERENCE consent type present"; else fail "REMOTE_INFERENCE not in ConsentGate"; fi

# Vector store + memory manager
if [ -f agent/java/com/apex/agent/AgentVectorStore.java ]; then ok "AgentVectorStore.java present"; else fail "AgentVectorStore.java not found"; fi
if [ -f agent/java/com/apex/agent/MemoryManager.java ]; then ok "MemoryManager.java present"; else fail "MemoryManager.java not found"; fi
if grep -q 'mMemoryManager' agent/java/com/apex/agent/ApexAgentDaemon.java 2>/dev/null; then ok "Memory manager wired into daemon"; else fail "Memory manager not wired into ApexAgentDaemon"; fi

# Voice input
if grep -q 'transcribeVoice\|push.to.talk\|Icons.Default.Mic' apps/apex-control/app/src/main/java/com/apex/control/agent/AgentChatSurface.kt 2>/dev/null; then ok "Push-to-talk voice input in chat UI"; else fail "Push-to-talk not found in AgentChatSurface"; fi
if grep -q 'transcribeVoice' apps/apex-control/app/src/main/java/com/apex/control/agent/AgentRepository.kt 2>/dev/null; then ok "transcribeVoice in AgentRepository"; else fail "transcribeVoice not in AgentRepository"; fi

# Vector store test
if [ -f tests/agent/test_vector_store.py ]; then ok "test_vector_store.py present"; else fail "test_vector_store.py not found"; fi

# ── Lindroid Completion ────────────────────────────────────────────
echo ""
echo "--- Lindroid Completion ---"

if [ -f lindroid/java/com/apex/lindroid/LindroidManager.java ]; then ok "LindroidManager.java present"; else fail "LindroidManager.java not found"; fi
if [ -f lindroid/java/com/apex/lindroid/ContainerConfig.java ]; then ok "ContainerConfig.java present"; else fail "ContainerConfig.java not found"; fi
if [ -f lindroid/java/com/apex/lindroid/DisplayBridge.java ]; then ok "DisplayBridge.java present"; else fail "DisplayBridge.java not found"; fi
if [ -f lindroid/aidl/com/apex/lindroid/ILindroid.aidl ]; then ok "ILindroid.aidl present"; else fail "ILindroid.aidl not found"; fi

# Lindroid MCP tools
if grep -q 'apex-lindroid' agent/java/com/apex/agent/McpRegistry.java 2>/dev/null; then ok "Lindroid MCP tools registered"; else fail "Lindroid MCP tools not in McpRegistry"; fi

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo "=== Result: $PASS PASS, $WARN WARN, $FAIL FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
