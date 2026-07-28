'use strict';
'require view';
'require rpc';
'require dom';
'require ui';

// FM350 SMS inbox and composer.
//
// sms_tool (from the official feed) decodes PDU mode and UCS2, but it does NOT reassemble
// multipart (concatenated) SMS - it emits one row per storage slot. The rpcd backend groups
// the segments into logical messages and merges in any router-side archive, so each row here
// is already one whole message. The backend runs sms_tool under the AT-port lease so reading
// the inbox cannot desynchronise the dialer.

var callList   = rpc.declare({ object: 'luci.fm350', method: 'sms_list', expect: { '': {} } });
var callSend   = rpc.declare({ object: 'luci.fm350', method: 'sms_send',
                               params: [ 'number', 'text' ], expect: { '': {} } });
var callDelete = rpc.declare({ object: 'luci.fm350', method: 'sms_delete',
                               params: [ 'index', 'indexes', 'origin', 'id' ], expect: { '': {} } });

return view.extend({
	load: function() {
		return L.resolveDefault(callList(), { messages: [] });
	},

	renderInbox: function(d) {
		var msgs = d.messages || [];

		if (!msgs.length)
			return E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ E('em', {}, [ _('No messages in the modem store.') ]) ])
			]);

		var self = this;
		var rows = msgs.map(function(m) {
			// sms_tool emits an "error" variant for a PDU it could not decode. Showing it
			// as an explicit placeholder beats dropping it: a message you cannot read is
			// still evidence that something arrived.
			var body = m.error
				? E('em', { 'style': 'color:#a00' }, [ _('(could not decode: %s)').format(m.error) ])
				: E('span', { 'style': 'white-space:pre-wrap' }, [ m.content || '' ]);

			// A multipart message is reassembled by the backend, but say so - the store
			// counter reflects SEGMENTS, so "6 of 90 used" for one visible message is
			// correct and would otherwise look like a bug.
			var parts = null;
			if (m.total > 1) {
				parts = m.complete
					? E('span', { 'class': 'cbi-value-description' },
					    [ ' ' + _('(joined from %d parts)').format(m.total) ])
					// Incomplete groups are rendered, not hidden: a missing segment is
					// precisely when the reader needs to know the text is truncated.
					: E('strong', { 'style': 'color:#a00' },
					    [ ' ' + _('(incomplete: %d of %d parts)').format(m.parts, m.total) ]);
			}

			var idxList = (m.indexes && m.indexes.length) ? m.indexes.join(',') : String(m.index);

			// An archived message lives in the router's saved file, not the modem store; mark
			// it so the reader knows why it survives a full store, and so the delete path knows
			// to rewrite the archive instead of issuing an AT+CMGD.
			var when = [ m.timestamp || E('em', {}, [ '—' ]) ];
			if (m.origin === 'archived')
				when.push(E('span', { 'class': 'cbi-value-description' }, [ ' ' + _('(archived)') ]));

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '18%' }, [ m.sender || E('em', {}, [ '—' ]) ]),
				E('td', { 'class': 'td left', 'width': '22%' }, when),
				E('td', { 'class': 'td left' }, [ body, parts || '' ]),
				E('td', { 'class': 'td right', 'width': '8%' }, [
					E('button', {
						'class': 'btn cbi-button-remove',
						'click': ui.createHandlerFn(self, 'handleDelete', m, idxList)
					}, [ _('Delete') ])
				])
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, [ _('From') ]),
					E('th', { 'class': 'th left' }, [ _('Received') ]),
					E('th', { 'class': 'th left' }, [ _('Message') ]),
					E('th', { 'class': 'th right' }, [ '' ])
				])
			].concat(rows))
		]);
	},

	renderContent: function(d) {
		var storage = null;
		if (d.used !== null && d.used !== undefined && d.total) {
			var pct = Math.round((d.used / d.total) * 100);
			// Surfaced because a full store stops accepting messages SILENTLY - there is
			// no notification, they simply never arrive.
			storage = E('p', { 'class': 'cbi-value-description' }, [
				_('Modem store: %d of %d used (%d%%).').format(d.used, d.total, pct),
				pct >= 80 ? E('strong', { 'style': 'color:#a00' }, [
					' ' + _('Nearly full — delete messages or new ones will be rejected without warning.')
				]) : '',
				// archived_count is always present once h5000m-sms-archive is installed (0 when
				// its store is empty or it is disabled) - shown whenever it is a number so the
				// router-side count is visible from the page it actually affects, without a
				// second trip to the Archive settings page just to see whether it is doing
				// anything.
				(d.archived_count !== null && d.archived_count !== undefined)
					? E('span', {}, [ ' ' + _('%d message(s) held in the router\'s SMS archive.').format(d.archived_count) ])
					: ''
			]);
		}

		return E('div', {}, [ storage || '', this.renderInbox(d) ]);
	},

	refresh: function() {
		var self = this;
		return this.load().then(function(d) {
			dom.content(self.container, self.renderContent(d));
		});
	},

	// A persistent banner shown while a delete is in flight and after it resolves. It lives in
	// its own box (this.deleteBanner), NOT inside the inbox container that refresh() rebuilds,
	// so it survives the follow-up sms_list re-read. `spinning` is the in-progress state; the
	// final states (success/partial/unknown) replace it and stay put.
	showBanner: function(msg, kind, spinning) {
		var cls = 'alert-message' + (kind ? ' ' + kind : '');
		var body = spinning
			? [ E('span', { 'class': 'spinning' }, [ ' ' + msg ]) ]
			: [ msg ];
		dom.content(this.deleteBanner, E('div', { 'class': cls }, body));
	},

	clearBanner: function() {
		dom.content(this.deleteBanner, '');
	},

	// `indexes` is the comma-separated list of every storage slot a LIVE message occupies.
	// Deleting only the slot that was clicked would orphan the other segments, and a
	// partially-deleted multipart message can never be reassembled. An ARCHIVED message has no
	// modem slots - it is deleted from the router's saved file by id, with no AT interaction.
	handleDelete: function(m, indexes, ev) {
		var self = this;
		var archived = (m.origin === 'archived');
		var parts = m.total || 1;
		var note = archived
			? _('It is removed from the router\'s saved archive and cannot be recovered.')
			: (parts > 1)
				? _('This message spans %d storage slots; all of them are removed.').format(parts)
				: _('It is removed from the modem store and cannot be recovered.');

		return ui.showModal(_('Delete this message?'), [
			E('p', {}, [ note ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(this, function() {
						// Close the modal and raise a PERSISTENT banner immediately - not a
						// spinner that dies with the modal. A live delete serialises on the
						// shared AT port and does one AT transaction per part, so it can take
						// real seconds; the banner explains the wait instead of looking hung.
						ui.hideModal();
						var waitMsg = archived
							? _('Removing the archived message…')
							: (parts > 1)
								? _('Deleting %d parts. The AT port is shared with the dialer keeping the uplink up, so each part can queue behind it — this may take a few seconds per part.').format(parts)
								: _('Deleting the message. The AT port is shared with the dialer keeping the uplink up, so this can briefly queue behind it.');
						self.showBanner(waitMsg, 'info', true);

						var call = archived
							? callDelete(null, null, 'archived', m.id)
							: callDelete(null, indexes, 'live', null);

						// The banner must survive until BOTH the RPC resolves AND the follow-up
						// refresh lands, because the store count from sms_list is what actually
						// proves the delete happened. So finalise inside refresh().then.
						return call.then(function(res) {
							return self.refresh().then(function() {
								if (res && res.ok === false && res.failed) {
									// The state the user most needs to know: leftover segments
									// mean the message can never be reassembled again. This is
									// exactly what a naive per-slot delete used to cause silently.
									self.showBanner(
										_('Some parts could not be deleted (slots %s). The message is now incomplete and cannot be reassembled.')
											.format((res.failed || []).join(', ')),
										'danger', false);
								} else if (res && res.ok === false) {
									self.showBanner(
										_('The message could not be deleted: %s')
											.format((res.error || '') + ''),
										'danger', false);
								} else {
									var freed = (res && res.deleted) || parts;
									self.showBanner(
										_('Deleted — %d storage slot(s) freed.').format(freed),
										'success', false);
									// Success is transient news; clear it so it does not linger
									// over an inbox that already reflects the deletion.
									window.setTimeout(function() { self.clearBanner(); }, 5000);
								}
							});
						}, function() {
							// The RPC itself rejected - rpcd timeout, or the port wedged so the
							// reply was lost. A delete whose reply never came back may well have
							// SUCCEEDED, so do NOT report failure. Re-read and tell the truth:
							// the outcome is unknown and the list has been refreshed.
							return self.refresh().then(function() {
								self.showBanner(
									_('The delete request did not return a result — the AT port may be busy. The message list has been re-read; check whether the message is gone before trying again.'),
									'warning', false);
							});
						});
					})
				}, [ _('Delete') ])
			])
		]);
	},

	handleSend: function(ev) {
		var self = this;
		var number = document.getElementById('fm350-sms-number').value;
		var text = document.getElementById('fm350-sms-text').value;

		if (!number || !text) {
			ui.addNotification(null, E('p', _('Both a number and a message are required.')), 'danger');
			return;
		}

		return callSend(number, text).then(function(r) {
			if (r && r.ok) {
				ui.addNotification(null, E('p', _('Message sent.')), 'info');
				document.getElementById('fm350-sms-text').value = '';
				return self.refresh();
			}
			ui.addNotification(null, E('p', [
				_('Send failed.'), ' ', E('code', {}, [ (r && r.output) || (r && r.error) || '' ])
			]), 'danger');
		});
	},

	render: function(d) {
		this.container = E('div');
		dom.content(this.container, this.renderContent(d));

		// Delete-progress banner, kept OUTSIDE this.container so refresh() rebuilding the inbox
		// does not wipe it mid-delete. Empty until a delete is started.
		this.deleteBanner = E('div');

		return E([], [
			E('h2', {}, [ _('SMS') ]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Send a message') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('To') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', { 'type': 'text', 'id': 'fm350-sms-number',
						             'class': 'cbi-input-text', 'placeholder': '10086' })
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Message') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('textarea', { 'id': 'fm350-sms-text', 'class': 'cbi-input-textarea',
						                'rows': 3, 'style': 'width:100%' })
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('div', { 'class': 'cbi-value-field' }, [
						E('button', {
							'class': 'btn cbi-button-action important',
							'click': ui.createHandlerFn(this, 'handleSend')
						}, [ _('Send') ])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Inbox') ]),
				E('button', {
					'class': 'btn',
					'click': ui.createHandlerFn(this, 'refresh')
				}, [ _('Refresh') ])
			]),

			this.deleteBanner,
			this.container
		]);
	},

	// No polling here on purpose. Listing messages is a full AT conversation over the same
	// port the dialer needs, and unlike signal strength an inbox does not change second to
	// second. Refresh is explicit.
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
