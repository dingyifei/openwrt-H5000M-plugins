# shellcheck shell=sh
# fm350-watchdog.sh - dead-bearer detection and tiered recovery for fm350-dialer.
#
# Sourced by fm350-dialer, and sourced DIRECTLY by tests: defining functions only, it has no
# bring-up side effects, so tests can drive the ladder without a modem. Every irreversible
# action (modem reset, reboot) and every state path is overridable so a test redirects them
# off the real system.
#
# Why this exists: the modem keeps advertising a stale AT+CGPADDR after the carrier tears the
# data bearer down (measured: a dead IP held for ~1.5h while ping -I eth2 was 100% loss), so
# "we still hold an address" is NOT proof that data flows. The dialer therefore needs an
# ACTIVE data-path probe, feeding the re-dial path it already has (BEARER_LOST -> netifd
# respawn), with a guarded soft->hard->reboot escalation for the cases a re-dial cannot fix.
#
# ⚠️ Timing is COUNTER-BASED, never wall-clock. This board has no RTC and sysntpd steps the
# clock the moment the link comes up (see the long note in fm350-dialer), so a `date +%s`
# deadline computed beforehand is already in the past afterwards. "Healthy for HEALTHY_HOLD
# seconds" is expressed as ceil(HEALTHY_HOLD / PROBE_INTERVAL) consecutive good probe cycles -
# no /proc/uptime, no date.

# --- tunables (the dialer overrides these from its CLI args; these are the standalone
# defaults so the library is usable when sourced on its own) --------------------------------
: "${WATCHDOG:=1}"
: "${PROBE_TARGETS:=1.1.1.1 8.8.8.8 9.9.9.9}"
: "${PROBE_INTERVAL:=15}"
: "${PROBE_TIMEOUT:=2}"
: "${PROBE_FAILS:=4}"
: "${REDIAL_LIMIT:=3}"
: "${MODEM_RESET_LIMIT:=2}"
: "${REBOOT_LIMIT:=2}"
: "${HEALTHY_HOLD:=120}"

# --- overridable seams (tests point these at a scratch dir / stubs) -------------------------
: "${FM350_RECOV_DIR:=/var/run}"      # recovery counter: tmpfs, survives our respawn, clears on reboot
: "${FM350_GUARD_DIR:=/etc/h5000m}"   # reboot guard: overlay, must survive a reboot
: "${FM350_USB_RESET:=/usr/sbin/fm350-usb-reset}"
: "${FM350_REBOOT_CMD:=reboot}"

# --- logging (reuse the dialer's log.sh when present; degrade to stderr for standalone) -----
wd_log()  { if command -v log_info >/dev/null 2>&1; then log_info '%s' "$*"; else printf 'fm350-watchdog: %s\n' "$*" >&2; fi; }
wd_warn() { if command -v log_warn >/dev/null 2>&1; then log_warn '%s' "$*"; else printf 'fm350-watchdog: %s\n' "$*" >&2; fi; }

# --- counter files -------------------------------------------------------------------------
_recov_file() { printf '%s/fm350-%s.recov' "$FM350_RECOV_DIR" "$1"; }
_guard_file() { printf '%s/fm350-%s.reboot-guard' "$FM350_GUARD_DIR" "$1"; }

# A missing or malformed counter reads as 0 - a corrupt file must never wedge recovery.
_read_count() {
	_rc=$(cat "$1" 2>/dev/null)
	case "$_rc" in
		''|*[!0-9]*) printf '0' ;;
		*)           printf '%s' "$_rc" ;;
	esac
}

recov_read()  { _read_count "$(_recov_file "$1")"; }
recov_write() { printf '%s\n' "$2" > "$(_recov_file "$1")" 2>/dev/null; }
guard_read()  { _read_count "$(_guard_file "$1")"; }
# The guard must outlive a reboot: write it to the overlay and sync before we pull the trigger.
guard_write() { mkdir -p "$FM350_GUARD_DIR" 2>/dev/null; printf '%s\n' "$2" > "$(_guard_file "$1")" 2>/dev/null; sync 2>/dev/null; }

