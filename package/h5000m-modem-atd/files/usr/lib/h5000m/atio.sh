#!/bin/sh
# AT serial I/O library for the FM350-GL. Sourced, not executed.
#
# Design notes that are load-bearing:
#   * busybox provides no stty, so this depends on coreutils-stty.
#   * The port is opened with clocal so open() cannot block waiting for carrier -
#     a cellular modem's AT port never asserts DCD.
#   * Every reader ignores the command echo, because ATE0 is best-effort: a port
#     that was left in ATE1 by another tool would otherwise desynchronise us.
#   * Locks are keyed on the stable USB topology path (e.g. 2-1) plus the interface
#     number, never on the ttyUSB name, which renumbers across re-enumeration.

H5000M_LOCKDIR=/var/lock
H5000M_MODEM_STATE=/var/run/h5000m-modem.state

at_log() { logger -t h5000m-modem -p daemon.info "$*"; }
at_warn() { logger -t h5000m-modem -p daemon.warn "$*"; }

# at_lockfile <usbpath> <ifnum> -> path of the lock guarding that physical port
at_lockfile() {
	printf '%s/h5000m-at-%s-if%s.lock' "$H5000M_LOCKDIR" "$1" "$2"
}

# at_port_setup <devnode> - put the port in raw mode. Idempotent.
at_port_setup() {
	[ -c "$1" ] || return 1
	stty -F "$1" raw clocal -echo -echoe -echok -echoctl -echonl \
		min 0 time 2 2>/dev/null
}

# at_exec <devnode> <command> [timeout_seconds]
# Writes the response body (without the final OK) to stdout.
# Returns 0 = OK, 2 = ERROR/+CME/+CMS, 3 = timeout, 1 = could not open.
#
# The exchange runs inside a timeout-wrapped subshell rather than on the caller's own
# file descriptors, and that is not stylistic. Measured on this unit: writing to a port
# that never acknowledges (any of the six non-AT ttyUSB nodes) makes close() block for
# ~30s draining the untransmitted byte, regardless of how short the read timeout is -
# open and read are both instant, so the cost is entirely in close. Left unbounded that
# turns one stray command into a half-minute stall of whatever holds the AT lock.
# Killing the subshell releases the descriptor and caps the damage at timeout+2s.
at_exec() {
	_ap_dev="$1"
	_ap_cmd="$2"
	_ap_tmo="${3:-5}"

	at_port_setup "$_ap_dev" || return 1

	_ap_raw=$(timeout $(( _ap_tmo + 2 )) sh -c '
		_cr=$(printf "\r")
		exec 3<>"$1" 2>/dev/null || exit 1
		printf "%s\r" "$2" >&3
		_end=$(( $(date +%s) + $3 ))
		while [ "$(date +%s)" -le "$_end" ]; do
			read -r -t 1 _l <&3 || continue
			_l=${_l%"$_cr"}
			[ -z "$_l" ] && continue
			printf "%s\n" "$_l"
			case "$_l" in
				OK|ERROR|"+CME ERROR:"*|"+CMS ERROR:"*|"NO CARRIER") break ;;
			esac
		done
	' _ "$_ap_dev" "$_ap_cmd" "$_ap_tmo" 2>/dev/null)

	_ap_out=""
	_ap_rc=3
	# Reparse in the parent: the subshell may be killed mid-flight, so its exit status
	# is not trustworthy - the transcript is.
	_ap_oldifs="$IFS"
	IFS='
'
	for _ap_line in $_ap_raw; do
		[ -z "$_ap_line" ] && continue
		[ "$_ap_line" = "$_ap_cmd" ] && continue
		case "$_ap_line" in
			OK)
				_ap_rc=0
				;;
			ERROR|"+CME ERROR:"*|"+CMS ERROR:"*|"NO CARRIER")
				_ap_out="${_ap_out}${_ap_line}
"
				_ap_rc=2
				;;
			*)
				_ap_out="${_ap_out}${_ap_line}
