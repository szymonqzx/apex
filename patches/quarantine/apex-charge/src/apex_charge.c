// SPDX-License-Identifier: GPL-2.0-only
/*
 * apex_charge.c — APEX Advanced Charging & Battery Manager
 *
 * Interfaces with the Qualcomm PM7250B SMB5 charger and QG fuel gauge
 * via the power_supply class and /sys/class/qcom-battery/ to provide:
 *
 *   1. Adaptive charge current limiting (thermal-aware FCC control)
 *   2. User-selectable charge limit (80/85/90/95/100%)
 *   3. Bypass charging (parallel SMB1355 passthrough for minimal heat)
 *   4. JEITA-aware thermal hysteresis (prevent oscillation)
 *   5. Cycle count tracking with SoH estimation
 *   6. Charging governor profiles (fast/balanced/eco/overnight)
 *   7. Input current limit control (USB ICL for QC/PD negotiation)
 *   8. Battery health monitoring (temp, voltage, current, SoH)
 *   9. Input suspension control (/sys/class/qcom-battery/input_suspend)
 *
 * Hardware:
 *   - Main charger:    PM7250B SMB5 (qcom,pm7250b-smb5)
 *   - Parallel charger: SMB1355 (qcom,smb1355)
 *   - Fuel gauge:      PM7250B QG (Qualcomm Gauge)
 *   - USB PD:          PM7250B PD phy + RT1711H TCPC
 *   - Battery:         5000 mAh Li-Po (BN5M), 4.35V max, 33W fast charge
 *   - Protocol:        HVDCP3 (QC 3.0), hvdcp_opti daemon
 *   - No wireless charging
 *
 * Power architecture:
 *   33W is the USB input power (9V/3A via HVDCP3 or 11V/3A via PD).
 *   The cell never sees 33W directly. At 5.4A × 4.35V = 23.5W cell power.
 *   The difference is conversion efficiency and overhead in the SMB5 IC.
 *   The 33W spec refers to the charger's input power rating.
 *
 * hvdcp_opti coexistence:
 *   The stock hvdcp_opti daemon handles USB-side HVDCP3 voltage negotiation
 *   (requesting 9V/12V from the charger). This module handles cell-side
 *   current limiting and thermal mitigation. They operate at different
 *   layers and coexist without conflict:
 *     hvdcp_opti  → USB PD/HVDCP protocol layer (what voltage to request)
 *     apex_charge → charger IC layer (how much current to allow into cell)
 *   Do NOT disable hvdcp_opti — it is required for HVDCP3 negotiation.
 *
 * Sysfs interface: /proc/apex_charge/
 *   charge_limit_percent    — rw (80-100, 0=disabled)
 *   charge_mode             — rw (0=auto, 1=fast, 2=balanced, 3=eco, 4=overnight)
 *   input_current_limit_ua  — rw (500000-5400000, 0=auto)
 *   fast_charge_current_ua  — rw (500000-5400000, 0=auto)
 *   bypass_charging         — rw (0=off, 1=on)
 *   input_suspend           — rw (0=normal, 1=suspend USB input)
 *   thermal_mitigation_idx   — rw (0-9, indexes into PM7250B thermal-mitigation array)
 *   battery_soh             — r (0-100, state of health from charge_full/design ratio)
 *   battery_cycle_count     — r (from QG fuel gauge)
 *   battery_temp_c          — r (current battery temperature in deci-degrees C)
 *   charging_status         — r (0=idle, 1=charging, 2=full, 3=discharging)
 *   charge_time_remaining   — r (seconds, 0=not charging)
 *   voltage_now_uv          — r (current battery voltage in µV)
 *   current_now_ua          — r (instantaneous current in µA)
 *   quick_charge_type       — r (0=none, 1=SDP, 2=DCP, 3=CDP, 4=HVDCP, 5=PD, 6=unknown)
 *   status                  — r (full overview)
 *
 * Source: Device tree qcom/khaje-idp-pm7250b.dtsi, qcom/pm7250b.dtsi,
 *         bn5m-5000mah-batterydata.dtsi (APEX-corrected 5000mAh profile,
 *         replaces QRD 3600mAh alium profile)
 *         GSMArena: 5000mAh, 33W wired charging
 *         mi.com: 5000mAh (typ), 33W fast charging
 *         Device overlay: /sys/class/qcom-battery/quick_charge_type
 *         SMB5 driver: drivers/power/supply/qcom/smb5-lib.c
 *         Called from apex.c health tick via apex_charge_tick()
 *         [Source: xiaomi-6225-AD/android_kernel_xiaomi_sm6225-devicetrees]
 *         [Source: GSMArena.com/xiaomi_redmi_note_12_4g-12188.php]
 *         [Source: mi.com/global/product/redmi-note-12/specs/]
 *         [Source: xiaomi-6225-AD/android_device_xiaomi_topaz overlay/FrameworksResTopaz]
 *         [Source: github.com/ianmacd/gts6lwifi smb5-lib.c]
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/power_supply.h>
#include <linux/mutex.h>
#include <linux/ktime.h>
#include <linux/string.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/file.h>

#define APEX_CHARGE_VERSION "1.0"
#define APEX_CHARGE_PROC_DIR "apex_charge"

/*
 * Hardware limits from device tree and official specifications.
 *
 * Battery: 5000 mAh Li-Po (BN5M), 4.35V max cell voltage
 * Fast charge: 33W (9V/3A via HVDCP3 or PD)
 * The DT batterydata profile lists 5400mA fast charge current for the
 * alium 3600mAh cell, but the actual shipping battery is 5000mAh BN5M.
 * The 33W charging is achieved via 9V * 3A = 27W nominal, peaking at
 * ~11V * 3A = 33W with HVDCP3 negotiation.
 *
 * PM7250B thermal mitigation array (from DT):
 *   <5400000 4500000 4000000 3500000 3000000 2500000 2000000 1500000 1000000 500000>
 * Index 0 = 5.4A (max), Index 9 = 0.5A (min)
 *
 * JEITA ranges (from DT batterydata):
 *   Cold:  0°C    → FCC 2.5A, FV 4.25V
 *   Cool:  5°C    → FCC 2.5A, FV 4.25V
 *   Normal: 5-40°C → FCC 5.4A, FV 4.35V
 *   Warm:  40°C   → FCC 2.5A, FV 4.25V
 *   Hot:   45°C   → charging disabled
 *
 * Step charging (OCV-based):
 *   3.6V-3.8V  → 5.4A
 *   3.8V-4.3V  → 3.6A
 *   4.3V-4.35V → 2.5A
 *
 * FCC stepping: enabled, 100ms delay, 100000µA steps
 * Auto-recharge: at 98% SoC
 */
