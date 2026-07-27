'use strict';
'require rpc';
'require ui';
'require poll';
'require dom';

// Shared cell-lock controller + apply-progress banner for the FM350 pages.
//
// WHY THIS IS SHARED (status, cells and radio all require it):
//  - An apply is a multi-minute apply/verify/revert window run by the fm350-radio procd guard,
//    and it takes the cellular link DOWN. radio_state is a pure file read (no AT), so polling it
//    on every page is cheap and lets an apply STARTED on one page — e.g. a Lock pressed on the
//    Cells list — stay visible if the user navigates away to Status or Radio.
//  - It owns the ONE lock/unlock UX, so the outage warning, the default-on "restrict to LTE"
//    note and the default-off "keep after reboot" rationale live in exactly one place instead of
//    drifting across three copies — the same single-sourcing that keeps ratName honest.
//  - Because a failed poll almost always means the very link this page rode in on is mid-retune,
//    a null result is rendered as "still working", never as an error.

var POLL = 3;

var callRadioState = rpc.declare({ object: 'luci.fm350', method: 'radio_state', expect: { '': {} } });
var callSimConfirm = rpc.declare({ object: 'luci.fm350', method: 'sim_confirm', expect: { '': {} } });
var callCellSet    = rpc.declare({ object: 'luci.fm350', method: 'cell_set',
                                   params: [ 'arfcn', 'pci', 'lte_only', 'persist' ], expect: { '': {} } });
var callCellUnlock = rpc.declare({ object: 'luci.fm350', method: 'cell_unlock', expect: { '': {} } });

function stateLabel(s) {
	switch (s) {
	case 'applying':  return _('Applying…');
	case 'verifying': return _('Verifying…');
	case 'reverting': return _('Reverting…');
	case 'ok':        return _('Done');
	case 'failed':    return _('Failed');
	case 'reverted':  return _('Reverted');
	case 'confirm':   return _('Awaiting confirmation');
	default:          return s || _('Working…');
	}
}

// Every apply/unlock confirm reuses this — the link genuinely drops, so say so once, here.
function outageWarning() {
	return [
		E('p', {}, [ _('The modem re-registers on the new configuration. This takes up to about 2.5 minutes and CELLULAR GOES DOWN while it runs.') ]),
		E('p', {}, [ _('If you are reading this over the cellular link, the page will lose contact and keep retrying on its own — do not close it.') ])
	];
}

function Progress(node) {
	this.node = node;
	this.applying = false;
	this.lock = null;        // { arfcn, pci } while a cell lock is active, else null
	this.last = undefined;   // last radio_state seen, so setLock() can re-render in place
	this.onSettle = null;    // view-supplied fn, called once an apply reaches a terminal state
}

// Start the radio_state poll and paint immediately. initialState is optional (a view that
// already loaded radio_state can hand it in to avoid a blank frame).
Progress.prototype.attach = function(initialState) {
	var self = this;
	if (initialState !== undefined)
		this.render(initialState);
	this.pollFn = function() { return self.refresh(); };
	poll.add(this.pollFn, POLL);
	return this.refresh();
};

Progress.prototype.refresh = function() {
	var self = this;
	return L.resolveDefault(callRadioState(), null).then(function(rs) { self.render(rs); });
};

// The view hands us the cell-lock state from the radio_info it already loaded, so Unlock is
// reachable from the banner without depending on the cell list rendering.
Progress.prototype.setLock = function(ri) {
	this.lock = (ri && ri.cell_locked) ? { arfcn: ri.cell_arfcn, pci: ri.cell_pci } : null;
	this.render(this.last);
};

// A view calls this right after it kicks an apply, so progress shows before the first poll.
Progress.prototype.beginApply = function(detail) {
	this.applying = true;
	this.render({ state: 'applying', detail: detail || _('Starting…') });
};

Progress.prototype.alert = function(state, detail) {
	var cls = (state === 'ok') ? 'success'
	        : (state === 'failed' || state === 'reverted') ? 'warning' : 'info';
	return E('div', { 'class': 'alert-message ' + cls }, [
		E('strong', {}, [ stateLabel(state) ]), detail ? ' ' + String(detail) : ''
	]);
};

Progress.prototype.simBanner = function(rs) {
	var self = this;
	return E('div', { 'class': 'alert-message warning' }, [
		E('h4', {}, [ _('SIM switch awaiting confirmation') ]),
		E('p', {}, [ rs.detail ? String(rs.detail) : _('A SIM slot switch reached data but has not been made permanent.') ]),
		E('p', {}, [ _('Do nothing and it rolls back to the previous SIM at the second reboot. Keep it only once you have confirmed data is on the account you expect (watch for roaming charges).') ]),
		E('div', {}, [
			E('button', { 'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(self, function() {
					return callSimConfirm().then(function() {
						ui.addNotification(null, E('p', _('SIM switch kept.')), 'info');
						return self.refresh();
					});
				}) }, [ _('Keep this SIM') ])
		])
	]);
};

