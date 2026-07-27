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

# shellcheck disable=SC1091
. /usr/lib/h5000m/log.sh
# Component `modem_atd` (the UCI key), tag `h5000m-modem` (what appears in syslog). The tag
# is deliberately the one this layer has always used: changing it would silently break
# every existing `logread -e h5000m-modem`, and a logging change that invalidates people's
# log filters has made things worse, not better.
h5000m_log_init modem_atd h5000m-modem

# Kept as thin wrappers so every existing caller keeps working while the levels become
# real. Note these take a plain string, not a format - callers pass pre-built messages.
at_log()  { log_info  '%s' "$*"; }
at_warn() { log_warn  '%s' "$*"; }

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

	# _AT_SKIP_SETUP is set only by at_locked_batch, which does the stty once before its
	# loop while holding the lock. Deliberately NOT a general "remember the last device"
	# memo: this modem re-enumerates on its own, and a cached "already configured" that
	# outlived a re-enumeration would silently talk to an unconfigured port.
	[ -n "${_AT_SKIP_SETUP:-}" ] || at_port_setup "$_ap_dev" || return 1

	_ap_raw=$(timeout $(( _ap_tmo + 2 )) sh -c '
		_cr=$(printf "\r")
		exec 3<>"$1" 2>/dev/null || exit 1
		printf "%s\r" "$2" >&3
		# Countdown, not a wall-clock deadline: this board has no RTC and sysntpd steps the
		# clock during early boot, which would make `date +%s` overshoot a deadline computed
		# moments earlier and abandon a perfectly good exchange as a timeout. Each iteration
		# costs at most the 1s read timeout, and the outer timeout(1) is the hard bound.
		# Only a read that TIMED OUT costs a second, so only that decrements. Charging every
		# iteration would truncate long replies - AT+CLAC alone returns 37 lines, which would
		# be cut off well before OK. An endlessly chatty port is bounded by the outer timeout.
		_left=$3
		while [ "$_left" -gt 0 ]; do
			if ! read -r -t 1 _l <&3; then
				_left=$(( _left - 1 ))
				continue
			fi
			_l=${_l%"$_cr"}
			[ -z "$_l" ] && continue
			printf "%s\n" "$_l"
			case "$_l" in
				OK|ERROR|"+CME ERROR:"*|"+CMS ERROR:"*|"NO CARRIER") break ;;
			esac
		done
	' _ "$_ap_dev" "$_ap_cmd" "$_ap_tmo" 2>/dev/null)

	# The AT wire, at trace level only. This is the view that did not exist while debugging
	# the activation model, when the modem's actual replies had to be inferred from
	# behaviour. Redaction is applied inside the logger, not here, so every trace site
	# gets it automatically rather than each remembering to.
	log_trace '> %s' "$_ap_cmd"

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

	# Collapse the transcript onto one line: syslog records per line, and a multi-line
	# response would otherwise be interleaved with whatever else is logging.
	#
	# GUARDED, because the collapse costs a subshell and a `tr` - three forks - and
	# without the guard they were paid on EVERY AT command at the default level only to
	# throw the result away. The dialer polls every 30s and the web UI will poll every few
	# seconds, so this is the hottest line in the stack.
	log_want trace && log_trace '< [rc=%s] %s' "$_ap_rc" "$(printf '%s' "$_ap_out" | tr '\n' '|')"

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

	# Countdown rather than a wall-clock deadline. Discovery runs at boot - precisely when
	# sysntpd steps the clock on this RTC-less board - and a step mid-probe would abandon
	# the wait instantly, marking a live AT port dead and picking the wrong one or none.
	_pr_left=4
	while [ "$_pr_left" -gt 0 ]; do
		[ -s "$_pr_out" ] && break
		_pr_left=$(( _pr_left - 1 ))
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
# --- priority ---------------------------------------------------------------------
# Every consumer contends for the SINGLE AT port, and until now they contended as equals:
# whoever called flock at the right moment won. That is fine for a handful of CLI calls and
# wrong the moment a web page starts polling, because it puts UI cosmetics in direct
# competition with keeping the bearer alive.
#
# Consumers declare AT_PRIO. Higher wins:
#   30  fm350-dialer      bearer health outranks everything
#   20  h5000m-sms, h5000m-esim   user-initiated, must complete
#   10  atq (default)     interactive human
#    1  LuCI status poll  cosmetic; must never delay the above
#
# ⚠️ This is APPROXIMATE priority, not a queue. flock has no ordering and cannot be given
# one without a daemon that owns the port permanently. All a waiter can do is decline to
# race when it sees something more important also waiting. That is enough for the case that
# matters - a 3s UI poll must not starve a dialer trying to restore the link - and it is
# deliberately not described as a guarantee.
: "${AT_PRIO:=10}"

# Entries are "<pid> <prio>". A dead pid's entry is ignored and reaped on the next rewrite,
# so a consumer killed mid-wait cannot block anyone forever.
#
# NOTE on $$: inside at_locked's subshell this is the PARENT shell's pid, not the
# subshell's. That is fine and in fact wanted - it is stable for the lifetime of the
# consumer process, which is exactly the identity we want to register and reap.
_at_prio_add() { printf '%s %s\n' "$$" "${AT_PRIO:-10}" >> "$1" 2>/dev/null; }