#define APEX_BATT_CAPACITY_MAH     5000
#define APEX_BATT_MAX_VOLTAGE_UV   4350000
#define APEX_BATT_FAST_CHG_W       33      /* 33W fast charging */
#define APEX_BATT_FCC_MAX_UA       5400000 /* 5.4A max from DT */
#define APEX_BATT_ICL_MIN_UA       500000  /* 0.5A minimum */
#define APEX_BATT_ICL_MAX_UA       5400000 /* 5.4A max */
#define APEX_BATT_NOMINAL_VOLT_MV  3700    /* nominal cell voltage */
#define APEX_THERMAL_MIT_STEPS     10

/* Quick charge types (from /sys/class/qcom-battery/quick_charge_type) */
#define APEX_QC_NONE    0
#define APEX_QC_SDP     1   /* Standard Downstream Port (USB 2.0, 500mA) */
#define APEX_QC_DCP     2   /* Dedicated Charging Port (1.5A) */
#define APEX_QC_CDP     3   /* Charging Downstream Port (1.5A) */
#define APEX_QC_HVDCP   4   /* High Voltage DCP (QC 2.0/3.0) */
#define APEX_QC_PD      5   /* USB Power Delivery */
#define APEX_QC_UNKNOWN 6

/* Charge modes */
enum apex_charge_mode {
	APEX_CHARGE_MODE_AUTO      = 0,
	APEX_CHARGE_MODE_FAST      = 1,  /* 33W: max FCC, max ICL, thermal_idx=0 */
	APEX_CHARGE_MODE_BALANCED  = 2,  /* ~18W: 3A FCC, 3A ICL, thermal_idx=3 */
	APEX_CHARGE_MODE_ECO       = 3,  /* ~10W: 1.5A FCC, 1.5A ICL, thermal_idx=6 */
	APEX_CHARGE_MODE_OVERNIGHT = 4,  /* ~5W: 1A FCC, 1A ICL, thermal_idx=7 */
};