Progress.prototype.lockBanner = function() {
	return E('div', { 'class': 'alert-message info' }, [
		E('span', {}, [ _('Cell lock active: EARFCN %s / PCI %s.').format(this.lock.arfcn, this.lock.pci) ]), ' ',
		E('button', { 'class': 'btn cbi-button-negative',
			'click': ui.createHandlerFn(this, 'unlock') }, [ _('Unlock cell') ])
	]);
};

Progress.prototype.render = function(rs) {
	this.last = rs;
	var out = [];

	// A SIM confirmation outranks everything else: it needs an explicit human action and its own
	// self-revert clock is ticking.
	var confirming = !!(rs && (rs.awaiting_confirm || rs.state === 'confirm'));
	if (confirming)
		out.push(this.simBanner(rs));

	if (rs === null) {
		// Poll failed — almost always the link we ride is mid-retune. Never surface an error.
		if (this.applying)
			out.push(this.alert('applying', _('Reconnecting to the router — the link is being retuned. This page recovers on its own.')));
	} else if (rs) {
		var s = rs.state || 'idle';
		if (s === 'applying' || s === 'verifying' || s === 'reverting') {
			this.applying = true;
			out.push(this.alert(s, rs.detail));
		} else if (s === 'ok' || s === 'failed' || s === 'reverted') {
			// React only to a terminal state we actually watched turn — a stale terminal from a
			// past apply, seen on first load, must not fire a spurious reload.
			if (this.applying) {
				this.applying = false;
				out.push(this.alert(s, rs.detail));
				if (this.onSettle)
					this.onSettle();
			}
		} else if (s === 'confirm') {
			this.applying = false;
		}
	}

	// Offer Unlock only while idle and actually locked, and never over a pending SIM confirm.
	if (this.lock && !this.applying && !confirming)
		out.push(this.lockBanner());

	dom.content(this.node, out);
};

// ---- lock / unlock UX: one implementation, shared by Cells (per row) and Radio (manual) ----

Progress.prototype.lock = function(arfcn, pci, opts) {
	var self = this;
	opts = opts || {};
	var lteOnly = E('input', { 'type': 'checkbox', 'checked': 'checked' });
	var persist = E('input', { 'type': 'checkbox' });

	var body = outageWarning();
	body.push(E('div', { 'class': 'cbi-value' }, [
		E('label', {}, [ lteOnly, ' ', _('Also restrict to LTE while locked (recommended)') ])
	]));
	// Measured: a cell lock constrains E-UTRAN selection only — with a cell locked and the radio
	// cycled, the modem camped on NR anyway. Ticking this pins the radio to LTE so the lock
	// actually takes effect; leaving it off lets 5G quietly defeat the lock.
	body.push(E('p', { 'class': 'cbi-value-description' }, [
		_('A cell lock constrains LTE only — without this the modem may camp on 5G/NR and ignore the lock entirely. Unlock later restores the previous radio configuration.')
	]));
	body.push(E('div', { 'class': 'cbi-value' }, [
		E('label', {}, [ persist, ' ', _('Keep after reboot') ])
	]));
	body.push(E('p', { 'class': 'cbi-value-description' }, [
		_('Default OFF on purpose: a lock that clears at the next reboot is your guaranteed way out if it kills the link. Persisting writes UCI, and only after data is proven.')
	]));
	body.push(E('div', { 'class': 'right' }, [
		E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
		E('button', { 'class': 'btn cbi-button-action important',
			'click': ui.createHandlerFn(self, function() {
				return callCellSet(arfcn, pci, lteOnly.checked ? 1 : 0, persist.checked ? 1 : 0).then(function(r) {
					ui.hideModal();
					// The backend's error names the valid range; surface it verbatim.
					if (!r || !r.ok)
						return ui.addNotification(null, E('p', (r && r.error) || _('Could not start the lock.')), 'danger');
					self.beginApply(_('Locking to EARFCN %s / PCI %s…').format(arfcn, pci));
					if (r.note)
						ui.addNotification(null, E('p', r.note), 'info');
				});
			}) }, [ _('Lock') ])
	]));
	return ui.showModal(opts.serving ? _('Pin to the current cell?')
	                                 : _('Lock to EARFCN %s / PCI %s?').format(arfcn, pci), body);
};

Progress.prototype.unlock = function() {
	var self = this;
	var body = outageWarning();
	// Unlock is not just "clear the lock": if the lock also restricted the RAT, cell_unlock puts
	// the previous band/RAT configuration back too — which is why there is no separate control.
	body.push(E('p', {}, [ _('This clears the cell lock and restores the previous radio configuration, including any LTE restriction the lock applied.') ]));
	body.push(E('div', { 'class': 'right' }, [
		E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
		E('button', { 'class': 'btn cbi-button-negative important',
			'click': ui.createHandlerFn(self, function() {
				return callCellUnlock().then(function(r) {
					ui.hideModal();
					if (!r || !r.ok)
						return ui.addNotification(null, E('p', (r && r.error) || _('Could not start the unlock.')), 'danger');
					self.beginApply(_('Unlocking…'));
					if (r.note)
						ui.addNotification(null, E('p', r.note), 'info');
				});
			}) }, [ _('Unlock') ])
	]));
	return ui.showModal(_('Unlock the cell?'), body);
};

return {
	create: function(node) { return new Progress(node); },
	outageWarning: outageWarning
};
