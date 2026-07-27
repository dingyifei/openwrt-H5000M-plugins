'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

// FM350 radio configuration: band lock, SIM slot, APN.
//
// This is the WRITE side. The heavy lifting lives in a procd guard (fm350-radio) that rpcd
// hands off to: an apply is an apply/verify/revert window that can last ~2.5 minutes and
// takes the cellular link DOWN while it runs, which is far longer than any HTTP request may
// stay open. So nothing here blocks on the result - band_set/sim_set return immediately and
// we watch `radio_state` (pure file reads, no AT) on a poll. Because the very link this page
// is loaded over may be the one being retuned, a failed poll is treated as "still working,
// keep waiting", never as an error.
//
// KEY HARDWARE TRUTH baked into the UI: band selection is PER-RAT and only NARROWS. Sending
// LTE bands narrows LTE alone and leaves UMTS and NR fully enabled. You therefore CANNOT turn
// a radio type off by unticking its bands - only by choosing a mode that omits it. The band
// note and the greyed-out groups exist to keep that from silently lying to the user.

var STATE_POLL = 3;    // radio_state cadence: drives progress + confirm banner (no AT cost)

var callRadioInfo  = rpc.declare({ object: 'luci.fm350', method: 'radio_info',  expect: { '': {} } });
var callRadioState = rpc.declare({ object: 'luci.fm350', method: 'radio_state', expect: { '': {} } });
var callBandSet    = rpc.declare({ object: 'luci.fm350', method: 'band_set',
                                   params: [ 'rat', 'bands', 'persist' ], expect: { '': {} } });
var callBandUnlock = rpc.declare({ object: 'luci.fm350', method: 'band_unlock', expect: { '': {} } });
var callSimSet     = rpc.declare({ object: 'luci.fm350', method: 'sim_set',
                                   params: [ 'slot' ], expect: { '': {} } });
var callSimConfirm = rpc.declare({ object: 'luci.fm350', method: 'sim_confirm', expect: { '': {} } });
var callStatus     = rpc.declare({ object: 'luci.fm350', method: 'status', params: [ 'ttl' ], expect: { '': {} } });
var callReconnect  = rpc.declare({ object: 'luci.fm350', method: 'reconnect', expect: { '': {} } });

// APN is plain network UCI, not a modem command - set it through ubus uci (session ACL),
// commit, then reuse the existing reconnect rather than adding a backend method.
var callUciGet    = rpc.declare({ object: 'uci', method: 'get',
                                  params: [ 'config', 'section' ], expect: { values: {} } });
var callUciSet    = rpc.declare({ object: 'uci', method: 'set',
                                  params: [ 'config', 'section', 'values' ] });
var callUciCommit = rpc.declare({ object: 'uci', method: 'commit', params: [ 'config' ] });