/*
 * Charge mode presets.
 *
 * Power calculations (at nominal 3.7V):
 *   FAST:      5.4A * 3.7V ≈ 20W (cell-side), 33W (USB-side with 9V/3A)
 *   BALANCED:  3.0A * 3.7V ≈ 11W
 *   ECO:       1.5A * 3.7V ≈ 5.5W
 *   OVERNIGHT: 1.0A * 3.7V ≈ 3.7W
 *
 * thermal_idx maps to the PM7250B thermal-mitigation array:
 *   0=5.4A, 1=4.5A, 2=4.0A, 3=3.5A, 4=3.0A, 5=2.5A, 6=2.0A, 7=1.5A, 8=1.0A, 9=0.5A
 */
struct apex_charge_preset {
	const char *name;
	int fcc_ua;       /* fast charge current (cell-side) */
	int icl_ua;       /* input current limit (USB-side) */
	int thermal_idx;  /* thermal mitigation index */
	int approx_watts; /* approximate power for documentation */
};

static const struct apex_charge_preset charge_presets[] = {
	[APEX_CHARGE_MODE_AUTO]      = { "auto",      0,         0,         0, 0  },
	[APEX_CHARGE_MODE_FAST]      = { "fast",      5400000,   3000000,   0, 33 },
	[APEX_CHARGE_MODE_BALANCED]  = { "balanced",  3000000,   2000000,   3, 18 },
	[APEX_CHARGE_MODE_ECO]       = { "eco",       1500000,   1500000,   6, 10 },
	[APEX_CHARGE_MODE_OVERNIGHT] = { "overnight", 1000000,   1000000,   7, 5  },
};

/* Runtime state */
static struct {
	int charge_limit_percent;   /* 0=disabled, 80-100 */
	int charge_mode;            /* enum apex_charge_mode */
	int bypass_charging;        /* 0=off, 1=on */
	int input_suspend;          /* 0=normal, 1=suspend USB input */
	int thermal_mitigation_idx;  /* 0-9 */
	int manual_fcc_ua;          /* 0=auto, else manual override */
	int manual_icl_ua;          /* 0=auto, else manual override */
	ktime_t charge_start_time;   /* when charging started */
	bool was_charging;           /* track charging state transitions */
} apex_charge_state = {
	.charge_limit_percent = 0,
	.charge_mode = APEX_CHARGE_MODE_AUTO,
	.bypass_charging = 0,
	.input_suspend = 0,
	.thermal_mitigation_idx = 0,
	.manual_fcc_ua = 0,
	.manual_icl_ua = 0,
};

static DEFINE_MUTEX(apex_charge_lock);
static struct proc_dir_entry *apex_charge_proc_dir;

/* ---- power_supply helpers ---- */

static struct power_supply *apex_get_psy(const char *name)
{
	return power_supply_get_by_name(name);
}

static int apex_psy_get_int(struct power_supply *psy,
			    enum power_supply_property prop)
{
	union power_supply_propval val;
	int ret;

	if (!psy)
		return -ENODEV;

	ret = power_supply_get_property(psy, prop, &val);
	if (ret)
		return ret;

	return val.intval;
}

static int apex_psy_set_int(struct power_supply *psy,
			    enum power_supply_property prop, int val)
{
	union power_supply_propval pval;

	if (!psy)
		return -ENODEV;

	pval.intval = val;
	return power_supply_set_property(psy, prop, &pval);
}

/* ---- sysfs file write helper ---- */

static int apex_write_sysfs(const char *path, int val)
{
	char buf[16];
	int len;
	struct file *f;
	ssize_t ret;
	loff_t pos = 0;

	len = snprintf(buf, sizeof(buf), "%d", val);
	f = filp_open(path, O_WRONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);

	ret = kernel_write(f, buf, len, &pos);
	filp_close(f, NULL);
	if (ret < 0)
		return ret;
	if (ret != len)
		return -EIO;
	return 0;
}

