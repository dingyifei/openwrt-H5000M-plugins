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

network.registerProtocol('fm350', {
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

		o = s.taboption('general', form.Value, 'pdp_index', _('PDP context id'));
		o.datatype = 'range(1,15)';
		o.default = '1';
		o.description = _('Hardware constraint, not a preference: this modem forwards RNDIS traffic on the initial bearer only. On another context you get an IP address and every packet is silently dropped.');

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication'));
		o.value('none', _('None'));
		o.default = 'none';
		o.description = _('Only "none" is accepted. PAP/CHAP would need the initial-attach-APN command, which is out of scope here.');

		o = s.taboption('advanced', form.Flag, 'peerdns', _('Use carrier DNS'));
		o.default = '1';

		o = s.taboption('advanced', form.Value, 'metric', _('Route metric'));
		o.datatype = 'uinteger';
		o.default = '20';
		o.description = _('Lowest metric wins. Left high by default so wired and Wi-Fi uplinks take precedence; mwan3 owns real failover ordering.');

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'));
		o.datatype = 'max(9200)';
		o.placeholder = _('(from the network)');

		o = s.taboption('advanced', form.Flag, 'set_attach_apn', _('Also set the attach APN'));
		o.default = '0';
		o.description = _('Sends the initial-attach-APN command in addition to the context definition. Off by default because it is rejected on the firmware this was developed against.');
	}
});
