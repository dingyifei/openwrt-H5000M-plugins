'use strict';
'require form';
'require network';

// LuCI handler for the custom 'fm350' netifd protocol.
//
// Without this, Network -> Interfaces shows the cellular interface as "unsupported
// protocol type / install extension protocol" and offers no form at all: LuCI only renders
// options for protocols it has a JS handler for. Nothing here drives the modem - the proto
// script and dialer in h5000m-fm350 do that. This is purely the UI contract, and the
// options below must stay in step with proto_config_add_* in /lib/netifd/proto/fm350.sh.

// The `return` is load-bearing and its absence is silent: LuCI's require/compileClass uses
// this module's RETURN VALUE as the protocol class, so without it the factory yields
// undefined and the page dies with
//   TypeError: "protocol.fm350" factory yields invalid constructor
// `node --check` passes either way - this is a contract violation, not a syntax error -
// which is why it shipped. Every official handler (protocol/dhcp.js et al) returns.
return network.registerProtocol('fm350', {
	getI18n: function() {
		return _('FM350 Cellular (RNDIS)');
	},

	// no_device=1 in the proto handler: the RNDIS netdev is discovered at runtime and is
	// deliberately never named in configuration, because it renumbers. So there is no
	// device to pick in the UI - that is the whole point of the custom protocol.
	getIfname: function() {
		return this._ubus('l3_device') || null;
	},

	getOpkgPackage: function() {
		return 'h5000m-fm350';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, 'apn', _('APN'),
			_('Leave EMPTY to request the subscription default, which is what the network guarantees and is self-correcting across carriers and travel eSIMs. A guessed APN can attach to the wrong gateway and silently discard traffic while still reporting "registered".'));
		o.placeholder = _('(blank - use the subscription default)');

		o = s.taboption('general', form.ListValue, 'pdp_type', _('PDP type'));
		o.value('IPV4V6', 'IPv4/IPv6');
		o.value('IP', 'IPv4');
		o.value('IPV6', 'IPv6');
		o.default = 'IPV4V6';
		o.description = _('Always request IPv4/IPv6. If the subscription allows only one family the network downgrades inside an accept, which is a success - not a reason to re-dial.');

		o = s.taboption('general', form.ListValue, 'apn_type', _('APN type'));
		o.value('default', _('default (internet)'));
		o.value('net', 'net');
		o.value('tethering', 'tethering');
		o.default = 'default';
		o.description = _('Selects which bearer the RNDIS data path carries. The modem chooses the context id itself, so there is no context number to set. Verified working as "default" on China Telecom.');

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication'));
		o.value('none', _('None'));
		o.default = 'none';
		o.description = _('Only "none" is accepted; this modem has no +CGAUTH.');

		o = s.taboption('advanced', form.Flag, 'peerdns', _('Use carrier DNS'));
		o.default = '1';

		o = s.taboption('advanced', form.Value, 'metric', _('Route metric'));
		o.datatype = 'uinteger';
		o.default = '20';
		o.description = _('Lowest metric wins. Left high by default so wired and Wi-Fi uplinks take precedence; mwan3 owns real failover ordering.');

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'));
		o.datatype = 'max(9200)';
		o.placeholder = _('(from the network)');
	}
});
