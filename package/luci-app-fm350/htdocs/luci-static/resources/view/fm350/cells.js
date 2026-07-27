'use strict';
'require view';
'require rpc';
'require dom';
'require ui';
'require fm350.progress';

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

// radio_info carries the current cell-lock state (cell_locked/cell_arfcn/cell_pci). We read it
// once per (re)load to highlight the locked row and to seed the shared banner's Unlock control -
// never on a poll, so opening this page costs one cached AT batch, not a standing modem drain.
var callRadioInfo = rpc.declare({ object: 'luci.fm350', method: 'radio_info', expect: { '': {} } });

// A cell is lockable only when it is an LTE (E-UTRAN) cell. cell.rat here is the GTCCINFO code
// (4=LTE, 9=NR, 2=UMTS) which is a DIFFERENT numbering from cell_caps.rats (EMMCHLCK 0/2/7), so
// they must not be compared directly. cell_set is an E-UTRAN lock (EARFCN+PCI, lte_only) with no
// RAT parameter, so LTE is the only RAT it can actually pin.
function lockReason(rat) {
	if (rat === 9)
		return _('NR cell locking is not supported by this firmware');
	if (rat === 2)
		return _('Cell locking applies to LTE cells only on this modem');
	return _('This cell type cannot be locked');
}

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
		var self = this;
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
				E('th', { 'class': 'th' }, [ 'SINR' ]),
				E('th', { 'class': 'th' }, [ _('Lock') ])
			]);

			var lk = self.lockInfo || {};

			// Rows arrive serving-first then strongest-RSRP-first; the backend already ordered
			// them, so we render in place and never re-sort.
			var body = cells.map(function(c) {
				var serving = !!c.serving;
				// This row IS the locked cell when EARFCN and PCI both match what EMMCHLCK reports.
				var lockedRow = lk.locked && c.arfcn === lk.arfcn && c.pci === lk.pci;
				return E('tr', {
					'class': 'tr',
					// Locked row tinted blue (overrides the serving green); serving tinted green.
					// Both are readable at a glance without a legend.
					'style': lockedRow ? 'background-color:rgba(0,80,200,0.10)'
					       : serving   ? 'background-color:rgba(0,136,0,0.08)' : ''
				}, [
					E('td', { 'class': 'td' }, [ serving ? E('strong', {}, [ _('Serving') ]) : _('neighbour') ]),
					E('td', { 'class': 'td' }, [ val(c.rat_name) ]),
					E('td', { 'class': 'td' }, [ val(c.band_label) ]),
					E('td', { 'class': 'td' }, [ val(c.arfcn) ]),
					E('td', { 'class': 'td' }, [ val(c.pci) ]),
					E('td', { 'class': 'td' }, [ val(c.bandwidth) ]),
					E('td', { 'class': 'td' }, [ num(c.rsrp, 'dBm', 0) ]),
					E('td', { 'class': 'td' }, [ num(c.rsrq, 'dB', 0) ]),
					E('td', { 'class': 'td' }, [ num(c.snr, 'dB', 0) ]),
					E('td', { 'class': 'td' }, [ self.lockCell(c, serving, lockedRow) ])
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

	// The per-row Lock cell. LTE rows get a live button (labelled "Pin to current cell" on the
	// serving row, the safest and most common intent); the row that is already locked shows a
	// bold "Locked" instead, with Unlock offered in the shared banner above. Non-LTE rows show a
	// DISABLED button with the reason beside it — a missing button reads as a bug, a disabled one
	// with its reason teaches the limit.
	lockCell: function(c, serving, lockedRow) {
		if (lockedRow)
			return E('strong', {}, [ _('Locked') ]);
		if (c.rat === 4)
			return E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleLock', c.arfcn, c.pci, serving)
			}, [ serving ? _('Pin to current cell') : _('Lock') ]);
		return E('span', {}, [
			E('button', { 'class': 'btn', 'disabled': 'disabled' }, [ _('Lock') ]), ' ',
			E('span', { 'class': 'cbi-value-description' }, [ lockReason(c.rat) ])
		]);
	},

	// The confirm modal, the outage warning and the lte_only/persist options all live in the
	// shared progress controller, so Cells and Radio drive the identical lock UX.
	handleLock: function(arfcn, pci, serving) {
		return this.progress.lock(arfcn, pci, { serving: serving });
	},

	// Re-read cells (non-forcing) and the lock state, then repaint. Used as the progress
	// controller's onSettle so a lock/unlock started here updates the highlight when it lands.
	reload: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(callCells(0), {}),
			L.resolveDefault(callRadioInfo(), {})
		]).then(function(res) {
			self.setLockInfo(res[1]);
			self.progress.setLock(res[1]);
			dom.content(self.container, self.renderResults(res[0]));
		});
	},

	setLockInfo: function(ri) {
		this.lockInfo = (ri && ri.cell_locked)
			? { locked: true, arfcn: ri.cell_arfcn, pci: ri.cell_pci }
			: { locked: false };
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
	// page is cheap and never disturbs the dialer; the user forces a scan explicitly. radio_info
	// rides alongside for the current lock state.
	load: function() {
		return Promise.all([
			L.resolveDefault(callCells(0), {}),
			L.resolveDefault(callRadioInfo(), {})
		]);
	},

	render: function(res) {
		var self = this;
		var r = res[0] || {};
		this.setLockInfo(res[1] || {});

		// Shared apply-progress + lock banner. Polls radio_state (no AT) so a lock started here
		// stays visible after navigating away, and it carries the Unlock control so unlocking
		// never depends on this cell list being rendered. onSettle repaints the highlight once an
		// apply lands.
		this.bannerBox = E('div');
		this.progress = progress.create(this.bannerBox);
		this.progress.setLock(res[1] || {});
		this.progress.onSettle = L.bind(this.reload, this);

		this.container = E('div');
		dom.content(this.container, this.renderResults(r));

		// If the last-known data is already mid-refresh (someone else forced it), chase the
		// result so the page settles on its own without the user pressing Scan.
		if (r && r.pending)
			this.chase(0);

		this.progress.attach();

		return E([], [
			E('h2', {}, [ _('FM350 Cells') ]),
			this.bannerBox,
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' }, [
					_('The serving cell and nearby cells the modem can see. Lock the modem to an LTE cell with the button on its row — "Pin to current cell" on the serving row is the safest choice. NR (5G) cells cannot be locked on this firmware. You can also steer by band on the Radio page.')
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
