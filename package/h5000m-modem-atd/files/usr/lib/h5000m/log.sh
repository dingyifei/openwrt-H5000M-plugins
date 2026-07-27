#!/bin/sh
# Tiered logging for the H5000M stack. Sourced, not executed.
#
# WHY THIS EXISTS - two failures at once, both real:
#
#   Too much: the dialer logged "waiting for the modem to finish coming up" every 10s, up
#   to a dozen lines per bring-up, unconditionally at info. That is not merely untidy.
#   OpenWrt's logd is a FIXED-SIZE RAM RING BUFFER, so a chatty component does not just add
#   noise - it EVICTS EVERYTHING ELSE, destroying the evidence you would need for an
#   unrelated failure.
#
#   Too little: there was no way to see the actual AT exchange without editing atio.sh on
#   the device. Hours went into reconstructing what the modem had replied.
#
# Everything routes to syslog with a real priority, so `logread -p` keeps working and
# nothing bypasses the system logger.
#
# FORK BUDGET IS THE DESIGN CONSTRAINT. This runs on a ~1GHz router; the dialer logs on
# every poll and a web UI will poll every few seconds. In busybox ash every $( ), pipe and
# external applet is a fork, so:
#   * a SUPPRESSED call must cost ZERO forks - hence the fork-free `case` level check, and
#     `log_want` so callers can skip building expensive arguments they will not use;
#   * an EMITTED call costs one `logger`, and nothing else unless redaction fires.
#
# Usage:
#   . /usr/lib/h5000m/log.sh
#   h5000m_log_init fm350
#   log_info 'published %s' "$ip"          # printf-style; never string-concatenated
#   log_want trace && log_trace '< %s' "$(expensive)"
#
# Safe under `set -u`: every expansion below is defaulted.

H5000M_LOG_CONFIG=h5000m

_H5_TAG=h5000m
_H5_COMP=h5000m
_H5_LEVEL=2
_H5_REDACT=1
_H5_DEDUP_MAX=50
_H5_INIT=0

# Dedup state. Deliberately in-process and trap-free: several callers already install their
# own EXIT trap (the dialer's cleanup), and silently stealing it would be worse than the
# spam this suppresses. The run is flushed when a different message arrives - which is what
# happens the moment a wait loop ends, the case this exists for - or at _H5_DEDUP_MAX, so a
# long-lived process cannot sit on an un-emitted counter indefinitely.
_H5_LAST=''
_H5_LAST_N=0
_H5_LAST_PRI=info

# Fork-free name -> number. Assigns rather than prints, because a printing helper would
# have to be called through $( ), i.e. a fork on the hottest path in the file.
_h5_setlvl() {
	case "$1" in
		error) _h5_n=0 ;; warn) _h5_n=1 ;; info) _h5_n=2 ;;
		debug) _h5_n=3 ;; trace) _h5_n=4 ;;
		*)     _h5_n=2 ;;
	esac
}

# log_want <level> - true if that level would be emitted. Lets a caller avoid building an
# argument it is about to throw away; collapsing a multi-line AT transcript cost three
# forks per AT command at the default level before this existed.
log_want() {
	[ "$_H5_INIT" = 1 ] || h5000m_log_init "$_H5_COMP" "$_H5_TAG"
	_h5_setlvl "$1"
	[ "$_h5_n" -le "$_H5_LEVEL" ]
}

# h5000m_log_init <component> [syslog-tag]
#
# ONE `uci show` rather than four `uci get`s: this is sourced by atq, at-lease, the SMS and
# eSIM wrappers and both hotplug scripts, and OpenWrt runs a tty hotplug handler once per
# node - seven per modem plug event. Four forks each turned into 28 on the plug path.
#
# The component is the UCI KEY; the tag is what appears in syslog. They differ where a tag
# carries runtime detail - the dialer logs as "fm350[cellular]" but must still be
# configurable as h5000m.logging.fm350, because a key you cannot guess is a key nobody sets.
h5000m_log_init() {
	_H5_COMP="${1:-h5000m}"
	_H5_TAG="${2:-$_H5_COMP}"
	_H5_INIT=1

	# The heredoc (rather than a pipe) keeps the `while` in THIS shell - a piped loop runs
	# in a subshell and every assignment below would be discarded on exit. Quotes are
	# stripped with parameter expansion rather than `tr`, which would be a second fork.
	_h5_lvl=''; _h5_own=''
	while read -r _h5_line; do
		_h5_v="${_h5_line#*=}"; _h5_v="${_h5_v#\'}"; _h5_v="${_h5_v%\'}"
		case "$_h5_line" in
			*".logging.level="*)        _h5_lvl="$_h5_v" ;;
			*".logging.${_H5_COMP}="*)  _h5_own="$_h5_v" ;;
			*".logging.trace_redact="*) _H5_REDACT="$_h5_v" ;;
			*".logging.dedup_max="*)    _H5_DEDUP_MAX="$_h5_v" ;;
		esac
	done <<EOF
