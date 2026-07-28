# tests

Host-runnable, no hardware. Run both before every push:

```sh
bash tests/test-plugin-invariants.sh
sh   tests/test-log-library.sh
sh   tests/test-travelmate-defaults.sh
```

One further suite needs a ucode interpreter and therefore runs **on the router**, not on the
host — see `test-sms-grouping.uc` below.

All three host suites are **negative-controlled** — every assertion was checked by injecting the
violation and confirming the suite fails. That habit exists because this repo has already shipped a
test that passed vacuously: it compared two empty files, because `uci show` with multiple
arguments writes nothing.

## `test-plugin-invariants.sh` — 52 static checks

Every rule exists because the corresponding mistake was actually made, not as hypothetical
hygiene:

- no `proto_set_keep 1` — it leaves a stale address attached across a renumber and kills
  the uplink silently;
- no hard-coded `ttyUSB`/`eth` names — they renumber on re-enumeration;
- no `flock -w` — busybox has no such flag, and using it read as "AT port busy";
- no `set -u` in a netifd proto command — `/lib/functions.sh` dereferences an unset
  variable, and netifd respawns whatever exits, so it becomes a restart storm;
- no bashisms (the base ships busybox ash), no credential material;
- no anonymous `wifi-iface` sections — they trigger LuCI's wireless-migration dialog,
  which restarts the network to fix them;
- LuCI protocol handlers must `return network.registerProtocol(...)` — without the
  `return` the page dies with "factory yields invalid constructor", and `node --check`
  passes it, because that is a contract violation rather than a syntax error;
- rpcd backends must take no direct serial access, must set `AT_PRIO=1`, must live in
  `/usr/share/rpcd/ucode` rather than the exec-plugin directory, and their Makefile must
  reload rpcd in postinst;
- **no wall-clock deadlines.** This board has no RTC, so sysntpd steps the clock during early
  boot — inside the dialer's own 120 s modem wait. A `$(date +%s) + N` deadline computed before
  the step is already in the past after it, and the loop exits instantly with `NO_MODEM` +
  `proto_block_restart`. Five loops shipped that way; count down instead;
- **the USB `authorized` window must be signal-isolated** — run from rpcd's process group, an
  `/etc/init.d/rpcd restart` mid-window strands the modem at `authorized=0` until a power cycle;
- **every LuCI resource module must `return` a class** built with `.extend(`. A bare object
  literal gives `"factory yields invalid constructor"` and kills every page that requires it.
  This trap was hit **twice** — first `protocol/fm350.js` with no `return`, then
  `resources/fm350/progress.js` returning an object literal — because the original check was
  written to the shape of the first bug rather than to the rule it broke;
- **a dotted require must name its alias.** LuCI derives an un-aliased name as
  `dep.replace(/[^a-zA-Z0-9_]/g,'_')`, so `'require fm350.progress'` binds `fm350_progress`,
  not `progress`, and every page dies at first use with a `ReferenceError`;
- **never pass `null` as a declared rpc argument.** ubus types each argument from the backend's
  exemplar and rejects a null outright, so the call never reaches the backend at all — SMS
  delete silently never ran. The check is anchored with `[^)]*` so it stays inside the call's
  own parens: the first version flagged `L.resolveDefault(callX(), null)`, where the null
  belongs to `resolveDefault`. A check that cries wolf on correct code is worse than none;
- a `procd_set_param respawn`, where present, must carry three numeric args — a wrong count
  silently changes respawn behaviour and shows up only as a service that never comes back
  (the check validates the form, it does not force respawn: fm350-radio deliberately omits it);
- the SMS archiver must never call sms_tool `delete all` (a broken 0..49 sweep that would also
  wipe not-yet-archived messages) and must run at its own `AT_PRIO=5` tier;
- shared ucode libraries under `usr/share/ucode/` take no direct `/dev/tty` access, same ban as
  the rpcd backends but a separate check (a pure library has no `AT_PRIO` to set);
- every `/lib/upgrade/keep.d/*` entry is an absolute path and never under `/tmp` or `/var`
  (tmpfs, wiped each boot) — the one property the SMS archive's persistence depends on;
- every UCI config an rpcd backend `uci set`s must appear in that package's own ACL
  `write.uci` — otherwise the write fails silently for any session but root's full-trust
  one. Caught for real: `archive_set` landed a `uci set h5000m.sms_archive.*` call a commit
  before the ACL was extended to grant `h5000m` at all.