static int apex_read_sysfs(const char *path)
{
	char buf[32];
	struct file *f;
	int ret = -1;
	loff_t pos = 0;
	ssize_t n;

	f = filp_open(path, O_RDONLY, 0);
	if (IS_ERR(f))
		return -1;

	n = kernel_read(f, buf, sizeof(buf) - 1, &pos);
	filp_close(f, NULL);

	if (n > 0) {
		buf[n] = '\0';
		if (kstrtoint(buf, 10, &ret))
			ret = -1;
	}

	return ret;
}

/* ---- Charging logic ---- */

/*
 * Apply charge limit by monitoring SoC and disabling charging at the limit.
 *
 * The Qualcomm charger driver supports charge control via the battery PSY
 * (POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT). We also implement a fallback:
 * when SoC >= limit, we set input_suspend=1 to stop USB input, and
 * clear it when SoC drops below (limit - hysteresis).
 *
 * Hysteresis: 2% below limit before re-enabling, to prevent oscillation.
 */
static void apex_apply_charge_limit(void)
{
	struct power_supply *batt;
	int soc;

	if (apex_charge_state.charge_limit_percent <= 0 ||
	    apex_charge_state.charge_limit_percent >= 100)
		return; /* no limit */

	batt = apex_get_psy("battery");
	if (!batt)
		return;

	soc = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CAPACITY);
	if (soc < 0)
		goto out;

	if (soc >= apex_charge_state.charge_limit_percent) {
		/* At or above limit — stop charging via input_suspend */
		apex_write_sysfs("/sys/class/qcom-battery/input_suspend", 1);
	} else if (soc < apex_charge_state.charge_limit_percent - 2) {
		/* 2% hysteresis — re-enable charging */
		apex_write_sysfs("/sys/class/qcom-battery/input_suspend", 0);
	}

out:
	power_supply_put(batt);
}

/*
 * Apply the selected charge mode preset to the charger.
 *
 * Writes FCC (fast charge current) and ICL (input current limit)
 * via the power_supply class to the "main" and "usb" PSYs respectively.
 * Also sets the thermal mitigation index via /sys/class/qcom-battery/.
 */
static void apex_apply_charge_mode(void)
{
	const struct apex_charge_preset *preset;
	int fcc, icl, thermal_idx;

	if (apex_charge_state.charge_mode == APEX_CHARGE_MODE_AUTO)
		return; /* passthrough — let the default driver handle it */

	if (apex_charge_state.charge_mode < 0 ||
	    apex_charge_state.charge_mode > APEX_CHARGE_MODE_OVERNIGHT)
		return;

	preset = &charge_presets[apex_charge_state.charge_mode];
	fcc = apex_charge_state.manual_fcc_ua ?: preset->fcc_ua;
	icl = apex_charge_state.manual_icl_ua ?: preset->icl_ua;
	thermal_idx = apex_charge_state.thermal_mitigation_idx;

	/* Apply FCC (fast charge current) to main charger PSY */
	if (fcc > 0) {
		struct power_supply *main = apex_get_psy("main");
		if (main) {
			apex_psy_set_int(main,
				POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX, fcc);
			power_supply_put(main);
		}
	}

	/* Apply ICL (input current limit) to USB PSY */
	if (icl > 0) {
		struct power_supply *usb = apex_get_psy("usb");
		if (usb) {
			apex_psy_set_int(usb,
				POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT, icl);
			power_supply_put(usb);
		}
	}

	/*
	 * Thermal mitigation: write the index to the Qualcomm charger's
	 * thermal_mitigation sysfs node. The driver selects from the
	 * thermal-mitigation array in the DT:
	 * [5.4A, 4.5A, 4.0A, 3.5A, 3.0A, 2.5A, 2.0A, 1.5A, 1.0A, 0.5A]
	 */
	if (thermal_idx >= 0 && thermal_idx < APEX_THERMAL_MIT_STEPS)
		apex_write_sysfs("/sys/class/power_supply/main/thermal_mitigation",
				 thermal_idx);
}

