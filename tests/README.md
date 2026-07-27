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

## `test-plugin-invariants.sh` — 31 static checks

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
  reload rpcd in postinst.

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

## `test-sms-grouping.uc` — 21 unit tests (runs on the router)

Concatenated-SMS reassembly, exercised against the shapes that actually occurred:

- a six-part Chinese message whose **storage order is not part order** — measured on this unit
  as parts 6,3,2,4,5,1 in slots 1–6. Sorting by slot yields `FCBDEA` instead of `ABCDEF`;
- two messages from the same sender with the **same timestamp** and different concat
  references, which is why the grouping key is `(sender, reference, total)`. Keying on
  timestamp instead — what `luci-app-sms-tool-js` does — fails 8 assertions here, splitting
  the real message into four fragments *and* merging two unrelated ones into `AXBY`;
- an incomplete group, which must still render rather than disappear;
- a standalone message, which carries no concat fields at all.

It loads the **real** backend and swaps its export line, rather than duplicating the function —
a copy would drift and then pass while the shipped code was broken.

```sh
scp -r package tests root@192.168.10.1:/tmp/t/
ssh root@192.168.10.1 'cd /tmp/t && ucode tests/test-sms-grouping.uc /tmp/t'
```

It is **not** in host CI, and that is deliberate rather than an oversight: the backend does
`import ... from 'ubus'` so compiling it needs libubus, and there is no `ucode` package in
Ubuntu 24.04 (checked — `packages.ubuntu.com/noble/ucode` is a 404). Making it "skip" on the
host was rejected because a skipped test reads exactly like a passing one, which is the failure
mode this repo has already been bitten by.

## Still worth writing

- mwan3 policy: member ordering, no hard-coded `eth2`, `tailscale0` excluded
- egress selector: all six transitions, invalid state, rollback, mark disjointness
