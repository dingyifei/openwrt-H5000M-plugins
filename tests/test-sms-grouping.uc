// Unit tests for the shared SMS grouping module
// (package/h5000m-modem-atd/files/usr/share/ucode/h5000m/sms_grouping.uc).
//
// Concatenated-SMS reassembly is pure data transformation, so it is testable without a modem.
// The tests below are the cases that actually bit, not hypotheticals:
//
//   - a six-part Chinese message whose STORAGE INDEX ORDER IS NOT PART ORDER (measured on this
//     unit as parts 6,3,2,4,5,1 in slots 1..6) - the case that would silently scramble text;
//   - two different messages from the same sender, distinguished only by `reference`, which is
//     why the grouping key must not be (sender, timestamp);
//   - segments whose SMSC timestamps differ, which is the normal case and the reason
//     luci-app-sms-tool-js's timestamp-keyed grouping is fragile;
//   - an incomplete group, which must still render rather than vanish;
//   - a standalone message, which carries no reference/part/total at all;
//   - the timestamp comparator, since the live view sorts newest-first and the archiver
//     oldest-first through this ONE function, and the format is NOT lexically sortable.
//
// The module is a pure library (no fs, no ubus) loaded exactly the way the real consumers
// load it - loadfile() then call - so the test exercises the shipped artifact, not a copy
// that could drift and pass while the real code was broken.
//
// Usage: ucode tests/test-sms-grouping.uc [repo-root]
//
// ⚠️ WHERE THIS RUNS: anywhere the `ucode` binary exists - the router, or a dev box with
// ucode installed. It no longer needs libubus (the old version loaded the whole rpcd backend,
// which imports 'ubus'); the pure module compiles standalone. There is still no `ucode`
// package in Ubuntu 24.04 or on macOS, so host CI runs it only where ucode is available.
// Rather than let the suite "skip" - which reads exactly like a pass, and this repo has
// already shipped one vacuous test - the dependency is stated plainly. Run it with:
//
//   scp -r package tests root@<router>:/tmp/t/ && ssh root@<router> \
//     'cd /tmp/t && ucode tests/test-sms-grouping.uc /tmp/t'

let root = length(ARGV) > 0 ? ARGV[0] : '.';
let mod_path = `${root}/package/h5000m-modem-atd/files/usr/share/ucode/h5000m/sms_grouping.uc`;

let factory = loadfile(mod_path);
if (!factory) {
	warn(`cannot load ${mod_path}\n`);
	exit(1);
}
let mod = factory();
let group_messages = mod.group_messages;
let cmp_timestamp = mod.cmp_timestamp;

let checks = 0, fails = 0;
function ok(msg) { checks++; print(`  [PASS] ${msg}\n`); }
function bad(msg) { checks++; fails++; print(`  [FAIL] ${msg}\n`); }
function eq(got, want, msg) {
	if (got == want) ok(msg);
	else bad(`${msg} (got ${got}, want ${want})`);
}

print("== six-part message, storage order != part order ==\n");
// Exactly the shape observed: reference 10, total 6, parts 6,3,2,4,5,1 in slots 1..6.
let six = [
	{ index: 1, sender: '106598731', timestamp: '07/27/26 23:30:19', reference: 10, part: 6, total: 6, content: 'F' },
	{ index: 2, sender: '106598731', timestamp: '07/27/26 23:30:20', reference: 10, part: 3, total: 6, content: 'C' },
	{ index: 3, sender: '106598731', timestamp: '07/27/26 23:30:19', reference: 10, part: 2, total: 6, content: 'B' },
	{ index: 4, sender: '106598731', timestamp: '07/27/26 23:30:21', reference: 10, part: 4, total: 6, content: 'D' },
	{ index: 5, sender: '106598731', timestamp: '07/27/26 23:30:19', reference: 10, part: 5, total: 6, content: 'E' },
	{ index: 6, sender: '106598731', timestamp: '07/27/26 23:30:18', reference: 10, part: 1, total: 6, content: 'A' }
];
let r = group_messages(six);
eq(length(r), 1, 'six segments collapse to one message');
eq(r[0].content, 'ABCDEF', 'segments are joined in PART order, not storage order');
eq(r[0].parts, 6, 'part count reported');
eq(r[0].total, 6, 'total reported');
eq(r[0].complete, true, 'complete group flagged complete');
eq(length(r[0].indexes), 6, 'every storage slot retained for delete');
// Without all six indexes, Delete orphans the rest and the message can never be reassembled.
// Compared as a joined string rather than relying on ucode's array formatting.
let idxs = sort(r[0].indexes, function(a, b) { return a - b; });
eq(join(',', idxs), '1,2,3,4,5,6', 'indexes cover all six slots');