// Same dash/number semantics as the other FM350 views (module isolation => replicated).
function val(v, unit) {
	if (v === null || v === undefined || v === '')
		return E('em', {}, [ '—' ]);
	return unit ? '%s %s'.format(v, unit) : String(v);
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

// Mode names come from the BACKEND (radio_info.caps.rat_options), which decodes the manual
// §11.1.14 enumeration once. A second copy of that table here would drift the moment either
// side gained a mode - silently, because a wrong mode name still renders perfectly.
// `ratName` is therefore a lookup into what the backend sent, not a table of its own.
var RAT_NAMES = {};

function ratName(v) {
	return RAT_NAMES[v] || _('mode %d').format(v);
}

function loadRatNames(ri) {
	var opts = (ri && ri.caps && ri.caps.rat_options) || [];
	opts.forEach(function(o) { RAT_NAMES[o.value] = o.label; });
}

// Which RAT groups a mode PERMITS. Derived from the mode name (NR/LTE/UMTS -> those groups);
// "automatic" permits every group the hardware has. Unknown modes permit all (never grey a
// band we are unsure about). This is the rule that makes the "cannot disable a RAT by
// unticking bands" caveat concrete.
function ratGroups(v, capsBands) {
	if (v === 10) {
		var all = {};
		(capsBands || []).forEach(function(b) { all[b.group] = true; });
		return all;
	}
	var g = {}, name = ratName(v);
	name.split('/').forEach(function(tok) {
		if (tok === 'NR') g.nr = true;
		else if (tok === 'LTE') g.lte = true;
		else if (tok === 'UMTS') g.umts = true;
	});
	if (!g.nr && !g.lte && !g.umts)
		(capsBands || []).forEach(function(b) { g[b.group] = true; });
	return g;
}

var GROUP_ORDER = [ 'lte', 'nr', 'umts' ];
var GROUP_TITLE = { lte: 'LTE', nr: 'NR (5G)', umts: 'UMTS' };

return view.extend({
	applying: false,

	// --- band section ----------------------------------------------------------------

	currentRat: function() {
		if (this.ri.rat !== null && this.ri.rat !== undefined)
			return this.ri.rat;
		var rats = (this.ri.caps && this.ri.caps.rats) || [];
		return rats.length ? rats[0] : 10;
	},

	currentBands: function() {
		var set = {};
		((this.ri.band_labels) || []).forEach(function(b) { set[b.value] = true; });
		return set;
	},

	// Read the live checkbox state back into selBands so a mode change does not discard the
	// user's manual ticks.
	syncSelBands: function() {
		if (!this.bandListBox)
			return;
		var nodes = this.bandListBox.querySelectorAll('input.band-cb');
		for (var i = 0; i < nodes.length; i++)
			this.selBands[nodes[i].getAttribute('data-band')] = nodes[i].checked;
	},

	renderBandList: function() {
		var self = this;
		var caps = (this.ri.caps && this.ri.caps.bands) || [];
		var permitted = ratGroups(this.selRat, caps);
		var byGroup = { lte: [], nr: [], umts: [] };
		caps.forEach(function(b) { if (byGroup[b.group]) byGroup[b.group].push(b); });

		var out = [];
		GROUP_ORDER.forEach(function(g) {
			if (!byGroup[g].length)
				return;
			var allowed = !!permitted[g];
			var boxes = byGroup[g].map(function(b) {
				return E('label', {
					'style': 'display:inline-block;margin:0 1em 0.3em 0;' + (allowed ? '' : 'opacity:0.45')
				}, [
					E('input', {
						'type': 'checkbox',
						'class': 'band-cb',
						'data-band': String(b.value),
						'checked': self.selBands[b.value] ? 'checked' : null,
						'disabled': allowed ? null : 'disabled'
					}), ' ', b.label
				]);
			});
			out.push(E('div', { 'class': 'cbi-section-node' }, [
				E('h4', {}, [ GROUP_TITLE[g] + (allowed ? '' : ' — ' + _('excluded by the selected mode')) ]),
				E('div', {}, boxes)
			]));
		});
		return out.length ? out : [ E('p', {}, [ E('em', {}, [ _('No band capability reported.') ]) ]) ];
	},

	renderBandNote: function() {
		var caps = (this.ri.caps && this.ri.caps.bands) || [];
		var permitted = ratGroups(this.selRat, caps);
		var perms = [];
		[ 'nr', 'lte', 'umts' ].forEach(function(g) { if (permitted[g]) perms.push(g.toUpperCase()); });

		var lines = [ E('p', { 'class': 'cbi-value-description' }, [
			_('Radio types allowed by this mode: %s. The checkboxes only narrow bands WITHIN an allowed type — unticking every band of a type does NOT disable it. To exclude a radio type entirely, choose a mode above that omits it.').format(perms.join(', ') || '—')
		]) ];
		if (permitted.nr)
			lines.push(E('p', { 'class': 'cbi-value-description' }, [
				E('strong', {}, [ _('This mode permits 5G/NR: the modem may still camp on NR no matter which LTE boxes are ticked. Pick an LTE-only mode to prevent 5G.') ])
			]));
		return lines;
	},

	handleRatChange: function(ev) {
		this.syncSelBands();
		this.selRat = +ev.target.value;
		dom.content(this.bandListBox, this.renderBandList());
		dom.content(this.bandNoteBox, this.renderBandNote());
	},

	collectBands: function() {
		var nodes = this.bandListBox.querySelectorAll('input.band-cb');
		var out = [];
		for (var i = 0; i < nodes.length; i++)
			if (nodes[i].checked && !nodes[i].disabled)
				out.push(nodes[i].getAttribute('data-band'));
		return out.join(',');
	},

	// A compact "N LTE, M NR" summary of the currently enabled bands, for the Current row.
	enabledSummary: function() {
		var counts = {}, order = [];
		((this.ri.band_labels) || []).forEach(function(b) {
			var g = (b.group || '?').toUpperCase();
			if (!(g in counts)) { counts[g] = 0; order.push(g); }
			counts[g]++;
		});
		return order.map(function(g) { return counts[g] + ' ' + g; }).join(', ') || null;
	},

	bandNodes: function() {
		var self = this;
		var rats = (this.ri.caps && this.ri.caps.rats) || [];
		var options = rats.map(function(v) {
			return E('option', { 'value': String(v), 'selected': v === self.selRat ? 'selected' : null }, [ ratName(v) ]);
		});
		if (!options.length)
			options = [ E('option', { 'value': String(this.selRat) }, [ ratName(this.selRat) ]) ];

		this.ratSelect = E('select', { 'class': 'cbi-input-select' }, options);
		this.ratSelect.addEventListener('change', L.bind(this.handleRatChange, this));

		this.bandListBox = E('div');
		dom.content(this.bandListBox, this.renderBandList());
		this.bandNoteBox = E('div');
		dom.content(this.bandNoteBox, this.renderBandNote());
		this.persistCb = E('input', { 'type': 'checkbox' });

		var pref = [ this.ri.pref1_name, this.ri.pref2_name ].filter(function(x) { return x; }).join(' > ');

		return [
			rows(_('Current radio configuration'), [
				[ _('Mode'),          val(this.ri.rat_name) ],
				[ _('Preferred'),     pref ? pref : E('em', {}, [ '—' ]) ],
				[ _('Enabled bands'), val(this.enabledSummary()) ]
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Band lock') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Mode (RAT)') ]),
					E('div', { 'class': 'cbi-value-field' }, [ this.ratSelect ])
				]),
				this.bandNoteBox,
				this.bandListBox,
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Keep after reboot') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						this.persistCb, ' ',
						E('span', { 'class': 'cbi-value-description' }, [
							_('Default OFF on purpose: a band lock that dies at the next reboot is your guaranteed way out if it kills the link. Persisting writes UCI, and is offered only because the guard does so AFTER data is proven.')
						])
					])
				]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleApply') }, [ _('Apply band lock') ]), ' ',
					E('button', { 'class': 'btn',
						'click': ui.createHandlerFn(this, 'handleUnlock') }, [ _('Unlock (automatic)') ])
				])
			])
		];
	},

	outageWarning: function() {
		return [
			E('p', {}, [ _('The modem re-registers on the new configuration. This takes up to about 2.5 minutes and CELLULAR GOES DOWN while it runs.') ]),
			E('p', {}, [ _('If you are reading this over the cellular link, the page will lose contact and keep retrying on its own — do not close it.') ])
		];
	},

	handleApply: function() {
		var self = this;
		var rat = +this.ratSelect.value;
		var bands = this.collectBands();
		var persist = this.persistCb.checked ? 1 : 0;

		var body = this.outageWarning();
		body.push(persist
			? E('p', {}, [ E('strong', {}, [ _('“Keep after reboot” is ON — this lock will be written to config and survive a reboot.') ]) ])
			: E('p', {}, [ _('This lock clears on the next reboot (your guaranteed way out).') ]));
		body.push(E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
			E('button', { 'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, function() {
					return callBandSet(rat, bands, persist).then(function(r) {
						ui.hideModal();
						if (!r || !r.ok)
							return ui.addNotification(null, E('p', (r && r.error) || _('Could not start the apply.')), 'danger');
						self.applying = true;
						self.setProgress('applying', _('Starting…'));
						if (r.note)
							ui.addNotification(null, E('p', r.note), 'info');
					});
				}) }, [ _('Apply') ])
		]));
		return ui.showModal(_('Apply band lock?'), body);
	},

	handleUnlock: function() {
		var self = this;
		var body = this.outageWarning();
		body.push(E('p', {}, [ _('This returns the modem to automatic band selection for every radio type.') ]));
		// Measured: unlock is NOT "put it back how it was". AT+GTACT=10 enables every band the
		// radio is capable of, which on this unit was WIDER than the set enabled from the
		// factory (30 LTE bands became 31). Saying only "automatic" would let the user read
		// this as a restore, and there is no way back to the original subset except by
		// ticking it explicitly.
		body.push(E('p', { 'class': 'cbi-value-description' }, [
			E('strong', {}, [ _('Note: this widens rather than restores.') ]), ' ',
			_('Automatic enables every band the radio supports, which may be more than were enabled before. To return to a specific set, choose the bands explicitly instead.')
		]));
		body.push(E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
			E('button', { 'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, function() {
					return callBandUnlock().then(function(r) {
						ui.hideModal();
						if (!r || !r.ok)
							return ui.addNotification(null, E('p', (r && r.error) || _('Could not start the unlock.')), 'danger');
						self.applying = true;
						self.setProgress('applying', _('Starting…'));
						if (r.note)
							ui.addNotification(null, E('p', r.note), 'info');
					});
				}) }, [ _('Unlock') ])
		]));
		return ui.showModal(_('Unlock bands?'), body);
	},

	// --- SIM section -----------------------------------------------------------------

	simNodes: function() {
		var slot = this.ri.sim_slot;
		return [
			rows(_('Current SIM'), [
				[ _('Slot'), slot === 0 ? _('Physical SIM (slot 0)')
				           : slot === 1 ? _('eSIM (slot 1)')
				           : val(slot) ],
				[ _('Subscription'), val(this.ri.sim_sub) ],
				[ _('Type'), val(this.ri.sim_type_name) ]
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Switch SIM slot') ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn' + (slot === 0 ? '' : ' cbi-button-action'),
						'disabled': slot === 0 ? 'disabled' : null,
						'click': ui.createHandlerFn(this, 'handleSimPhysical')
					}, [ _('Switch to physical SIM') ]), ' ',
					E('button', {
						'class': 'btn' + (slot === 1 ? '' : ' cbi-button-action'),
						'disabled': slot === 1 ? 'disabled' : null,
						'click': ui.createHandlerFn(this, 'handleSimEsim')
					}, [ _('Switch to eSIM') ])
				])
			])
		];
	},

	handleSimPhysical: function() { return this.confirmSim(0); },
	handleSimEsim: function() { return this.confirmSim(1); },

	confirmSim: function(slot) {
		var self = this;
		var body = this.outageWarning();
		if (slot === 1)
			body.push(E('p', {}, [ E('strong', {}, [
				_('The eSIM (eUICC) currently has NO profile installed. Cellular will stay DOWN after the switch until you provision one. This is expected — the guard treats an empty eUICC as success and will NOT revert it.')
			]) ]));
		body.push(E('p', {}, [
			_('A SIM switch is NOT made permanent automatically. After data comes up you must click “Keep this SIM”, or it is rolled back to the current SIM at the second reboot — proof that data flows is not proof it flows on the account you want.')
		]));
		body.push(E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
			E('button', { 'class': 'btn cbi-button-negative important',
				'click': ui.createHandlerFn(this, function() {
					return callSimSet(slot).then(function(r) {
						ui.hideModal();
						if (!r || !r.ok)
							return ui.addNotification(null, E('p', (r && r.error) || _('Could not start the switch.')), 'danger');
						self.applying = true;
						self.setProgress('applying', _('Starting SIM switch…'));
						if (r.note)
							ui.addNotification(null, E('p', r.note), 'info');
					});
				}) }, [ slot === 1 ? _('Switch to eSIM') : _('Switch to physical SIM') ])
		]));
		return ui.showModal(slot === 1 ? _('Switch to eSIM?') : _('Switch to physical SIM?'), body);
	},

	// --- APN section -----------------------------------------------------------------

	apnNodes: function(uc, st) {
		uc = uc || {};
		st = st || {};
		this.apnInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': uc.apn || '' });
		var types = [ 'default', 'net', 'tethering' ];
		var cur = uc.apn_type || 'default';
		this.apnTypeSelect = E('select', { 'class': 'cbi-input-select' }, types.map(function(t) {
			return E('option', { 'value': t, 'selected': cur === t ? 'selected' : null }, [ t ]);
		}));

		return [
			rows(_('APN'), [
				[ _('Requested (configured)'), val(uc.apn) ],
				[ _('Granted (from network)'), val(st.apn) ]
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' }, [
					_('The requested APN is what you configure here; the granted APN is what the network actually assigned (+CGCONTRDP). They differ routinely on some carriers, and that difference is the useful diagnostic.')
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('APN') ]),
					E('div', { 'class': 'cbi-value-field' }, [ this.apnInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('APN type') ]),
					E('div', { 'class': 'cbi-value-field' }, [ this.apnTypeSelect ])
				]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleApnApply') }, [ _('Save APN & reconnect') ])
				])
			])
		];
	},

	handleApnApply: function() {
		var self = this;
		var apn = (this.apnInput.value || '').trim();
		var t = this.apnTypeSelect.value || 'default';
		return ui.showModal(_('Change APN and reconnect?'), [
			E('p', {}, [ _('This writes the APN to the cellular interface and reconnects. The link drops for a few seconds.') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', { 'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						return callUciSet('network', 'cellular', { apn: apn, apn_type: t })
							.then(function() { return callUciCommit('network'); })
							.then(function() {
								ui.hideModal();
								ui.addNotification(null, E('p', _('APN saved; reconnecting…')), 'info');
								return callReconnect();
							})
							.then(function() { return self.reload(); })
							.catch(function(e) {
								ui.hideModal();
								ui.addNotification(null, E('p', _('APN change failed: %s').format((e && e.message) || e)), 'danger');
							});
					}) }, [ _('Save & reconnect') ])
			])
		]);
	},

	// --- progress + confirm banner ---------------------------------------------------

	stateLabel: function(s) {
		switch (s) {
		case 'applying':  return _('Applying…');
		case 'verifying': return _('Verifying…');
		case 'reverting': return _('Reverting…');
		case 'ok':        return _('Done');
		case 'failed':    return _('Failed');
		case 'reverted':  return _('Reverted');
		case 'confirm':   return _('Awaiting confirmation');
		default:          return s;
		}
	},

	setProgress: function(state, detail) {
		var cls = (state === 'ok') ? 'success'
		        : (state === 'failed' || state === 'reverted') ? 'warning' : 'info';
		dom.content(this.progressBox, E('div', { 'class': 'alert-message ' + cls }, [
			E('strong', {}, [ this.stateLabel(state) ]), detail ? ' ' + String(detail) : ''
		]));
	},

	// The awaiting-confirm banner, shown here AND on the status page: a SIM switch that
	// reached data still needs an explicit Keep, or it self-reverts at the second reboot.
	bannerNode: function(rs) {
		var self = this;
		if (!rs || !(rs.awaiting_confirm || rs.state === 'confirm'))
			return [];
		return E('div', { 'class': 'alert-message warning' }, [
			E('h4', {}, [ _('SIM switch awaiting confirmation') ]),
			E('p', {}, [ rs.detail ? String(rs.detail) : _('A SIM slot switch reached data but has not been made permanent.') ]),
			E('p', {}, [ _('Do nothing and it rolls back to the previous SIM at the second reboot. Keep it only once you have confirmed data is on the account you expect (watch for roaming charges).') ]),
			E('div', {}, [
				E('button', { 'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						return callSimConfirm().then(function() {
							ui.addNotification(null, E('p', _('SIM switch kept.')), 'info');
							return self.refreshState();
						});
					}) }, [ _('Keep this SIM') ])
			])
		]);
	},

	renderState: function(rs) {
		dom.content(this.bannerBox, this.bannerNode(rs));

		// A failed poll almost always means the link we are on is mid-retune. Do NOT surface
		// an error; keep the "still working" message and let the next tick recover.
		if (rs === null) {
			if (this.applying)
				this.setProgress('applying', _('Reconnecting to the router — the link is being retuned. This page recovers on its own.'));
			return;
		}

		var s = rs.state || 'idle';
		if (s === 'applying' || s === 'verifying' || s === 'reverting') {
			this.applying = true;
			this.setProgress(s, rs.detail);
		}
		else if (s === 'ok' || s === 'failed' || s === 'reverted') {
			// Only react to a terminal state we caused; a stale terminal from a past apply on
			// first load must not trigger a spurious reload.
			if (this.applying) {
				this.applying = false;
				this.setProgress(s, rs.detail);
				this.reload();
			}
		}
		else if (s === 'confirm' || rs.awaiting_confirm) {
			this.applying = false;
			this.setProgress('confirm', rs.detail || _('SIM switch reached data — confirm to keep it in the banner above.'));
		}
	},

	refreshState: function() {
		var self = this;
		return L.resolveDefault(callRadioState(), null).then(function(rs) { self.renderState(rs); });
	},

	// --- data + plumbing -------------------------------------------------------------

	reload: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(callRadioInfo(), {}),
			L.resolveDefault(callUciGet('network', 'cellular'), {}),
			L.resolveDefault(callStatus(30), {})
		]).then(function(res) {
			self.ri = res[0] || {};
			loadRatNames(self.ri);
			self.selRat = self.currentRat();
			self.selBands = self.currentBands();
			dom.content(self.bandBox, self.bandNodes());
			dom.content(self.simBox, self.simNodes());
			dom.content(self.apnBox, self.apnNodes(res[1] || {}, res[2] || {}));
		});
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(callRadioInfo(), {}),
			L.resolveDefault(callRadioState(), {}),
			L.resolveDefault(callUciGet('network', 'cellular'), {}),
			L.resolveDefault(callStatus(30), {})
		]);
	},

	render: function(res) {
		this.ri = res[0] || {};
		loadRatNames(this.ri);
		var rs = res[1] || {};
		var uc = res[2] || {};
		var st = res[3] || {};

		this.selRat = this.currentRat();
		this.selBands = this.currentBands();

		this.bannerBox   = E('div');
		this.progressBox = E('div');
		this.bandBox     = E('div');
		this.simBox      = E('div');
		this.apnBox      = E('div');

		dom.content(this.bannerBox, this.bannerNode(rs));
		dom.content(this.bandBox, this.bandNodes());
		dom.content(this.simBox, this.simNodes());
		dom.content(this.apnBox, this.apnNodes(uc, st));

		// One continuous, cheap radio_state poll (file reads, no AT) drives both the progress
		// box and the confirm banner and, via L.resolveDefault(...null), quietly survives the
		// link dropping mid-apply. Registered once; never sped up or folded elsewhere.
		this.statePollFn = L.bind(this.refreshState, this);
		poll.add(this.statePollFn, STATE_POLL);

		return E([], [
			E('h2', {}, [ _('FM350 Radio') ]),
			this.bannerBox,
			this.bandBox,
			this.progressBox,
			this.simBox,
			this.apnBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
