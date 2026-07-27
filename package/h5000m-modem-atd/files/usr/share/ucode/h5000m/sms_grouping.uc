// Shared SMS concatenation-grouping logic for the FM350 stack.
//
// WHY THIS LIVES IN h5000m-modem-atd, NOT h5000m-sms: three separate consumers need it -
// the LuCI rpcd backend (luci.fm350), the archive worker (h5000m-sms-archive) and the unit
// test - and luci-app-fm350 only SOFT-depends on h5000m-sms (EXTRA_DEPENDS, optional) while
// it HARD-depends on h5000m-modem-atd. A consumer loading a module that might not be
// installed would be a load-time fatal for the whole rpcd backend, so the one package every
// consumer is guaranteed to have is where the shared code has to sit.
//
// HOW IT IS LOADED: by loadfile() rather than `import`, e.g.
//     const grouping = loadfile('/usr/share/ucode/h5000m/sms_grouping.uc')();
//     grouping.group_messages(msgs);
// loadfile() runs the file and hands back this module's `return` value. That works
// identically in the rpcd VM, in a standalone `#!/usr/bin/ucode` worker script, and under a
// bare `ucode tests/...` invocation - none of which can be relied on to enable ES `import`
// of a source file. It is a pure library: no fs, no ubus, no I/O, so it compiles anywhere
// `ucode` exists, with no libubus and nothing to mock.

// Reassemble concatenated ("multipart") SMS.
//
// A GSM SMS carries 140 bytes. Chinese cannot be expressed in GSM 7-bit, so it goes out as
// UCS-2 at 2 bytes/char = 70 characters, and anything longer is SPLIT BY THE SENDER into
// segments carrying a User Data Header with a reference id, a part count and a sequence
// number. Reassembly is the receiver's job. sms_tool parses that UDH and exposes
// `reference`/`part`/`total` in -j output, but it never joins the segments - so one message
// showed up in the inbox as six rows, and Delete removed one of them, orphaning the rest.
//
// Group on (sender, reference, total). Deliberately NOT on timestamp: the SMSC stamps each
// segment separately and they routinely differ by a second or more. luci-app-sms-tool-js
// keys on sender-timestamp-total and drops `reference` entirely, which is exactly the
// fragile version of this.
//
// ⚠️ `reference` is only the LOW BYTE when the carrier uses a 16-bit concat reference (UDH
// IEI 0x08): sms_tool reads the last three UDH octets with no IEI dispatch and discards the
// MSB. That is fine as a grouping key within a single `recv` snapshot - which is all this is
// - but it must never be treated as globally unique or persisted as an id.
function group_messages(msgs) {
	const order = [];
	const groups = {};

	for (let m in msgs) {
		// sms_tool emits reference/part/total ONLY when the PDU carried a concat UDH, so a
		// missing `total` means genuinely standalone, not "unknown".
		if (!m.total || m.total < 2) {
			push(order, { single: m });
			continue;
		}
		const key = `${m.sender ?? ''}|${m.reference ?? 0}|${m.total}`;
		let g = groups[key];
		if (!g) {
			g = { segs: [], total: m.total, sender: m.sender, reference: m.reference };
			groups[key] = g;
			push(order, { group: g });   // preserve first-seen order for the inbox
		}
		push(g.segs, m);
	}

	const out = [];
	for (let entry in order) {
		if (entry.single) {
			const s = entry.single;
			push(out, {
				index: s.index, indexes: [ s.index ],
				sender: s.sender, timestamp: s.timestamp,
				content: s.content, error: s.error,
				parts: 1, total: 1, complete: true
			});
			continue;
		}

		const g = entry.group;
		// Sort by part. Storage index order is NOT part order - measured on this unit, a
		// six-part message arrived as parts 6,3,2,4,5,1 in slots 1..6. Relying on emission
		// order would silently scramble the text.
		sort(g.segs, function(a, b) { return (a.part ?? 0) - (b.part ?? 0); });

		let text = '';
		let bad = false;
		const idx = [];
		for (let s in g.segs) {
			if (s.error != null) bad = true;
			text += (s.content ?? '');
			push(idx, s.index);
		}

		const have = length(g.segs);
		push(out, {
			// `index` stays the first segment's slot so older callers still work; `indexes`
			// is what Delete must use, or the remaining segments are orphaned forever.
			index: idx[0], indexes: idx,
			sender: g.sender,
			timestamp: g.segs[0]?.timestamp,
			content: text,
			reference: g.reference,
			parts: have, total: g.total,
			complete: (have == g.total) && !bad,
			error: bad ? 'one or more segments failed to decode' : null
		});
	}
	return out;
}

// One comparator, shared so the live view (newest-first) and the archiver (oldest-first)
// order messages IDENTICALLY. Returns <0 if a is older than b, >0 if newer, 0 if equal.
//
// sms_tool's default timestamp is `MM/DD/YY HH:MM:SS` (measured: "07/27/26 23:30:19"), which
// is NOT lexically sortable across months or years - "12/01/25" sorts before "07/27/26" as a
// string but is chronologically earlier, and both are wrong relative to each other lexically.
// So parse it into a numeric YYYYMMDDHHMMSS key. Two-digit years are read as 2000+YY: this
// modem's epoch starts well after 2000 and there is no pre-2000 SMS to disambiguate against.
//
// If a string does not match that shape (a firmware that formats dates differently, or a
// missing timestamp) fall back to a plain lexical compare - degraded but deterministic, and
// the single place to add another format if hardware ever shows one.
function ts_key(s) {
	if (type(s) != 'string')
		return null;
	const m = match(s, /^\s*([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{2,4})\s+([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})/);
	if (!m)
		return null;
	let year = +m[3];
	if (year < 100) year += 2000;
	// Zero-pad by arithmetic so the components never collide across fields.
	return ((((year * 100 + (+m[1])) * 100 + (+m[2])) * 100 + (+m[4])) * 100 + (+m[5])) * 100 + (+m[6]);
}

function cmp_timestamp(a, b) {
	const ka = ts_key(a), kb = ts_key(b);
	if (ka != null && kb != null)
		return ka - kb;
	// One or both unparseable: deterministic lexical fallback. null sorts before any string.
	const sa = (type(a) == 'string') ? a : '';
	const sb = (type(b) == 'string') ? b : '';
	return (sa < sb) ? -1 : (sa > sb) ? 1 : 0;
}

return { group_messages, cmp_timestamp };
