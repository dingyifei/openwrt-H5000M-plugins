'use strict';
'require view';
'require rpc';
'require dom';
'require ui';

// FM350 cell survey page.
//
// Lists the serving cell and its neighbours as reported by the luci.fm350 rpcd backend.
// Like every FM350 view, nothing here opens the AT port directly - the backend serialises
// that access behind `atq` so the dialer keeping the link up always wins.
//
// The `cells` method is ASYNCHRONOUS on purpose. It never blocks rpcd: it returns whatever
// a detached collector last wrote to a file, and a forced call (refresh=1) merely kicks the
// collector and returns `pending:true` with the previous rows. The fresh scan lands on a
// LATER call ~5s afterward. So a Scan does one force plus a few bounded follow-up reads -
// NOT a standing poll (this shares the AT port with the dialer, so we touch it only on
// demand). "refreshing…" is shown meanwhile; it always resolves, never an endless spinner.

var FOLLOWUP_MS = 5000;   // the collector needs ~5s; re-read after that
var FOLLOWUP_MAX = 3;     // bounded: give up gracefully rather than poll the AT port forever

var callCells = rpc.declare({
	object: 'luci.fm350',
	method: 'cells',
	params: [ 'refresh' ],
	expect: { '': {} }
});

// Same dash semantics as the status page: null/undefined/'' is a dash, never "undefined" or
// a misleading number. Neighbour rows legitimately omit band/bandwidth/SINR and null the
// PLMN, so most cells lean on this.
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

function ageText(age) {
	if (age === null || age === undefined)
		return _('no scan yet');
	return _('updated %ds ago').format(age);
}

return view.extend({
	// --- rendering -------------------------------------------------------------------

	// Build just the results block (alerts + table + notes); render() wraps it with the
	// static heading and Scan button so a re-scan only swaps this subtree.
	renderResults: function(r) {
		r = r || {};
		var out = [];

		if (r.reachable === false) {
			// Explicit "didn't answer" beats an empty table that looks like "no cells here".
			out.push(E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, [ _('Modem did not answer.') ]), ' ',
				_('The AT port is busy or the modem is resetting; this page yields to the dialer by design. Try Scan again in a moment.')
			]));
		}

		var cells = r.cells || [];
		if (cells.length) {
			var head = E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ _('Role') ]),
				E('th', { 'class': 'th' }, [ _('RAT') ]),
				E('th', { 'class': 'th' }, [ _('Band') ]),
				E('th', { 'class': 'th' }, [ _('ARFCN') ]),
				E('th', { 'class': 'th' }, [ _('PCI') ]),
				E('th', { 'class': 'th' }, [ _('Bandwidth') ]),
				E('th', { 'class': 'th' }, [ 'RSRP' ]),
				E('th', { 'class': 'th' }, [ 'RSRQ' ]),
				E('th', { 'class': 'th' }, [ 'SINR' ])
			]);

			// Rows arrive serving-first then strongest-RSRP-first; the backend already ordered
			// them, so we render in place and never re-sort.
			var body = cells.map(function(c) {
				var serving = !!c.serving;
				return E('tr', {
					'class': 'tr',
					// Tint the serving row so it reads at a glance without a legend.
					'style': serving ? 'background-color:rgba(0,136,0,0.08)' : ''
				}, [
					E('td', { 'class': 'td' }, [ serving ? E('strong', {}, [ _('Serving') ]) : _('neighbour') ]),
					E('td', { 'class': 'td' }, [ val(c.rat_name) ]),
					E('td', { 'class': 'td' }, [ val(c.band_label) ]),
					E('td', { 'class': 'td' }, [ val(c.arfcn) ]),
					E('td', { 'class': 'td' }, [ val(c.pci) ]),
					E('td', { 'class': 'td' }, [ val(c.bandwidth) ]),
					E('td', { 'class': 'td' }, [ num(c.rsrp, 'dBm', 0) ]),
					E('td', { 'class': 'td' }, [ num(c.rsrq, 'dB', 0) ]),
					E('td', { 'class': 'td' }, [ num(c.snr, 'dB', 0) ])
				]);
			});

			out.push(E('table', { 'class': 'table' }, [ head ].concat(body)));
		} else if (r.reachable !== false) {
			out.push(E('p', {}, [ E('em', {}, [ _('No cells reported yet — press Scan.') ]) ]));
		}

		// Status line: age, an active-refresh hint, and a truncation caveat when the modem
		// returned more cells than it will enumerate.
		var notes = [ ageText(r.age) ];
		if (r.pending)
			notes.push(_('refreshing…'));
		if (r.truncated)
			notes.push(_('list truncated by the modem'));
		out.push(E('p', { 'class': 'cbi-value-description' }, [ notes.join(' · ') ]));

		return E([], out);
	},

	// --- async scan handling ---------------------------------------------------------

	// A forced scan returns immediately with pending=true; the real result appears on a
	// later read. Chase it with a few bounded, non-forcing follow-up reads (refresh=0) so
	// we do not re-kick the collector each time. Stops as soon as pending clears or we hit
	// the cap - never an unbounded loop against the shared AT port.
	chase: function(n) {
		var self = this;
		if (n >= FOLLOWUP_MAX)
			return;
		window.setTimeout(function() {
			L.resolveDefault(callCells(0), {}).then(function(r) {
				dom.content(self.container, self.renderResults(r));
				if (r && r.pending)
					self.chase(n + 1);
			});
		}, FOLLOWUP_MS);
	},

	handleScan: function() {
		var self = this;
		return L.resolveDefault(callCells(1), {}).then(function(r) {
			dom.content(self.container, self.renderResults(r));
			if (r && r.pending)
				self.chase(0);
		});
	},

	// --- view plumbing ---------------------------------------------------------------

	// Initial load reads the last-known survey WITHOUT forcing (refresh=0), so opening the
	// page is cheap and never disturbs the dialer; the user forces a scan explicitly.
	load: function() {
		return L.resolveDefault(callCells(0), {});
	},

	render: function(r) {
		var self = this;
		this.container = E('div');
		dom.content(this.container, this.renderResults(r));

		// If the last-known data is already mid-refresh (someone else forced it), chase the
		// result so the page settles on its own without the user pressing Scan.
		if (r && r.pending)
			this.chase(0);

		return E([], [
			E('h2', {}, [ _('FM350 Cells') ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' }, [
					_('The serving cell and nearby cells the modem can see. This is what band locking acts on: you can tell which bands neighbouring cells use and steer the modem toward or away from them. Per-PCI (per-cell) locking is not available on this modem — only whole bands.')
				]),
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleScan')
				}, [ _('Scan') ])
			]),
			this.container
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
