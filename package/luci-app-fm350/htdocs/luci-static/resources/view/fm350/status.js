'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

// FM350 status page.
//
// Everything shown here comes from the luci.fm350 rpcd backend, which serialises its AT
// access through `atq` at the lowest priority tier. Nothing in this file talks to the
// modem; that is deliberate and load-bearing - the single AT port is shared with the
// dialer keeping the link alive.

var GENTLE = 15, LIVE = 3, LIVE_MAX_MS = 5 * 60 * 1000;

var callStatus = rpc.declare({
	object: 'luci.fm350',
	method: 'status',
	params: [ 'ttl' ],
	expect: { '': {} }
});

var callReconnect = rpc.declare({ object: 'luci.fm350', method: 'reconnect', expect: { '': {} } });
var callReset     = rpc.declare({ object: 'luci.fm350', method: 'reset_modem', expect: { '': {} } });
var callResetStat = rpc.declare({ object: 'luci.fm350', method: 'reset_status', expect: { '': {} } });

// Unavailable is rendered as a dash, never as a number. +CESQ reports 255 for metrics that
// do not apply to the current radio technology, and printing that as "255 dBm" would be
// worse than printing nothing.
function val(v, unit) {
	if (v === null || v === undefined || v === '')
		return E('em', {}, [ '—' ]);
	return unit ? '%s %s'.format(v, unit) : String(v);
}