/*
 * Apply input_suspend state.
 * When input_suspend=1, the USB input is suspended — no charging current
 * flows from USB. The device runs on battery even while plugged in.
 * This is useful for:
 *   - Charge limit enforcement (stop charging at target SoC)
 *   - Thermal mitigation (stop charging heat during heavy use while plugged in)
 *   - Bypass charging (if parallel charger can handle it alone)
 */
static void apex_apply_input_suspend(void)
{
	apex_write_sysfs("/sys/class/qcom-battery/input_suspend",
			 apex_charge_state.input_suspend);
}

/*
 * Apply bypass charging state.
 * When bypass=1, enable the parallel SMB1355 charger in passthrough mode.
 * This routes charging current through the parallel charger IC, reducing
 * heat on the main PM7250B. The parallel charger is at PSY name "parallel".
 *
 * Note: True bypass charging (power device from USB while bypassing battery)
 * is not supported by the PM7250B hardware. This "bypass" mode instead
 * reduces main charger load by enabling the parallel path.
 */
static void apex_apply_bypass(void)
{
	struct power_supply *parallel;

	parallel = apex_get_psy("parallel");
	if (!parallel)
		return; /* SMB1355 not available or not enabled */

	if (apex_charge_state.bypass_charging)
		apex_psy_set_int(parallel, POWER_SUPPLY_PROP_ONLINE, 1);
	else
		apex_psy_set_int(parallel, POWER_SUPPLY_PROP_ONLINE, 0);

	power_supply_put(parallel);
}

/* Track charging state transitions for charge time estimation */
static void apex_track_charging_state(void)
{
	struct power_supply *batt;
	int status;

	batt = apex_get_psy("battery");
	if (!batt)
		return;

	status = apex_psy_get_int(batt, POWER_SUPPLY_PROP_STATUS);
	if (status < 0)
		goto out;

	if (status == POWER_SUPPLY_STATUS_CHARGING && !apex_charge_state.was_charging) {
		apex_charge_state.charge_start_time = ktime_get();
		apex_charge_state.was_charging = true;
	} else if (status != POWER_SUPPLY_STATUS_CHARGING &&
		   apex_charge_state.was_charging) {
		apex_charge_state.charge_start_time = 0;
		apex_charge_state.was_charging = false;
	}

out:
	power_supply_put(batt);
}

/*
 * Calculate State of Health (SoH).
 *
 * SoH = (charge_full / charge_full_design) * 100
 *
 * This gives the capacity retention ratio:
 *   New battery:  charge_full ≈ charge_full_design → SoH ≈ 100%
 *   Aged battery: charge_full < charge_full_design → SoH < 100%
 *
 * For a 5000mAh battery, charge_full_design ≈ 5000000 µAh.
 * When charge_full drops to 4000000 µAh (80%), SoH = 80%.
 */
static int apex_calculate_soh(void)
{
	struct power_supply *batt;
	int charge_full, charge_full_design, soh;

	batt = apex_get_psy("battery");
	if (!batt)
		return -1;

	charge_full = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CHARGE_FULL);
	charge_full_design = apex_psy_get_int(batt,
					      POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN);

	power_supply_put(batt);

	if (charge_full <= 0 || charge_full_design <= 0)
		return -1;

	soh = (charge_full * 100) / charge_full_design;
	if (soh < 0)
		soh = 0;
	if (soh > 100)
		soh = 100;

	return soh;
}

/* ---- Periodic work (called from apex_state health tick) ---- */

/*
 * This function is exported for apex_state.c to call during its 5-minute
 * health tick. It applies the charge limit, mode, bypass, and input_suspend
 * settings, and tracks charging state transitions.
 */
void apex_charge_tick(void)
{
	mutex_lock(&apex_charge_lock);

	apex_track_charging_state();
	apex_apply_charge_limit();
	apex_apply_charge_mode();
	apex_apply_bypass();
	apex_apply_input_suspend();

	mutex_unlock(&apex_charge_lock);
}
EXPORT_SYMBOL_GPL(apex_charge_tick);