# One walk, two consumers. Emits the live entries that are not ours, so the reaper and the
# max-priority query share a single definition of "live and not mine" instead of drifting.
_at_prio_live() {
	[ -f "$1" ] || return 0
	while read -r _pl_pid _pl_val; do
		[ "$_pl_pid" = "$$" ] && continue
		[ -d "/proc/$_pl_pid" ] || continue
		case "$_pl_val" in ''|*[!0-9]*) continue ;; esac
		printf '%s %s\n' "$_pl_pid" "$_pl_val"
	done < "$1" 2>/dev/null
}

_at_prio_del() {
	[ -f "$1" ] || return 0
	_pd_tmp="$1.$$"
	_at_prio_live "$1" > "$_pd_tmp" 2>/dev/null
	mv -f "$_pd_tmp" "$1" 2>/dev/null || rm -f "$_pd_tmp" 2>/dev/null
	return 0
}

# Assigns _AT_PRIO_MAX rather than printing it: a printing helper has to be called through
# $( ), which is a fork, and this runs once per second per waiter.
_at_prio_scan() {
	_AT_PRIO_MAX=0
	[ -f "$1" ] || return 0
	while read -r _ps_pid _ps_val; do
		[ "$_ps_pid" = "$$" ] && continue
		[ -d "/proc/$_ps_pid" ] || continue
		case "$_ps_val" in ''|*[!0-9]*) continue ;; esac
		[ "$_ps_val" -gt "$_AT_PRIO_MAX" ] && _AT_PRIO_MAX="$_ps_val"
	done < "$1" 2>/dev/null
	return 0
}

# at_flock_wait <wait_seconds> <lockfile>
#
# The lockfile is REQUIRED. It was briefly optional "so an old caller keeps working", but
# every caller lives in this repo and was updated in the same change - so the only thing
# optionality bought was a silent-degradation mode where a caller that forgot the argument
# got no priority participation and no warning.
#
# The loop sleeps exactly one second, so the deadline is a fork-free countdown rather than
# a `date +%s` per iteration.
at_flock_wait() {
	_fw_left="${1:-10}"
	_fw_pf="$2.want"
	_at_prio_add "$_fw_pf"
	_fw_rc=1

	while :; do
		_at_prio_scan "$_fw_pf"
		if [ "$_AT_PRIO_MAX" -le "${AT_PRIO:-10}" ] && flock -n -x 9 2>/dev/null; then
			_fw_rc=0
			break
		fi
		[ "$_fw_left" -gt 0 ] || break
		_fw_left=$(( _fw_left - 1 ))
		sleep 1
	done

	_at_prio_del "$_fw_pf"
	return "$_fw_rc"
}

# at_locked <lockfile> <wait> <devnode> <command> [timeout]
# at_locked_batch <lockfile> <wait> <devnode> <timeout> <command>...
#
# Both hold the port for their whole run. Batch exists because the single AT port is the
# scarcest resource on this device: a status page needs half a dozen queries, and run one
# at a time they cost six acquisitions, six chances to interleave with the dialer and six
# chances to be told the port is busy. Batched they cost one.
#
# Callers must not open-code the mkdir + `( ) 9>lock` dance - that convention living in
# more than one place is how the two implementations drift apart.
at_locked() {
	_al_lock="$1"; _al_wait="$2"; shift 2
	mkdir -p "$H5000M_LOCKDIR"
	(
		at_flock_wait "$_al_wait" "$_al_lock" || exit 4
		at_exec "$@"
	) 9>"$_al_lock"
}

at_locked_batch() {
	_ab_lock="$1"; _ab_wait="$2"; _ab_dev="$3"; _ab_tmo="$4"; shift 4
	mkdir -p "$H5000M_LOCKDIR"
	(
		at_flock_wait "$_ab_wait" "$_ab_lock" || exit 4
		# One stty for the whole held run instead of one per command.
		at_port_setup "$_ab_dev" || exit 1
		_AT_SKIP_SETUP=1
		for _ab_cmd in "$@"; do
			printf '@@CMD %s\n' "$_ab_cmd"
			at_exec "$_ab_dev" "$_ab_cmd" "$_ab_tmo"
			printf '@@RC %s\n' "$?"
		done
	) 9>"$_ab_lock"
}

# at_state_load - export USBPATH / AT_A / AT_B / AT_A_IF / AT_B_IF / NETDEV
at_state_load() {
	[ -r "$H5000M_MODEM_STATE" ] || return 1
	# shellcheck disable=SC1090
	. "$H5000M_MODEM_STATE"
	[ -n "$MODEM_USBPATH" ]
}

# at_reg_ok <+CEREG response text> - true when the modem reports it is registered.
#
# Shared rather than copied: the dialer and the band/slot guard must agree on what counts as
# registered, or the guard can revert a configuration the dialer is perfectly happy with (or
# the reverse). The accepted set is <n>,1 (home) and <n>,5 (roaming) for both unsolicited-
# result-code settings 0 and 1, because the guard and the dialer may see different <n>.
at_reg_ok() {
	case "$1" in
		*"+CEREG: 0,1"*|*"+CEREG: 0,5"*|*"+CEREG: 1,1"*|*"+CEREG: 1,5"*) return 0 ;;
	esac
	return 1
}

# at_reg_denied <+CEREG response text> - the network actively refused us. Terminal: waiting
# cannot help, so callers should stop rather than sit out their whole timeout.
at_reg_denied() {
	case "$1" in
		*"+CEREG: 0,3"*|*"+CEREG: 1,3"*) return 0 ;;
	esac
	return 1
}
