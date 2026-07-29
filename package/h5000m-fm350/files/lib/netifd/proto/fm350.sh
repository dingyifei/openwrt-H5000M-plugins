#!/bin/sh
# netifd protocol handler for the Fibocom FM350-GL (RNDIS data + AT control).
#
# Why a custom proto rather than procd + 'static', or a raw hotplug script:
#   * 'static' would mean writing the granted IP back into UCI on every change -
#     flash wear plus an interface flap each time the network renumbers us.
#   * a hotplug script doing `ip addr add` loses the firewall zone, DNS ownership,
#     route metric and ubus state that netifd gives us for free.
# The decisive benefit is a STABLE UCI INTERFACE NAME ('cellular') that mwan3 and any
# later egress selector can reference, decoupled from the RNDIS netdev name.

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_fm350_init_config() {
	no_device=1
	available=1
	teardown_on_l3_link_down=1
	renew_handler=1

	proto_config_add_string apn
	proto_config_add_string pdp_type
	proto_config_add_string apn_type
	proto_config_add_string auth
	proto_config_add_int metric
	proto_config_add_int mtu
	proto_config_add_boolean peerdns

	# Dead-bearer watchdog (fm350-dialer + fm350-watchdog.sh). The modem keeps advertising a
	# stale CGPADDR after the carrier drops the data plane, so the dialer actively probes the
	# data path and, on sustained failure, climbs a re-dial -> modem-reset -> reboot ladder.
	# All optional; the defaults below (Balanced) match the dialer's built-ins.
	proto_config_add_boolean watchdog       # 1: enable the probe/ladder (default). 0: address-poll only, no recovery.
	proto_config_add_string  probe_targets  # space-separated IPs; a cycle is "down" only if ALL fail. default "1.1.1.1 8.8.8.8 9.9.9.9"
	proto_config_add_int     probe_interval # seconds between probes / loop tick. default 15
	proto_config_add_int     probe_timeout  # per-target ping wait, seconds. default 2
	proto_config_add_int     probe_fails    # consecutive failed cycles before recovery. default 4
	proto_config_add_int     redial_limit   # re-dials before escalating to a modem reset. default 3
	proto_config_add_int     modem_reset_limit # modem resets before escalating to a reboot. default 2
	proto_config_add_int     reboot_limit   # reboots a stuck bearer may trigger before giving up (0 disables the reboot tier). default 2
	proto_config_add_int     healthy_hold   # seconds of continuous data before the recovery counters clear. default 120
}

proto_fm350_setup() {
	local interface="$1"
	local apn pdp_type apn_type auth metric mtu peerdns
	local watchdog probe_targets probe_interval probe_timeout probe_fails
	local redial_limit modem_reset_limit reboot_limit healthy_hold

	json_get_vars apn pdp_type apn_type auth metric mtu peerdns
	json_get_vars watchdog probe_targets probe_interval probe_timeout probe_fails
	json_get_vars redial_limit modem_reset_limit reboot_limit healthy_hold

	# This modem has no +CGAUTH at all - PAP/CHAP would require AT+EIAAPN and is out
	# of scope - so anything other than 'none' is a configuration error we must not
	# silently ignore, or the user will chase a phantom APN problem instead.
	case "${auth:-none}" in
		none|"") ;;
		*)
			proto_notify_error "$interface" AUTH_UNSUPPORTED
			proto_block_restart "$interface"
			return 1
			;;
	esac

	# The modem picks the context id itself via +EAPNACT; what matters is the APN TYPE and
	# that exactly one context is active. A fixed pdp_index was the old model and is gone.
	[ -n "$apn_type" ] || apn_type=default

	# Pass the watchdog tunables with UCI-or-default values so the dialer never receives an
	# empty string (which would break its integer arithmetic). The defaults are the Balanced
	# profile and are kept in step with fm350-watchdog.sh's built-in defaults.
	proto_run_command "$interface" /usr/sbin/fm350-dialer \
		-i "$interface" \
		-a "${apn-}" \
		-t "${pdp_type:-IPV4V6}" \
		-y "$apn_type" \
		-m "${metric:-20}" \
		-u "${mtu:-0}" \
		-d "${peerdns:-1}" \
		--watchdog "${watchdog:-1}" \
		--probe-targets "${probe_targets:-1.1.1.1 8.8.8.8 9.9.9.9}" \
		--probe-interval "${probe_interval:-15}" \
		--probe-timeout "${probe_timeout:-2}" \
		--probe-fails "${probe_fails:-4}" \
		--redial-limit "${redial_limit:-3}" \
		--modem-reset-limit "${modem_reset_limit:-2}" \
		--reboot-limit "${reboot_limit:-2}" \
		--healthy-hold "${healthy_hold:-120}"
}

proto_fm350_renew() {
	local interface="$1"
	# A renew is a re-publish request, never a re-dial: tearing the bearer down to
	# refresh an address is how you get connect/disconnect churn.
	local pidfile="/var/run/fm350-${interface}.pid"
	[ -f "$pidfile" ] && kill -USR1 "$(cat "$pidfile")" 2>/dev/null
	return 0
}

proto_fm350_teardown() {
	local interface="$1"
	proto_kill_command "$interface"
}

[ -n "$INCLUDE_ONLY" ] || add_protocol fm350
