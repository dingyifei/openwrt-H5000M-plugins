'use strict';
'require view';
'require rpc';
'require dom';
'require ui';

// Settings page for the router-side SMS FIFO archive (package h5000m-sms-archive, optional -
// the SMS page already merges archived messages into the inbox regardless of whether this page
// is used, but until now the only way to turn the archiver on or tune it was raw UCI. This is
// the same gap the TTL page closed for h5000m-ttl, closed the same way: a *_get/*_set pair and
// a page, nothing more.
//
// `running` (is the procd service alive) and `enabled` (the UCI flag gating whether it does
// anything each wake cycle) are deliberately shown as two separate facts. The service is always
// started at boot once the package is installed; `enabled` is what actually turns automatic
// archiving-and-deleting on, and defaults OFF for exactly that reason.

var callGet = rpc.declare({ object: 'luci.fm350', method: 'archive_get', expect: { '': {} } });
var callSet = rpc.declare({ object: 'luci.fm350', method: 'archive_set',
                            params: [ 'enabled', 'threshold', 'batch_size', 'interval', 'max_messages' ],
                            expect: { '': {} } });

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
		// h5000m-sms-archive ships separately from luci-app-fm350 (EXTRA_DEPENDS, not a hard
		// dependency, matching h5000m-sms/h5000m-ttl) - it can be genuinely absent. Say so
		// rather than render controls that would silently do nothing.
		if (!d.installed)
			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'alert-message warning' }, [
					E('strong', {}, [ _('The h5000m-sms-archive package is not installed.') ]), ' ',
					_('The SMS inbox works without it, but the modem\'s own store is small and will fill up without a way to archive old messages off it.')
				])
			]);

		// Held as references rather than read back by id: this view re-renders on every
		// refresh, and a stale id from a previous render is a classic source of "the button
		// saves the wrong field" bugs.
		this.enableEl = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (d.enabled) this.enableEl.checked = true;

		this.thresholdEl = E('input', {
			'type': 'number', 'class': 'cbi-input-text', 'style': 'width:6em',
			'value': (d.threshold === null || d.threshold === undefined) ? 70 : d.threshold
		});
		this.batchEl = E('input', {
			'type': 'number', 'class': 'cbi-input-text', 'style': 'width:6em',
			'value': (d.batch_size === null || d.batch_size === undefined) ? 10 : d.batch_size
		});
		this.intervalEl = E('input', {
			'type': 'number', 'class': 'cbi-input-text', 'style': 'width:6em',
			'value': (d.interval === null || d.interval === undefined) ? 900 : d.interval
		});
		this.maxEl = E('input', {
			'type': 'number', 'class': 'cbi-input-text', 'style': 'width:6em',
			'value': (d.max_messages === null || d.max_messages === undefined) ? 0 : d.max_messages
		});

		var controls = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Settings') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Enable archiving') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.enableEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Off by default. While off the service still runs but does nothing each cycle — messages are never copied or deleted. Turn this on once you are comfortable letting it delete messages from the modem after archiving them.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Threshold') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.thresholdEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Modem store usage (segments, not messages — a multipart message counts once per part) that triggers a sweep. This unit was observed with roughly 90 slots total; leave headroom below the 80% warning on the SMS page.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Batch size') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.batchEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Oldest logical messages archived and deleted per cycle once the threshold is crossed. Kept small on purpose — if the store is still over threshold afterward, the next cycle simply runs again.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Interval (seconds)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.intervalEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('How often the archiver wakes up to check. 900 = 15 minutes. Re-read every cycle, so a change here takes effect on the next wake-up with no restart.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Keep at most') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					this.maxEl,
					E('div', { 'class': 'cbi-value-description' }, [
						_('0 = unbounded (the default) — every archived message is kept until you delete it by hand. Set a limit to have the oldest already-archived messages pruned automatically once the archive itself grows past this count. The router\'s storage is finite and this file is included in every configuration backup, so consider a limit once you know how much history you actually want kept.')
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

		var lastRun = null;
		if (d.last_run) {
			// Already a formatted "YYYY-MM-DD HH:MM:SS" string from the router's own clock,
			// not an epoch - shown verbatim rather than re-parsed into a Date.
			var when = d.last_run;
			lastRun = (d.last_result === 'ok')
				? E('span', {}, [ when, ' — ', d.last_summary || _('nothing to do') ])
				: E('span', { 'style': 'color:#a00' }, [ when, ' — ', _('failed: %s').format(d.last_summary || _('unknown error')) ]);
		}

		var state = rows(_('Current state'), [
			[ _('Service running'), onoff(d.running) ],
			[ _('Archiving'), onoff(d.enabled) ],
			[ _('Archived messages stored'), String(d.archived_count || 0) ],
			[ _('Modem store'), (d.used === null || d.used === undefined || !d.total)
			                     ? E('em', {}, [ '—' ])
			                     : _('%d of %d used').format(d.used, d.total) ],
			[ _('Last cycle'), lastRun || E('em', {}, [ _('has not run yet') ]) ]
		]);

		return E('div', {}, [ controls, state ]);
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
		var threshold = parseInt(this.thresholdEl.value, 10);
		var batch = parseInt(this.batchEl.value, 10);
		var interval = parseInt(this.intervalEl.value, 10);
		var max = parseInt(this.maxEl.value, 10);

		// Blank/non-numeric fields can never reach UCI meaningfully, so stop here. Out-of-range
		// values are deliberately NOT screened client-side — the backend owns every bound and
		// returns the exact range in its error, the same split the TTL page uses, so there is
		// one source of truth for what "valid" means.
		if (isNaN(threshold) || isNaN(batch) || isNaN(interval) || isNaN(max)) {
			ui.addNotification(null, E('p', {}, [ _('All four fields must be numbers.') ]), 'danger');
			return;
		}

		return callSet(enabled ? 1 : 0, threshold, batch, interval, max).then(function(r) {
			if (!r || r.ok === false) {
				ui.addNotification(null, E('p', {}, [
					_('Could not apply archive settings: %s').format((r && r.error) || _('unknown error'))
				]), 'danger');
			} else {
				ui.addNotification(null, E('p', {}, [ _('Archive settings applied.') ]), 'info');
			}
			// Re-read either way: on success to show the new stored state, on failure so the
			// controls snap back to what is actually saved rather than the rejected edit.
			return self.refresh();
		});
	},

	render: function(d) {
		this.container = E('div');
		dom.content(this.container, this.renderContent(d));

		return E([], [
			E('h2', {}, [ _('SMS Archive') ]),
			E('p', {}, [
				_('The modem\'s own SMS storage is small and rejects new messages silently once full. When enabled, this copies the oldest messages to the router and deletes them from the modem once the store crosses the threshold below — the SMS inbox then shows archived and live messages together, in one merged, chronological view.')
			]),
			this.container
		]);
	},

	// Not a CBI form — the single Apply button above owns the write, so there is no
	// Save/Apply footer to manage. Nulled on purpose, same as the TTL and status pages.
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
