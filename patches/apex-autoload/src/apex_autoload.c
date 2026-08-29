// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/usb/core/apex_autoload.c
 *
 * apex VID:PID -> module autoloader (DESIGN.md §5 "Pentest driver matrix").
 *
 * When a known adapter is plugged in, usb_new_device() calls
 * apex_usb_autoload() and we request_module() the matching driver so the
 * module loads only when hardware is actually attached (zero idle drain).
 *
 * Modules marked [out-of-tree] are built from the nether-kernels patch set;
 * the rest are in-tree and simply need the config symbols enabled.
 */

#include <linux/kmod.h>
#include <linux/module.h>
#include <linux/usb.h>

struct apex_usb_id {
	__u16 vid;
	__u16 pid;		/* 0xffff matches any PID for the VID */
	const char *module;
};

static const struct apex_usb_id apex_usb_table[] = {
	/* Wi-Fi (monitor mode) */
	{ 0x0bda, 0x8812, "8812au" },	/* ALFA AWUS036ACH  [out-of-tree] */
	{ 0x0bda, 0x881a, "8812au" },	/* AWUS036ACH v2    [out-of-tree] */
	{ 0x0bda, 0x8814, "8814au" },	/* AWUS1900         [out-of-tree] */
	{ 0x0bda, 0xb812, "88x2bu" },	/* AWUS036ACU       [out-of-tree] */
	{ 0x0bda, 0x8179, "8188eu" },	/* AWUS036NEH       [out-of-tree] */
	{ 0x0bda, 0x8178, "8188eu" },	/* RTL8188EUS fallback [out-of-tree] */
	{ 0x0cf3, 0x9271, "ath9k_htc" },	/* TP-Link TL-WN722N v1 */
	{ 0x0cf3, 0x7015, "ath9k_htc" },	/* AR9271 clone */
	{ 0x0db0, 0x6877, "carl9170" },	/* Netgear WNDA3100 */
	{ 0x0bda, 0x8187, "rtl8187" },	/* Netgear WG111 */
	{ 0x148f, 0x7610, "mt7610u" },	/* AWUS036ACM       [out-of-tree] */
	{ 0x148f, 0x7612, "mt7612u" },	/* AWUS036CAH       [out-of-tree] */
	/* SDR */
	{ 0x0bda, 0x2832, "dvb_usb_rtl28xxu" },	/* RTL-SDR v3 */
	{ 0x0bda, 0x2838, "dvb_usb_rtl28xxu" },	/* RTL-SDR v4 */
	{ 0x1d50, 0x6089, "hackrf" },	/* HackRF One */
	{ 0x1d50, 0x60a1, "airspy" },	/* Airspy R2/Mini */
	{ 0x1d50, 0x60a6, "airspy" },	/* Airspy HF+ */
	{ 0x04bb, 0x0a03, "msi2500" },	/* MSI001/MSI2500 SDR */
	/* CAN */
	{ 0x1d50, 0x606f, "gs_usb" },	/* CANable / gs_usb */
	{ 0x0c72, 0x0012, "peak_usb" },	/* PEAK PCAN-USB */
	{ 0x0c72, 0x0013, "peak_usb" },	/* PEAK PCAN-USB Pro */
	{ 0x0683, 0x0002, "ems_usb" },	/* EMS CPC-USB */
	{ 0x1cdc, 0x0014, "ucan" },	/* UCAN */
	/* USB-UART / SPI / JTAG bridges */
	{ 0x1a86, 0x7523, "ch341" },	/* CH341 */
	{ 0x10c4, 0xea60, "cp210x" },	/* CP210x */
	{ 0x0403, 0x6001, "ftdi_sio" },	/* FTDI FT232 */
	{ 0x067b, 0x2303, "pl2303" },	/* Prolific PL2303 */
	/* IR */
	{ 0x04d8, 0xfd08, "ir_toy" },	/* IR Toy */
};

/* Called from drivers/usb/core/hub.c usb_new_device() in process context.
 * No interface lock is held — request_module() is safe to call here as it
 * may sleep while the module loader thread handles the actual load. */
void apex_usb_autoload(struct usb_device *udev)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(apex_usb_table); i++) {
		const struct apex_usb_id *id = &apex_usb_table[i];

		if (id->vid != le16_to_cpu(udev->descriptor.idVendor))
			continue;
		if (id->pid != 0xffff &&
		    id->pid != le16_to_cpu(udev->descriptor.idProduct))
			continue;

		/* Only fire for the top-level adapter, not its interfaces. */
		if (udev->parent)
			return;

		request_module("%s", id->module);
		return;
	}
}
EXPORT_SYMBOL_GPL(apex_usb_autoload);
