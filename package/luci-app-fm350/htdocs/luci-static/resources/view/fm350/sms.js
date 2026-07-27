'use strict';
'require view';
'require rpc';
'require dom';
'require ui';

// FM350 SMS inbox and composer.
//
// sms_tool (from the official feed) already decodes PDU mode, UCS2 and multipart
// reassembly, so nothing here parses a PDU. The backend runs it under the AT-port lease so
// reading the inbox cannot desynchronise the dialer.

var callList   = rpc.declare({ object: 'luci.fm350', method: 'sms_list', expect: { '': {} } });
var callSend   = rpc.declare({ object: 'luci.fm350', method: 'sms_send',
                               params: [ 'number', 'text' ], expect: { '': {} } });
var callDelete = rpc.declare({ object: 'luci.fm350', method: 'sms_delete',
                               params: [ 'index', 'indexes' ], expect: { '': {} } });

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

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '18%' }, [ m.sender || E('em', {}, [ '—' ]) ]),
				E('td', { 'class': 'td left', 'width': '22%' }, [ m.timestamp || E('em', {}, [ '—' ]) ]),
				E('td', { 'class': 'td left' }, [ body, parts || '' ]),
				E('td', { 'class': 'td right', 'width': '8%' }, [
					E('button', {
						'class': 'btn cbi-button-remove',
						'click': ui.createHandlerFn(self, 'handleDelete', idxList, m.total || 1)
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
				]) : ''
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

	// `indexes` is the comma-separated list of every storage slot this message occupies.
	// Deleting only the slot that was clicked would orphan the other segments, and a
	// partially-deleted multipart message can never be reassembled.
	handleDelete: function(indexes, parts, ev) {
		var self = this;
		var note = (parts > 1)
			? _('This message spans %d storage slots; all of them are removed.').format(parts)
			: _('It is removed from the modem store and cannot be recovered.');

		return ui.showModal(_('Delete this message?'), [
			E('p', {}, [ note ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(this, function() {
						return callDelete(null, indexes).then(function(res) {
							ui.hideModal();
							if (res && res.ok === false)
								ui.addNotification(null, E('p', {}, [
									_('Some segments could not be deleted: %s')
										.format((res.failed || []).join(', '))
								]), 'danger');
							return self.refresh();
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