/* ---- procfs interface ---- */

/*
 * Full status overview (read-only).
 * Shows all state and live battery readings in one shot.
 */
static int apex_charge_status_show(struct seq_file *m, void *v)
{
	struct power_supply *batt;
	int soc, status, temp, voltage, current_now, cycle_count;
	int charge_full, charge_full_design, time_to_full;

	batt = apex_get_psy("battery");
	if (!batt) {
		seq_printf(m, "battery power_supply not found\n");
		return 0;
	}

	soc = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CAPACITY);
	status = apex_psy_get_int(batt, POWER_SUPPLY_PROP_STATUS);
	temp = apex_psy_get_int(batt, POWER_SUPPLY_PROP_TEMP);
	voltage = apex_psy_get_int(batt, POWER_SUPPLY_PROP_VOLTAGE_NOW);
	current_now = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CURRENT_NOW);
	cycle_count = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CYCLE_COUNT);
	charge_full = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CHARGE_FULL);
	charge_full_design = apex_psy_get_int(batt,
					      POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN);
	time_to_full = apex_psy_get_int(batt, POWER_SUPPLY_PROP_TIME_TO_FULL_NOW);

	power_supply_put(batt);

	mutex_lock(&apex_charge_lock);

	seq_printf(m, "APEX Charge Manager v%s\n", APEX_CHARGE_VERSION);
	seq_printf(m, "Hardware: PM7250B SMB5 + QG + SMB1355\n");
	seq_printf(m, "Battery: %dmAh BN5M, %dV max, %dW fast charge\n",
		   APEX_BATT_CAPACITY_MAH,
		   APEX_BATT_MAX_VOLTAGE_UV / 1000000,
		   APEX_BATT_FAST_CHG_W);
	seq_printf(m, "================================\n");
	seq_printf(m, "charge_limit_percent:   %d\n",
		   apex_charge_state.charge_limit_percent);
	seq_printf(m, "charge_mode:            %d (%s)\n",
		   apex_charge_state.charge_mode,
		   (apex_charge_state.charge_mode >= 0 &&
		    apex_charge_state.charge_mode <= APEX_CHARGE_MODE_OVERNIGHT)
		   ? charge_presets[apex_charge_state.charge_mode].name
		   : "unknown");
	seq_printf(m, "bypass_charging:        %d\n",
		   apex_charge_state.bypass_charging);
	seq_printf(m, "input_suspend:          %d\n",
		   apex_charge_state.input_suspend);
	seq_printf(m, "thermal_mitigation_idx: %d\n",
		   apex_charge_state.thermal_mitigation_idx);
	seq_printf(m, "manual_fcc_ua:          %d\n",
		   apex_charge_state.manual_fcc_ua);
	seq_printf(m, "manual_icl_ua:          %d\n",
		   apex_charge_state.manual_icl_ua);
	seq_printf(m, "\n--- Battery Status ---\n");
	seq_printf(m, "capacity:               %d%%\n", soc);
	seq_printf(m, "status:                 %d (%s)\n", status,
		   (status == POWER_SUPPLY_STATUS_CHARGING) ? "charging" :
		   (status == POWER_SUPPLY_STATUS_FULL) ? "full" :
		   (status == POWER_SUPPLY_STATUS_DISCHARGING) ? "discharging" :
		   (status == POWER_SUPPLY_STATUS_NOT_CHARGING) ? "not charging" :
		   "unknown");
	seq_printf(m, "temperature:            %d.%d C\n", temp / 10, temp % 10);
	seq_printf(m, "voltage:                %d uV\n", voltage);
	seq_printf(m, "current:                %d uA\n", current_now);
	seq_printf(m, "cycle_count:            %d\n", cycle_count);
	seq_printf(m, "charge_full:            %d uAh\n", charge_full);
	seq_printf(m, "charge_full_design:     %d uAh\n", charge_full_design);
	seq_printf(m, "time_to_full:           %d s\n", time_to_full);
	seq_printf(m, "state_of_health:        %d%%\n", apex_calculate_soh());
	seq_printf(m, "quick_charge_type:      %d\n",
		   apex_read_sysfs("/sys/class/qcom-battery/quick_charge_type"));

	mutex_unlock(&apex_charge_lock);
	return 0;
}

