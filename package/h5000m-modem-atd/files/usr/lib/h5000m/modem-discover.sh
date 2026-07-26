#!/bin/sh
# FM350-GL discovery: sysfs -> AT ports + data netdev. Sourced, not executed.
#
# Nothing here may hard-code a ttyUSB name or a netdev name. The vendor firmware's
# ttyUSB0..6 / eth2 layout is a *prior*, not a contract: interface numbering is stable
# (it is fixed by the USB descriptor) but Linux device names are not.

MODEM_VID=0e8d
MODEM_PID=7127

# Interface numbers, best AT candidate first.
#
# Upstream option.c matches this modem with an interface filter of ff/00/00 and
#   .driver_info = NCTRL(2) | NCTRL(3) | NCTRL(4)
# NCTRL means "do not send modem control lines on this interface", which upstream
# uses to mark the non-AT (diag/log) ports. So If#6..9 - the ones *without* NCTRL -
# are the likeliest AT ports, and indeed the vendor firmware used ttyUSB3 == If#6 as
# its dialer port. If#3 is listed next because the vendor's docs also treated
# ttyUSB1 == If#3 as a usable AT port. If#5 (ff/42/01) is ADB and is never a
# candidate; If#0/1 are the RNDIS pair.
MODEM_AT_CANDIDATES="6 3 7 8 9 4 2"

# modem_find_usbdev -> sysfs path of the modem, e.g. /sys/bus/usb/devices/2-1
modem_find_usbdev() {
	for _fd_d in /sys/bus/usb/devices/*; do
		[ -r "$_fd_d/idVendor" ] || continue
		[ "$(cat "$_fd_d/idVendor")" = "$MODEM_VID" ] || continue
		[ "$(cat "$_fd_d/idProduct")" = "$MODEM_PID" ] || continue
		printf '%s' "$_fd_d"
		return 0
	done
	return 1
}

# modem_tty_for_if <usbdev> <ifnum> -> /dev/ttyUSBn for that interface, if bound
modem_tty_for_if() {
	_tf_base="$1"
	# The kernel names interface directories with the unpadded number (2-1:1.6),
	# even though bInterfaceNumber itself is zero-padded ("06").
	_tf_iface="${_tf_base}:1.$2"
	[ -d "$_tf_iface" ] || return 1
	for _tf_n in "$_tf_iface"/tty/ttyUSB* "$_tf_iface"/ttyUSB*; do
		[ -e "$_tf_n" ] || continue
		printf '/dev/%s' "$(basename "$_tf_n")"
		return 0
	done
	return 1
}

# modem_find_netdev <usbdev> -> the RNDIS/cdc_ether data interface name
modem_find_netdev() {
	for _fn_i in "$1":*; do
		[ -d "$_fn_i/net" ] || continue
		for _fn_n in "$_fn_i"/net/*; do
			[ -e "$_fn_n" ] || continue
			basename "$_fn_n"
			return 0
		done
	done
	return 1
}

# modem_discover - probe candidates and write $H5000M_MODEM_STATE.
# Port A (exclusive, dialer-owned) is the first candidate that answers AT;
# port B (leased: status polling, lpac, humans) is the second. A wedge on one
# must not be able to stall the other, which is the whole point of the split.
modem_discover() {
	_md_base=$(modem_find_usbdev) || {
		at_warn "no FM350 (${MODEM_VID}:${MODEM_PID}) on the USB bus"
		return 1
	}
	_md_usbpath=$(basename "$_md_base")

	# Probing stops at the first working port unless MODEM_DEEP_SCAN=1. Continuing to
	# hunt for a second AT port is expensive precisely because the other ports are dead:
	# each one costs a ~30s blocked close (see at_exec), so a full sweep took ~36s on
	# this unit and found nothing. The prior puts the real port first, so the common
	# path now writes to exactly one device.
	_md_a=""; _md_a_if=""
	_md_b=""; _md_b_if=""
	for _md_if in $MODEM_AT_CANDIDATES; do
		_md_dev=$(modem_tty_for_if "$_md_base" "$_md_if") || continue
		at_probe "$_md_dev" || continue
		if [ -z "$_md_a" ]; then
			_md_a="$_md_dev"; _md_a_if="$_md_if"
			[ "${MODEM_DEEP_SCAN:-0}" = 1 ] || break
		else
			_md_b="$_md_dev"; _md_b_if="$_md_if"
			break
		fi
	done

	[ -n "$_md_a" ] || { at_warn "no AT port responded on $_md_usbpath"; return 1; }

	# Single-port operation is the EXPECTED case on this hardware, not a degradation:
	# only interface 6 answers AT (see the at_locked comment in atio.sh). The scan still
	# looks for a second port because other firmware revisions may expose one, and
	# finding it would let the dialer stop contending - but nothing may depend on it.
	_md_single=0
	if [ -z "$_md_b" ]; then
		_md_b="$_md_a"; _md_b_if="$_md_a_if"; _md_single=1
	fi

	# ATE0 once, on the port we actually selected. Command echo would otherwise have to
	# be filtered on every exchange; at_exec filters it anyway, but belt and braces.
	at_exec "$_md_a" 'ATE0' 2 >/dev/null 2>&1

	_md_net=$(modem_find_netdev "$_md_base") || _md_net=""

	mkdir -p "$(dirname "$H5000M_MODEM_STATE")"
	cat >"$H5000M_MODEM_STATE" <<EOF
MODEM_USBPATH='$_md_usbpath'
MODEM_AT_A='$_md_a'
MODEM_AT_A_IF='$_md_a_if'
MODEM_AT_B='$_md_b'
MODEM_AT_B_IF='$_md_b_if'
MODEM_SINGLE_PORT='$_md_single'
MODEM_NETDEV='$_md_net'
EOF

	ln -sf "$_md_a" /dev/modem-at0
	ln -sf "$_md_b" /dev/modem-at1

	at_log "modem $_md_usbpath: AT-A=$_md_a (if$_md_a_if) AT-B=$_md_b (if$_md_b_if) net=${_md_net:-none}"
	return 0
}

# modem_discover_locked - serialise concurrent hotplug events
modem_discover_locked() {
	mkdir -p "$H5000M_LOCKDIR"
	flock -x 9 || return 1
	modem_discover
} 9>"$H5000M_LOCKDIR/h5000m-modem-discover.lock"
