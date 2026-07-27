'use strict';
'require view';
'require rpc';
'require dom';
'require ui';

// FM350 TTL / hop-limit normalisation page.
//
// The mechanism lives in the separate h5000m-ttl package; this page only READS its state
// through luci.fm350.ttl_get and WRITES it through ttl_set. ttl_set runs the nft apply helper
// synchronously - nft generation plus one `fw4 reload`, no AT transaction - so unlike the radio
// pages there is no guard, no revert timer and no progress poll here: the call returns in a
// second or two and we simply re-read the state.

var callGet = rpc.declare({ object: 'luci.fm350', method: 'ttl_get', expect: { '': {} } });
var callSet = rpc.declare({ object: 'luci.fm350', method: 'ttl_set',
                            params: [ 'enabled', 'value', 'manage_offload' ], expect: { '': {} } });

// on/off pill for a boolean state row. Green only for "on" so an enabled TTL and live
// offloading both read as the state that is currently in force, not as "good".
function onoff(v) {
	return v ? E('span', { 'style': 'color:#0a0' }, [ _('on') ])
	         : E('span', {}, [ _('off') ]);
}

function rows(title, list) {
	var body = list.map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, [ E('strong', {}, [ r[0] ]) ]),
			E('td', { 'class': 'td left' }, [ r[1] ])
		]);
	});
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ title ]),
		E('table', { 'class': 'table' }, body)
	]);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callGet(), { installed: false });
	},

	renderContent: function(d) {
		// The package can be absent even though the LuCI app is installed (they ship
		// separately). Say so plainly rather than render controls that would silently do
		// nothing - a dead toggle is worse than an honest "not installed".
		if (!d.installed)
			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'alert-message warning' }, [
					E('strong', {}, [ _('The h5000m-ttl package is not installed.') ]), ' ',
					_('TTL normalisation cannot be configured from here until it is.')
				])
			]);

		// Hold references to the inputs rather than reading them back by id: this view is
		// re-rendered on every refresh, and stale ids from a previous render are a classic
		// source of "the button reads the wrong field" bugs.
		this.enableEl = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (d.enabled) this.enableEl.checked = true;

		this.valueEl = E('input', {
			'type': 'number', 'class': 'cbi-input-text',
			'min': 1, 'max': 255, 'style': 'width:6em',
			'value': (d.value === null || d.value === undefined) ? 64 : d.value
		});

		this.offloadEl = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		// Default ON, and reflect whatever is stored.
		if (d.manage_offload) this.offloadEl.checked = true;

		var controls = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Settings') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Enable TTL rewriting') ]),
				E('div', { 'class': 'cbi-value-field' }, [ this.enableEl ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('TTL / hop limit') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.valueEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('The value written into outgoing packets (1–255). 64 makes traffic from this router look like it originated on a typical phone or laptop.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Manage flow offloading') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.offloadEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('When on, enabling TTL rewriting also turns flow offloading off, because the two cannot both work (see below). Turn this off only if you understand that offloaded flows will not be rewritten.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleApply')
					}, [ _('Apply') ])
				])
			])
		]);

		// Current live state, read back from ttl_get. `active` is the rule being in the live
		// nftables ruleset - not merely configured - and both offloading flags are the real
		// firewall defaults, shown rather than assumed.
		var state = rows(_('Current state'), [
			[ _('TTL rule active'), d.active ? onoff(true)
			                                 : E('em', {}, [ _('not loaded') ]) ],
			[ _('Configured value'), (d.value === null || d.value === undefined)
			                           ? E('em', {}, [ '—' ]) : String(d.value) ],
			[ _('Interface'), d.interface ? String(d.interface) : E('em', {}, [ '—' ]) ],
			[ _('Software flow offloading'), onoff(d.flow_offloading) ],
			[ _('Hardware flow offloading'), onoff(d.flow_offloading_hw) ]
		]);

		// The offloading consequence, stated as the concrete failure mode rather than a
		// generic "may reduce effectiveness" warning: offloaded flows skip the postrouting
		// hook where the TTL is rewritten, so only a flow's FIRST packets get the new value.
		// A mix of 64 and 63 on the wire fingerprints tethering exactly as well as no rewrite
		// at all - so a half-applied rewrite is not a weaker disguise, it is no disguise.
		var offloadNote = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Why offloading is turned off') ]),
			E('p', {}, [
				_('Flow offloading forwards established connections in a fast path that bypasses the postrouting hook where the TTL is rewritten. With offloading on, only the first few packets of each connection are rewritten and the rest keep the router\'s own hop count. A connection carrying a mix of 64 and 63 is as easy to fingerprint as one that was never rewritten, so a partial rewrite is no disguise at all.')
			]),
			E('p', {}, [
				_('That is why enabling TTL rewriting turns both software and hardware flow offloading off. On this device that costs real forwarding throughput — it is a deliberate trade, not a bug.')
			]),
			// The trap this page must not fall into: `active` proves the rule is loaded, not
			// that the value is reaching the wire. Counters increment for a rule that a later
			// rule overrides. Only a capture from a downstream client settles it.
			E('p', { 'class': 'cbi-value-description' }, [
				_('“TTL rule active” means the rule is loaded into the live ruleset. It does not prove the value that actually reaches the wire — to confirm that, capture traffic on a downstream client (for example with tcpdump) and read the TTL there.')
			])
		]);

		return E('div', {}, [ controls, state, offloadNote ]);
	},

	refresh: function() {
		var self = this;
		return this.load().then(function(d) {
			dom.content(self.container, self.renderContent(d));
		});
	},

	handleApply: function(ev) {
		var self = this;
		var enabled = this.enableEl.checked;
		var manage  = this.offloadEl.checked;
		var value   = parseInt(this.valueEl.value, 10);

		// A blank or non-numeric field can never reach the modem meaningfully, so stop it
		// here. Out-of-RANGE numbers (0, 300) are deliberately NOT screened here - the backend
		// validates 1–255 and returns the exact range in its error, and surfacing the server's
		// own message verbatim keeps one source of truth for the bound.
		if (isNaN(value)) {
			ui.addNotification(null, E('p', {}, [ _('Enter a TTL value between 1 and 255.') ]), 'danger');
			return;
		}

		return callSet(enabled ? 1 : 0, value, manage ? 1 : 0).then(function(r) {
			if (!r || r.ok === false) {
				ui.addNotification(null, E('p', {}, [
					_('Could not apply TTL settings: %s').format((r && r.error) || _('unknown error'))
				]), 'danger');
			} else {
				ui.addNotification(null, E('p', {}, [ _('TTL settings applied.') ]), 'info');
			}
			// Re-read either way: on success to show the new live state, on failure so the
			// controls snap back to what is actually stored rather than the rejected edit.
			return self.refresh();
		});
	},

	render: function(d) {
		this.container = E('div');
		dom.content(this.container, this.renderContent(d));

		return E([], [
			E('h2', {}, [ _('TTL / Hop-limit') ]),
			E('p', {}, [
				_('Rewrites the TTL (IPv4) and hop limit (IPv6) of traffic leaving the router so it matches a single device. Some mobile networks meter or block traffic whose hop counts reveal that it was routed through a second device.')
			]),
			this.container
		]);
	},

	// This is not a CBI form: there is no Save/Apply footer to manage, and the single Apply
	// button above owns the write. Removing the footer hooks keeps LuCI from drawing an empty
	// one. handleReset is nulled here ON PURPOSE and no method of that name exists above.
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