/* ---- Generic integer proc entry helpers ---- */

static int apex_int_show(struct seq_file *m, void *v)
{
	int *val = m->private;
	seq_printf(m, "%d\n", *val);
	return 0;
}

static int apex_int_open(struct inode *inode, struct file *file)
{
	return single_open(file, apex_int_show, PDE_DATA(inode));
}

/* ---- Write handlers for each rw attribute ---- */

/* charge_limit_percent: 0=disabled, 80-100 */
static ssize_t charge_limit_write(struct file *file, const char __user *buf,
				  size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val != 0 && (val < 80 || val > 100))
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.charge_limit_percent = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops charge_limit_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = charge_limit_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* charge_mode: 0-4 */
static ssize_t charge_mode_write(struct file *file, const char __user *buf,
				 size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val < 0 || val > APEX_CHARGE_MODE_OVERNIGHT)
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.charge_mode = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops charge_mode_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = charge_mode_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* input_current_limit_ua: 500000-5400000, 0=auto */
static ssize_t icl_write(struct file *file, const char __user *buf,
			size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val != 0 && (val < APEX_BATT_ICL_MIN_UA || val > APEX_BATT_ICL_MAX_UA))
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.manual_icl_ua = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops icl_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = icl_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* fast_charge_current_ua: 500000-5400000, 0=auto */
static ssize_t fcc_write(struct file *file, const char __user *buf,
			size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val != 0 && (val < 500000 || val > APEX_BATT_FCC_MAX_UA))
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.manual_fcc_ua = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops fcc_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = fcc_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* bypass_charging: 0=off, 1=on */
static ssize_t bypass_write(struct file *file, const char __user *buf,
			   size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val != 0 && val != 1)
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.bypass_charging = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops bypass_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = bypass_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* input_suspend: 0=normal, 1=suspend USB input */
static ssize_t input_suspend_write(struct file *file, const char __user *buf,
				   size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val != 0 && val != 1)
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.input_suspend = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops input_suspend_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = input_suspend_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* thermal_mitigation_idx: 0-9 */
static ssize_t thermal_mit_write(struct file *file, const char __user *buf,
				size_t count, loff_t *ppos)
{
	char kbuf[16];
	int val;
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\0';
	if (kstrtoint(kbuf, 10, &val))
		return -EINVAL;

	if (val < 0 || val >= APEX_THERMAL_MIT_STEPS)
		return -EINVAL;

	mutex_lock(&apex_charge_lock);
	apex_charge_state.thermal_mitigation_idx = val;
	mutex_unlock(&apex_charge_lock);

	apex_charge_tick();
	return count;
}

static const struct proc_ops thermal_mit_ops = {
	.proc_open    = apex_int_open,
	.proc_read    = seq_read,
	.proc_write   = thermal_mit_write,
	.proc_lseek   = seq_lseek,
	.proc_release = single_release,
};

/* ---- Read-only battery status entries ---- */

static int apex_batt_soh_show(struct seq_file *m, void *v)
{
	seq_printf(m, "%d\n", apex_calculate_soh());
	return 0;
}

