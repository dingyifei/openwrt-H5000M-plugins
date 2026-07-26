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
}

proto_fm350_setup() {
	local interface="$1"
	local apn pdp_type apn_type auth metric mtu peerdns

	json_get_vars apn pdp_type apn_type auth metric mtu peerdns

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

	proto_run_command "$interface" /usr/sbin/fm350-dialer \
		-i "$interface" \
		-a "${apn-}" \
		-t "${pdp_type:-IPV4V6}" \
		-y "$apn_type" \
		-m "${metric:-20}" \
		-u "${mtu:-0}" \
		-d "${peerdns:-1}"
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