function num(v, unit, digits) {
	if (v === null || v === undefined)
		return E('em', {}, [ '—' ]);
	return '%s %s'.format(Number(v).toFixed(digits === undefined ? 1 : digits), unit);
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
	liveUntil: 0,

	interval: function() {
		if (this.liveUntil && Date.now() < this.liveUntil)
			return LIVE;
		// A live toggle that never switches itself off is a footgun: a tab left open would
		// poll the shared AT port every few seconds indefinitely, and whoever left it open
		// is by definition not watching. Expire back to gentle instead.
		if (this.liveUntil) {
			this.liveUntil = 0;
			ui.addNotification(null, E('p', _('Live refresh expired; back to normal refresh.')), 'info');
		}
		return GENTLE;
	},

	load: function() {
		return L.resolveDefault(callStatus(this.interval()), {});
	},

	renderContent: function(s) {
		var st = s.interface || {};

		if (s.modem_reachable === false) {
			return E('div', {}, [
				E('div', { 'class': 'alert-message warning' }, [
					E('strong', {}, [ _('Modem did not answer.') ]), ' ',
					_('The AT port is busy or the modem is resetting. This page yields to the dialer by design, so a brief failure during a reconnect is expected.')
				])
			]);
		}

		return E('div', {}, [
			rows(_('Connection'), [
				[ _('Interface'),    st.up ? E('span', { 'style': 'color:#0a0' }, [ _('up') ])
				                           : E('span', { 'style': 'color:#a00' }, [ _('down') ]) ],
				[ _('Device'),       val(st.device) ],
				[ _('IPv4 address'), val(st.ipv4) ],
				[ _('Gateway'),      val(st.gateway) ],
				[ _('DNS'),          (s.dns && s.dns.length) ? s.dns.join(', ') : E('em', {}, [ '—' ]) ],
				[ _('Packets'),      (s.rx_packets === null || s.rx_packets === undefined)
				                       ? E('em', {}, [ '—' ])
				                       : 'rx %d / tx %d'.format(s.rx_packets, s.tx_packets) ]
			]),

			rows(_('Network'), [
				[ _('Operator'),     val(s.operator) ],
				[ _('Technology'),   val(s.act_name) ],
				[ _('Registration'), val(s.reg_name) ],
				[ _('APN'),          s.apn ? s.apn : E('em', {}, [ _('(subscription default)') ]) ],
				[ _('Context id'),   val(s.aid) ]
			]),

			// Which metrics exist depends on the radio technology - the modem reports 255
			// for the ones that do not apply, and this unit switches between LTE and NR.
			rows(_('Signal') + (s.rat_hint ? ' (' + s.rat_hint + ')' : ''), [
				[ 'RSRP', num(s.rsrp, 'dBm') ],
				[ 'RSRQ', num(s.rsrq, 'dB') ],
				[ 'SINR', num(s.sinr, 'dB') ]
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' }, [
					s.cached ? _('Cached %ds ago; shared by every open tab.').format(s.age || 0)
					         : _('Fresh reading.')
				])
			])
		]);
	},

	// poll.add() fixes its interval at registration time, so switching modes means
	// re-registering. Asking the backend for a shorter TTL alone would NOT make the page
	// live - it would just fetch fresher data on the same 15s tick.
	setPoll: function(secs) {
		if (this.pollFn)
			poll.remove(this.pollFn);
		var self = this;
		this.pollFn = function() { return self.refresh(); };
		poll.add(this.pollFn, secs);
	},

	handleLive: function(ev) {
		this.liveUntil = Date.now() + LIVE_MAX_MS;
		this.setPoll(LIVE);
		ui.addNotification(null, E('p', _('Live refresh on for 5 minutes.')), 'info');
		return this.refresh();
	},

	refresh: function() {
		var self = this;
		// Reading the interval here is what expires live mode: interval() flips liveUntil
		// back and returns GENTLE, and we then re-register at the slower rate.
		var want = this.interval();
		if (want !== this.pollSecs) {
			this.pollSecs = want;
			this.setPoll(want);
		}
		return this.load().then(function(s) {
			dom.content(self.container, self.renderContent(s));
		});
	},

	handleReconnect: function(ev) {
		var self = this;
		return ui.showModal(_('Reconnect cellular?'), [
			E('p', {}, [ _('This runs ifdown then ifup on the cellular interface. The link drops for a few seconds.') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						return callReconnect().then(function() {
							ui.hideModal();
							ui.addNotification(null, E('p', _('Reconnecting…')), 'info');
							return self.refresh();
						});
					})
				}, [ _('Reconnect') ])
			])
		]);
	},

	// NOT named handleReset: that is LuCI's own form-reset hook, and the `handleReset: null`
	// at the bottom of this object (which removes the Save/Reset footer) would silently
	// overwrite it, leaving a button wired to null.
	handleModemReset: function(ev) {
		var self = this;
		return ui.showModal(_('Reset the modem?'), [
			E('p', {}, [ _('This power-cycles the modem over USB. It is the recovery that works when the AT port has gone half-dead — unbinding the USB device does not fix that state and can make it worse.') ]),
			E('p', {}, [ E('strong', {}, [ _('Cellular will be down for about 70 seconds.') ]) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(this, function() {
						return callReset().then(function(r) {
							ui.hideModal();
							if (!r.ok) {
								ui.addNotification(null, E('p', r.error || _('Reset failed.')), 'danger');
								return;
							}
							ui.addNotification(null, E('p', _('Modem reset started; this takes about 70 seconds.')), 'info');
							self.pollReset(0);
						});
					})
				}, [ _('Reset modem') ])
			])
		]);
	},

	// Poll the AT endpoint back to life. The backend checks with stty rather than for the
	// device node, because the nodes reappear several seconds before the port actually
	// works - reporting success on the node alone would tell the user it recovered when
	// it has not.
	pollReset: function(n) {
		var self = this;
		if (n > 30)
			return ui.addNotification(null, E('p', _('Modem has not come back after 5 minutes — it may need a power cycle.')), 'danger');
		window.setTimeout(function() {
			callResetStat().then(function(r) {
				if (r && r.ready) {
					ui.addNotification(null, E('p', _('Modem is back; AT port responding.')), 'info');
					self.refresh();
				} else {
					self.pollReset(n + 1);
				}
			});
		}, 10000);
	},

	render: function(s) {
		var self = this;
		this.container = E('div');
		dom.content(this.container, this.renderContent(s));

		var content = E([], [
			E('h2', {}, [ _('FM350 Cellular Modem') ]),
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleLive')
				}, [ _('Live refresh (5 min)') ]), ' ',
				E('button', {
					'class': 'btn',
					'click': ui.createHandlerFn(this, 'handleReconnect')
				}, [ _('Reconnect') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleModemReset')
				}, [ _('Reset modem') ])
			]),
			this.container
		]);

		this.pollSecs = GENTLE;
		this.setPoll(GENTLE);

		return content;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