The shell-syntax check skips files whose shebang is `ucode`: they are not POSIX sh, and `sh -n`
would reject valid ucode. Their syntax is exercised on-target instead.

## `test-log-library.sh` — 21 unit tests

Exercises `/usr/lib/h5000m/log.sh` with `uci` and `logger` stubbed: level filtering, the
`log_want` predicate, repeat collapsing and its cap, format safety, and redaction.

The redaction assertions grep for the **actual** IMSI, EID, ICCID and PDU values rather
than for the mask — a privacy control has to be proven absent, not observed to look right.
The suite also asserts short values (`+CESQ: 99,99,...`, `OK`) are *not* mangled, since
over-redaction would make the logs useless.

## `test-travelmate-defaults.sh` — 19 unit tests

Runs the Travelmate `uci-defaults` script against a **stateful** `uci` stub (unlike the
read-only stub in `test-log-library.sh`, this one applies set/delete/add_list so the state the
script leaves behind can be inspected) with `logger` captured to a file.

The script used to *create* a disabled, SSID-less STA VIF as a placeholder for Travelmate to
fill in. It never gets filled: Travelmate's `f_setif()` matches a section's **existing** SSID
against its uplink list and never writes one, so the placeholder resolved `enabled=0` forever
and LuCI rendered it as the blank "SSID: ?" client. The script now removes that orphan instead,
guarded so a real uplink is never touched. The suite pins that behaviour:

- running twice leaves identical state (idempotent) and creates **zero** `wifi-iface` sections;
- a **real configured uplink** (`mode=sta`, `network=trm_wwan`, with an SSID and key) survives
  **untouched** — this is the load-bearing assertion, because the SSID guard is the entire
  safety of the change (the negative control deletes the uplink the moment that guard is dropped);
- an SSID-less orphan (absent *or* empty SSID) is removed and logged exactly once;
- an AP (`mode=ap`) and a foreign-network STA (`network!=trm_wwan`) are never touched;
- `network.trm_wwan` (DHCP) and its `wan`-zone membership are still established, without
  clobbering an existing zone member.

Every assertion is negative-controlled by mutating the script in one specific way and confirming
that assertion — and only the expected ones — flips to FAIL (recreate the placeholder; drop each
of the three delete guards; suppress the delete; suppress the log; skip the plumbing; break
idempotency by making the `add_list` unconditional).

## `test-sms-grouping.uc` — 26 unit tests (needs a ucode interpreter)

Concatenated-SMS reassembly, exercised against the shapes that actually occurred:

- a six-part Chinese message whose **storage order is not part order** — measured on this unit
  as parts 6,3,2,4,5,1 in slots 1–6. Sorting by slot yields `FCBDEA` instead of `ABCDEF`;
- two messages from the same sender with the **same timestamp** and different concat
  references, which is why the grouping key is `(sender, reference, total)`. Keying on
  timestamp instead — what `luci-app-sms-tool-js` does — merges two unrelated messages;
- an incomplete group, which must still render rather than disappear;
- a standalone message, which carries no concat fields at all;
- a segment that failed to decode, which is never dropped;
- the `cmp_timestamp` comparator, which the live view (newest-first) and the archiver
  (oldest-first) both sort through. The `MM/DD/YY` format is **not** lexically sortable —
  "12/01/25" is chronologically before "07/27/26" but sorts after it as a string — so the
  comparator parses the fields; the tests pin that, plus a null-timestamp fallback that must
  not throw.

It targets the **shared module** (`h5000m-modem-atd/.../usr/share/ucode/h5000m/sms_grouping.uc`)
the way the real consumers do — `loadfile()` then call — rather than duplicating the function,
which would drift and then pass while the shipped code was broken. The backend and the archive
worker both load this same file, so the one test covers all three.

```sh
scp -r package tests root@<router>:/tmp/t/
ssh root@<router> 'cd /tmp/t && ucode tests/test-sms-grouping.uc /tmp/t'
```

It is **not** in host CI, and that is deliberate rather than an oversight: there is no `ucode`
package in Ubuntu 24.04 (checked — `packages.ubuntu.com/noble/ucode` is a 404) or on macOS. Since
the module is now a pure library with no `ubus`/`fs` imports it no longer needs libubus, so it
runs anywhere a `ucode` binary exists — but making it "skip" when that binary is absent was
rejected, because a skipped test reads exactly like a passing one, the failure mode this repo has
already been bitten by.

## Still worth writing

- mwan3 policy: member ordering, no hard-coded `eth2`, `tailscale0` excluded
- egress selector: all six transitions, invalid state, rollback, mark disjointness