# --- pure helpers (unit-tested) ------------------------------------------------------------
# healthy_cycles -> consecutive good probes that count as "recovered" (>= 1).
healthy_cycles() {
	_hc=$(( (HEALTHY_HOLD + PROBE_INTERVAL - 1) / PROBE_INTERVAL ))
	[ "$_hc" -ge 1 ] || _hc=1
	printf '%s' "$_hc"
}

# ladder_tier <R> -> redial|reset|reboot for the R-th (R>=1) consecutive recovery attempt.
# The position is taken modulo (cycle+1) so that when a reboot is refused the ladder keeps
# cycling re-dial -> reset -> re-dial... forever instead of getting stuck.
ladder_tier() {
	_R="$1"
	_cycle=$(( REDIAL_LIMIT + MODEM_RESET_LIMIT ))
	_pos=$(( (_R - 1) % (_cycle + 1) ))
	if [ "$_pos" -lt "$REDIAL_LIMIT" ]; then
		printf 'redial'
	elif [ "$_pos" -lt "$_cycle" ]; then
		printf 'reset'
	else
		printf 'reboot'
	fi
}

# --- probing -------------------------------------------------------------------------------
# probe_ok <netdev> -> 0 if ANY target answers, 1 only if ALL fail. Binding to the netdev
# (never a literal eth name) makes the probe independent of which WAN owns the default route,
# so it stays correct when a second uplink is present. All-must-fail means one dead anycast
# node cannot trip recovery on its own.
probe_ok() {
	_nd="$1"
	for _t in $PROBE_TARGETS; do
		ping -I "$_nd" -c 1 -W "$PROBE_TIMEOUT" "$_t" >/dev/null 2>&1 && return 0
	done
	return 1
}

# probe_recovered <iface> - data has held for HEALTHY_HOLD; clear BOTH counters. This is what
# breaks the loops: only a fix that HOLDS resets the ladder, so an isolated drop hours later
# starts again at tier 1 while a genuinely stuck link keeps climbing.
probe_recovered() {
	recov_write "$1" 0
	guard_write "$1" 0
}

# --- the ladder ----------------------------------------------------------------------------
# bearer_recover <iface> <reason> -> advances the recovery counter and takes the tier action.
#   redial : (nothing here) - caller then notifies BEARER_LOST and exits, netifd re-dials.
#   reset  : power-cycle the modem synchronously, then caller exits -> re-dial into fresh modem.
#   reboot : if the guard is exhausted, log + reset the cycle + return 'reboot-refused' (caller
#            still re-dials); otherwise bump the persistent guard and reboot (does not return).
# Echoes the tier taken (redial|reset|reboot|reboot-refused) for logging and tests.
bearer_recover() {
	_iface="$1"; _reason="$2"
	_R=$(( $(recov_read "$_iface") + 1 ))
	recov_write "$_iface" "$_R"
	_tier=$(ladder_tier "$_R")
	case "$_tier" in
		redial)
			wd_log "bearer dead (${_reason}); re-dial (attempt ${_R})"
			printf 'redial'
			;;
		reset)
			wd_warn "bearer dead (${_reason}); attempt ${_R}: resetting the modem"
			"$FM350_USB_RESET" --wait >/dev/null 2>&1
			printf 'reset'
			;;
		reboot)
			_B=$(guard_read "$_iface")
			if [ "$_B" -ge "$REBOOT_LIMIT" ]; then
				wd_warn "bearer still dead after ${_B} reboot(s); reboot escalation exhausted - staying in re-dial/reset mode"
				recov_write "$_iface" 0
				printf 'reboot-refused'
				return 0
			fi
			guard_write "$_iface" "$(( _B + 1 ))"
			wd_warn "bearer dead (${_reason}); attempt ${_R}: rebooting (guard ${_B} -> $(( _B + 1 )))"
			"$FM350_REBOOT_CMD"
			printf 'reboot'
			;;
	esac
}