$(uci -q show "${H5000M_LOG_CONFIG}.logging" 2>/dev/null)
EOF

	# Per-component overrides matter because components fail differently: chasing a dialer
	# bug should not also turn on AT tracing for everything else on the box.
	[ -n "${_h5_own:-}" ] && _h5_lvl="$_h5_own"
	_h5_setlvl "${_h5_lvl:-info}"; _H5_LEVEL="$_h5_n"

	case "${_H5_REDACT:-}" in ''|*[!0-9]*) _H5_REDACT=1 ;; esac
	case "${_H5_DEDUP_MAX:-}" in ''|*[!0-9]*) _H5_DEDUP_MAX=50 ;; esac

	# Loud on purpose. Unredacted tracing writes identifiers to a log that may be forwarded
	# off-box, so it must never be something someone enables and forgets.
	if [ "$_H5_LEVEL" -ge 4 ] && [ "$_H5_REDACT" = 0 ]; then
		logger -t "$_H5_TAG" -p daemon.warn \
			"UNREDACTED AT TRACING IS ON - IMSI/EID/ICCID/phone numbers/SMS bodies will be written to syslog. Set ${H5000M_LOG_CONFIG}.logging.trace_redact=1 when finished."
	fi
}

# Mask identifier-bearing values. AT traffic carries IMSI (15 digits), ICCID (19-20), EID
# (32), MSISDNs and whole SMS bodies; PDUs are long hex. Matching on VALUE SHAPE rather
# than on a list of commands is deliberate - a command-name list silently stops covering
# anything added later, and this is a privacy control, so it should fail closed.
#
# The glob guard matters: most logged lines (OK, +CGACT: 1,1, +CESQ: 99,99,...) contain no
# long run at all, and skipping sed for those is the difference between two forks per line
# and none. Hex first - a 20+ digit run is a PDU, not a number.
_h5_redact() {
	case "$1" in
		*[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*|*'"'*'"'*)
			printf '%s' "$1" | sed \
				-e 's/[0-9A-Fa-f]\{20,\}/<redacted-pdu>/g' \
				-e 's/[0-9]\{7,\}/<redacted>/g' \
				-e 's/"[^"]\{7,\}"/"<redacted>"/g'
			;;
		*) printf '%s' "$1" ;;
	esac
}

_h5_emit() {
	case "$1" in
		error) _he_sys=daemon.err ;;
		warn)  _he_sys=daemon.warn ;;
		info)  _he_sys=daemon.info ;;
		*)     _he_sys=daemon.debug ;;
	esac
	logger -t "$_H5_TAG" -p "$_he_sys" "$2"
}

_h5_flush() {
	if [ "$_H5_LAST_N" -gt 1 ] 2>/dev/null; then
		_h5_emit "$_H5_LAST_PRI" "$_H5_LAST (repeated $_H5_LAST_N times)"
	fi
	_H5_LAST=''
	_H5_LAST_N=0
}

# h5000m_log_flush - force the repeat counter out early, e.g. before a long sleep.
h5000m_log_flush() { _h5_flush; }

_h5_log() {
	_hl_pri="$1"; shift
	[ "$_H5_INIT" = 1 ] || h5000m_log_init "$_H5_COMP" "$_H5_TAG"
	_h5_setlvl "$_hl_pri"
	[ "$_h5_n" -le "$_H5_LEVEL" ] || return 0

	# printf-style so a message containing % or a stray format char cannot be
	# reinterpreted, which a naive `logger "$*"` would allow. The '%s' short-circuit skips
	# a fork for the many callers (at_log, at_warn, the dialer's log/warn) that pass a
	# pre-built string.
	if [ "$1" = '%s' ] && [ $# -eq 2 ]; then
		_hl_msg="$2"
	else
		_hl_fmt="$1"; shift
		# shellcheck disable=SC2059
		_hl_msg="$(printf "$_hl_fmt" "$@" 2>/dev/null)"
	fi

	# Redaction runs at EVERY level, not just trace. An ICCID quoted in a warning or an
	# MSISDN in an SMS status line is exactly as sensitive as the same value at trace, and
	# binding a privacy control to a verbosity setting is how such things leak.
	[ "$_H5_REDACT" != 0 ] && _hl_msg="$(_h5_redact "$_hl_msg")"

	if [ "$_hl_msg" = "$_H5_LAST" ]; then
		_H5_LAST_N=$(( _H5_LAST_N + 1 ))
		[ "$_H5_LAST_N" -lt "$_H5_DEDUP_MAX" ] && return 0
		_h5_flush
		return 0
	fi

	_h5_flush
	_H5_LAST="$_hl_msg"
	_H5_LAST_N=1
	_H5_LAST_PRI="$_hl_pri"
	_h5_emit "$_hl_pri" "$_hl_msg"
}

log_error() { _h5_log error "$@"; }
log_warn()  { _h5_log warn  "$@"; }
log_info()  { _h5_log info  "$@"; }
log_debug() { _h5_log debug "$@"; }
log_trace() { _h5_log trace "$@"; }