"
				;;
		esac
	done
	IFS="$_ap_oldifs"

	printf '%s' "$_ap_out"
	return "$_ap_rc"
}

# at_probe <devnode> - is this an AT command port (vs NMEA/DIAG/silent)?
# Returns 0 only when the port answers bare AT with OK *and* ATI looks like a modem.
#
# The bare-AT timeout is deliberately 1s: a live AT port answers in milliseconds, while
# a dead one burns the entire timeout doing nothing. Measured on this unit, dropping it
# from 2s (and dropping a pointless ATE0 that ran before the port was known good) took
# a full discovery sweep from 55s to a few seconds. ATE0 is issued once, after
# selection, not per candidate.
at_probe() {
	_pr_dev="$1"
	_pr_out="/tmp/.h5000m-probe-$(basename "$_pr_dev")"
	rm -f "$_pr_out"

	# Run the probe detached and judge it by whether output appeared, not by waiting
	# for the process to finish. A dead port's close() blocks ~30s and - measured -
	# SIGTERM does NOT interrupt it, so `timeout` cannot rescue us here. The probe
	# child is simply left to unwind on its own while discovery moves on; it exits
	# by itself and holds no lock.
	( at_exec "$_pr_dev" 'ATI' 2 >"$_pr_out" 2>/dev/null ) &

	_pr_end=$(( $(date +%s) + 4 ))
	while [ "$(date +%s)" -lt "$_pr_end" ]; do
		[ -s "$_pr_out" ] && break
		sleep 1
	done

	[ -s "$_pr_out" ] || { rm -f "$_pr_out"; return 1; }
	_pr_id=$(cat "$_pr_out")
	rm -f "$_pr_out"

	# NMEA sentences and binary DIAG traffic must never be mistaken for AT.
	case "$_pr_id" in
		'$G'*|'$P'*) return 1 ;;
	esac
	return 0
}

# at_locked <lockfile> <wait_seconds> <devnode> <command> [timeout]
# The single entry point every consumer must use.
#
# HARDWARE REALITY (verified on this unit, firmware 81600.0000.00.29.21.24): the FM350
# exposes exactly ONE AT port. All seven ff/00/00 interfaces bind to option and produce
# ttyUSB0..6, but only interface 6 (ttyUSB3) answers AT; the other six are silent both
# to commands and passively, with or without DTR asserted.
#
# So the originally planned two-tier scheme - one port held exclusively by the dialer
# for its lifetime, a second leased to everyone else - is not implementable here. The
# discipline instead is: NOBODY holds the port across transactions. Every AT exchange
# takes the lock, runs, and releases. The dialer is a peer, not an owner. That costs us
# unsolicited-result-code latency (a URC arriving while another holder has the port is
# missed), which is why dialer state is poll-authoritative and URCs are opportunistic.
#
# NOTE: busybox flock supports only -s/-x/-u/-n. There is no -w, so a bounded wait has
# to be built from -n plus a retry loop; using -w silently turned every acquisition into
# a usage error that read as "AT port busy".
at_flock_wait() {
	_fw_end=$(( $(date +%s) + ${1:-10} ))
	until flock -n -x 9 2>/dev/null; do
		[ "$(date +%s)" -lt "$_fw_end" ] || return 1
		sleep 1
	done
	return 0
}

at_locked() {
	_al_lock="$1"; _al_wait="$2"; shift 2
	mkdir -p "$H5000M_LOCKDIR"
	(
		at_flock_wait "$_al_wait" || exit 4
		at_exec "$@"
	) 9>"$_al_lock"
}

# at_state_load - export USBPATH / AT_A / AT_B / AT_A_IF / AT_B_IF / NETDEV
at_state_load() {
	[ -r "$H5000M_MODEM_STATE" ] || return 1
	# shellcheck disable=SC1090
	. "$H5000M_MODEM_STATE"
	[ -n "$MODEM_USBPATH" ]
}