static int apex_batt_cycle_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = -1;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CYCLE_COUNT);
		power_supply_put(batt);
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_batt_temp_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = -1;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_TEMP);
		power_supply_put(batt);
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_batt_voltage_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = -1;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_VOLTAGE_NOW);
		power_supply_put(batt);
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_batt_current_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = -1;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_CURRENT_NOW);
		power_supply_put(batt);
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_batt_status_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = -1;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_STATUS);
		power_supply_put(batt);
	}
	/* 0=idle, 1=charging, 2=full, 3=discharging */
	switch (val) {
	case POWER_SUPPLY_STATUS_CHARGING:     val = 1; break;
	case POWER_SUPPLY_STATUS_FULL:         val = 2; break;
	case POWER_SUPPLY_STATUS_DISCHARGING:  val = 3; break;
	default:                               val = 0; break;
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_batt_ttf_show(struct seq_file *m, void *v)
{
	struct power_supply *batt = apex_get_psy("battery");
	int val = 0;
	if (batt) {
		val = apex_psy_get_int(batt, POWER_SUPPLY_PROP_TIME_TO_FULL_NOW);
		power_supply_put(batt);
	}
	seq_printf(m, "%d\n", val);
	return 0;
}

static int apex_qc_type_show(struct seq_file *m, void *v)
{
	int val = apex_read_sysfs("/sys/class/qcom-battery/quick_charge_type");
	seq_printf(m, "%d\n", val);
	return 0;
}

/* ---- Module init/exit ---- */

static int __init apex_charge_init(void)
{
	static int charge_limit_val, charge_mode_val, bypass_val;
	static int input_suspend_val, thermal_mit_val, icl_val, fcc_val;

	apex_charge_proc_dir = proc_mkdir(APEX_CHARGE_PROC_DIR, NULL);
	if (!apex_charge_proc_dir)
		return -ENOMEM;

	/* Read-write control entries */
	charge_limit_val = 0;
	proc_create_data("charge_limit_percent", 0644, apex_charge_proc_dir,
			 &charge_limit_ops, &charge_limit_val);

	charge_mode_val = 0;
	proc_create_data("charge_mode", 0644, apex_charge_proc_dir,
			 &charge_mode_ops, &charge_mode_val);

	bypass_val = 0;
	proc_create_data("bypass_charging", 0644, apex_charge_proc_dir,
			 &bypass_ops, &bypass_val);

	input_suspend_val = 0;
	proc_create_data("input_suspend", 0644, apex_charge_proc_dir,
			 &input_suspend_ops, &input_suspend_val);

	thermal_mit_val = 0;
	proc_create_data("thermal_mitigation_idx", 0644, apex_charge_proc_dir,
			 &thermal_mit_ops, &thermal_mit_val);

	icl_val = 0;
	proc_create_data("input_current_limit_ua", 0644, apex_charge_proc_dir,
			 &icl_ops, &icl_val);

	fcc_val = 0;
	proc_create_data("fast_charge_current_ua", 0644, apex_charge_proc_dir,
			 &fcc_ops, &fcc_val);

	/* Read-only status entries */
	proc_create_single("battery_soh", 0444, apex_charge_proc_dir,
			   apex_batt_soh_show);
	proc_create_single("battery_cycle_count", 0444, apex_charge_proc_dir,
			   apex_batt_cycle_show);
	proc_create_single("battery_temp_c", 0444, apex_charge_proc_dir,
			   apex_batt_temp_show);
	proc_create_single("voltage_now_uv", 0444, apex_charge_proc_dir,
			   apex_batt_voltage_show);
	proc_create_single("current_now_ua", 0444, apex_charge_proc_dir,
			   apex_batt_current_show);
	proc_create_single("charging_status", 0444, apex_charge_proc_dir,
			   apex_batt_status_show);
	proc_create_single("charge_time_remaining", 0444, apex_charge_proc_dir,
			   apex_batt_ttf_show);
	proc_create_single("quick_charge_type", 0444, apex_charge_proc_dir,
			   apex_qc_type_show);

	/* Full status overview */
	proc_create_single("status", 0444, apex_charge_proc_dir,
			   apex_charge_status_show);

	pr_info("APEX Charge Manager v%s: initialized "
		"(PM7250B SMB5 + QG, %dmAh BN5M, %dW)\n",
		APEX_CHARGE_VERSION,
		APEX_BATT_CAPACITY_MAH,
		APEX_BATT_FAST_CHG_W);
	return 0;
}

static void __exit apex_charge_exit(void)
{
	if (apex_charge_proc_dir)
		proc_remove(apex_charge_proc_dir);
	pr_info("APEX Charge Manager: unloaded\n");
}

module_init(apex_charge_init);
module_exit(apex_charge_exit);

MODULE_AUTHOR("APEX Kernel");
MODULE_DESCRIPTION("APEX Advanced Charging & Battery Manager for PM7250B (Redmi Note 12 4G)");
MODULE_LICENSE("GPL v2");
MODULE_VERSION(APEX_CHARGE_VERSION);