print("== same sender, same timestamp, DIFFERENT reference ==\n");
// The case timestamp-keyed grouping gets wrong: two messages merge into one.
let two = [
	{ index: 1, sender: '10086', timestamp: 'T', reference: 10, part: 1, total: 2, content: 'A' },
	{ index: 2, sender: '10086', timestamp: 'T', reference: 77, part: 1, total: 2, content: 'X' },
	{ index: 3, sender: '10086', timestamp: 'T', reference: 10, part: 2, total: 2, content: 'B' },
	{ index: 4, sender: '10086', timestamp: 'T', reference: 77, part: 2, total: 2, content: 'Y' }
];
r = group_messages(two);
eq(length(r), 2, 'distinct references stay distinct messages');
eq(r[0].content, 'AB', 'first message joined correctly');
eq(r[1].content, 'XY', 'second message joined correctly');

print("== incomplete group ==\n");
let partial = [
	{ index: 1, sender: 'S', timestamp: 'T', reference: 5, part: 1, total: 3, content: 'A' },
	{ index: 2, sender: 'S', timestamp: 'T', reference: 5, part: 3, total: 3, content: 'C' }
];
r = group_messages(partial);
eq(length(r), 1, 'incomplete group is still returned, not dropped');
eq(r[0].complete, false, 'incomplete group flagged incomplete');
eq(r[0].parts, 2, 'reports how many parts arrived');
eq(r[0].total, 3, 'reports how many were expected');

print("== standalone message ==\n");
let single = [ { index: 9, sender: 'S', timestamp: 'T', content: 'hello' } ];
r = group_messages(single);
eq(length(r), 1, 'standalone passes through');
eq(r[0].content, 'hello', 'standalone content preserved');
eq(r[0].complete, true, 'standalone is complete');
eq(r[0].indexes[0], 9, 'standalone still exposes an indexes list for delete');

print("== a segment that failed to decode ==\n");
let broken = [
	{ index: 1, sender: 'S', timestamp: 'T', reference: 3, part: 1, total: 2, content: 'A' },
	{ index: 2, sender: 'S', timestamp: 'T', reference: 3, part: 2, total: 2, error: 'error decoding pdu' }
];
r = group_messages(broken);
eq(length(r), 1, 'group with a bad segment still returned');
eq(r[0].complete, false, 'a group containing an undecodable segment is not complete');

print("== empty input ==\n");
r = group_messages([]);
eq(length(r), 0, 'empty list yields no messages');

print("== cmp_timestamp orders chronologically, not lexically ==\n");
// The trap: as strings, "12/01/25" < "07/27/26", but Dec 2025 is EARLIER than Jul 2026.
eq(cmp_timestamp('12/01/25 08:00:00', '07/27/26 23:30:19') < 0, true,
   'Dec 2025 sorts before Jul 2026 despite lexical order saying otherwise');
eq(cmp_timestamp('07/27/26 23:30:19', '07/27/26 23:30:18') > 0, true,
   'later second sorts after earlier second');
eq(cmp_timestamp('07/27/26 23:30:19', '07/27/26 23:30:19') == 0, true,
   'identical timestamps compare equal');
eq(cmp_timestamp('03/09/26 05:00:00', '03/10/26 04:00:00') < 0, true,
   'earlier day sorts first even when its clock time is later');
// Unparseable input must not throw - deterministic fallback, null before any string.
eq(cmp_timestamp(null, 'anything') < 0, true, 'null timestamp sorts before a string, no crash');

print(`\nchecks=${checks} failures=${fails}\n`);
if (fails > 0)
	exit(1);
print("ALL SMS GROUPING TESTS PASSED\n");
