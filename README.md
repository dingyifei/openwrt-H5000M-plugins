# openwrt-H5000M-plugins

Signed APK **plugin** build/delivery pipeline for the Hiveton **H5000M** — the sibling to
[`openwrt-H5000M`](../openwrt-H5000M) (the clean official ImageBuilder base).

## Why this repo exists

The base repo stays a pure official OpenWrt ImageBuilder base (`custom_plugins_included=false`,
no feature packages). This repo builds the **feature layer** as separately-built, **signed**
APK packages that install onto that base — offline, with trust verification, and versioned
independently of the base image.

Two kinds of packages ship from here:

1. **Custom "glue" packages** (authored here, exist nowhere else): H5000M-specific defaults
   and policy — e.g. `h5000m-travelmate-defaults`, `h5000m-mwan3-policy`, `h5000m-egress`,
   FM350 first-boot config.
2. **Source-built third-party packages** not in the official feeds: **PassWall2** (wrapper/UI)
   and **luci-app-epm** (eSIM Profile Manager UI, with the runtime/MBIM patch).

Everything else the feature stack needs — travelmate, mwan3, tailscale, openconnect, lpac,
and the **entire FM350 modem driver stack** — is already in the **official OpenWrt feeds**,
pre-signed by OpenWrt. Those are pulled in as-is (copied into the signed offline repo,
signature-verified), **not** rebuilt. See `../openwrt-H5000M/docs/phase2-package-availability.md`.

## Hard rules (inherited from the base project)

- Never `--allow-untrusted`. Every APK is signature-verified before indexing/install.
- The plugin signing key is **persistent** and lives **outside git** (`~/.config/h5000m-apk/`).
  The firmware's embedded trust anchor pins its fingerprint. Ephemeral SDK keys are
  development-only and their artifacts are marked non-publishable.
- No baked secrets (Wi-Fi/eSIM/VPN/Tailscale/proxy credentials, live daemon state).
- Rolling for the OpenWrt snapshot (SDK/feeds tracked live, integrity-checked against the
  mirror's `sha256sums`); still **pin external SOURCES** (our source-built packages) by
  repo/commit/hash in `configs/sources.lock`. Base + plugins must share one snapshot.

## Layout

```
configs/
  openwrt-sdk.env      # SDK URL/SHA256 + revision/target/arch/kernel/ABI (matches the base)
  sources.lock         # external source repo/commit/hash/license per source-built package
  packages.lock        # resolved APK name/version/arch/sha256/deps closure
package/               # custom glue package recipes (Makefiles + files/)
patches/luci-app-epm/  # EPM runtime/MBIM patch (must apply at --fuzz=0)
scripts/
  fetch-official-sdk.sh      # fetch + hash-verify the exact official SDK
  configure-sdk.sh           # package-only SDK config (no image profile)
  build-packages.sh          # deterministic build of custom pkgs with the persistent key
  build-offline-repo.sh      # collect closure, verify sigs, sign packages.adb, emit provenance
  verify-offline-install.sh  # unpack the exact base sysupgrade, simulate install offline
  check-secrets.sh           # secret scan over repo/pkgs/rootfs/index
tests/                 # mocked-UCI / state-machine / package tests
.github/workflows/build.yml
```

## Build flow

1. `scripts/fetch-official-sdk.sh` — fetch the SDK pinned in `configs/openwrt-sdk.env`.
2. `scripts/configure-sdk.sh` — configure it for package builds only.
3. `scripts/build-packages.sh` — build custom + source-built packages, signed.
4. `scripts/build-offline-repo.sh` — assemble the signed offline repo (custom + verified
   official packages), with checksums/provenance/install instructions.
5. `scripts/verify-offline-install.sh` — install into the exact base artifact, network cut.

## Status — ✅ pipeline working, milestone M1 verified (2026-07-26)

The full chain is implemented and **proven against the real base image**
(`r35533-3b2bc55dcb`, kernel 6.18.39):

```
INSTALL (network cut, no --allow-untrusted)
  (1/5) iwinfo  (2/5) rpcd-mod-rpcsys  (3/5) travelmate
  (4/5) luci-app-travelmate            (5/5) h5000m-travelmate-defaults
POSITIVE OK: closure matches; anchors only
NEGATIVE CONTROLS (each must fail)
  [PASS] empty keys-dir · [PASS] corrupted .apk
  [PASS] untrusted signer · [PASS] absent package     (4/4)
M1 VERIFICATION PASSED
```

Our signed package installs alongside OpenWrt-signed packages into the exact base rootfs,
offline, using only the firmware's embedded trust anchors — and the trust checks are
demonstrably real, not decorative.

**Rolling model** (chosen 2026-07-25). No SDK/feed pinning or tarball preservation:
`fetch-official-sdk.sh` pulls the current SDK and checks it against the mirror's own
`sha256sums`; `configure-sdk.sh` pins the 5 feeds per-run from the snapshot's
`feeds.buildinfo` (the `base` feed is already commit-pinned in `feeds.conf.default`).
**Build the base and these plugins from the same snapshot in one run** so kmods/deps agree
(this feature set builds no kmods, so ABI risk is minimal).

Verified apk behaviour — including the gotcha that a *relative* `--keys-dir` silently
reports everything `UNTRUSTED` — is in [`docs/apk-tooling-findings.md`](docs/apk-tooling-findings.md).

### Usage

```sh
./scripts/fetch-official-sdk.sh                              # fetch + verify the SDK
./scripts/build-in-container.sh scripts/configure-sdk.sh     # feeds, key gate, seeded .config
./scripts/build-in-container.sh scripts/build-packages.sh    # build + sign + verify
export H5000M_BASE_ARTIFACT=../openwrt-H5000M/artifacts/H5000M-official-base-<rev>
./scripts/build-in-container.sh --mount-base scripts/build-offline-repo.sh travelmate
./scripts/build-in-container.sh --network none --mount-base \
    scripts/verify-offline-install.sh travelmate             # M1 gate
```

Substitute any feature-set name for `travelmate`: `cellular`, `esim`, `tailscale`,
`mwan3`, or `all` (see `configs/feature-sets.conf`).

## Stage 2 — feature packages (updated 2026-07-27)

Eleven config/script-only packages, all `PKGARCH:=all`, no credentials:

| Package | Provides |
|---|---|
| `h5000m-modem-atd` | FM350 AT broker: sysfs discovery, `atq`, `at-lease`, `modem-ports`, hotplug rules |
| `h5000m-fm350` | netifd proto `fm350` + dialer + IMSI→APN table + `cellular` interface + `fm350-radio` band/cell/slot guard |
| `h5000m-lpac` | `h5000m-esim` — lpac over its AT backend, under the port lease |
| `h5000m-sms` | `h5000m-sms` — `sms_tool` under the port lease; no PDU codec of our own |
| `h5000m-sms-archive` | FIFO-archives the oldest modem SMS to the router past a configurable threshold, deletes them from the modem, and covers the archive in every config backup; **off by default** |
| `luci-proto-fm350` | LuCI handler so the `cellular` interface is editable in the web UI |
| `luci-app-fm350` | Network → FM350: status, cells, SMS, SMS archive settings, band lock, TTL and recovery actions |
| `h5000m-ttl` | pins the cellular egress TTL/hop-limit via fw4; **off by default** |
| `h5000m-travelmate-defaults` | the `trm_wwan` DHCP interface + wan-zone membership; reaps an SSID-less orphan STA |
| `h5000m-tailscale-defaults` | `tailscale0` firewall zone, shipped logged out |
| `h5000m-mwan3-policy` | wan → trm_wwan → cellular failover, public-IP tracking |

Three host-side suites, all negative-controlled — injecting each violation makes them fail
(exact counts drift as checks are added; `tests/README.md` is the source of truth):

`tests/test-plugin-invariants.sh` (52 checks) enforces rules learned the hard way on
hardware: no `proto_set_keep 1`, no hard-coded `ttyUSB`/`eth` names, no `flock -w`
(busybox has no such flag), no `set -u` in a netifd proto command, no bashisms, no
credentials, no anonymous `wifi-iface` sections, LuCI protocol handlers must `return` the
registered class, rpcd backends must take no direct serial access, set `AT_PRIO=1`,
live in `/usr/share/rpcd/ucode`, and reload rpcd in postinst, and every UCI config an rpcd
backend writes must be granted in that same package's own ACL.

`tests/test-log-library.sh` (21 checks) unit-tests the logging library with `uci` and
`logger` stubbed, so it needs no device. The redaction assertions grep for the actual
IMSI/EID/ICCID/PDU rather than for the mask — a privacy control has to be proven, not
eyeballed.

`tests/test-travelmate-defaults.sh` (19 checks) runs the Travelmate uci-defaults against a
stateful `uci` stub. Its load-bearing assertion is that a **real configured uplink survives
untouched**: the previous version of that script matched any STA on `trm_wwan` and deleted its
SSID and key, so a package upgrade would have disabled a working uplink.

### Build cost: why these packages use `EXTRA_DEPENDS`

Our glue packages compile nothing — they are shell scripts in a tarball. But declaring a
runtime dependency the obvious way, `DEPENDS:=+travelmate`, makes kconfig **`select`** that
package, which makes the SDK **build it from source**: `tailscale` drags in a full Go
toolchain build, `lpac` drags in `libmbim` → `gnutls` → `nettle` → `gmp`. All of it is then
discarded, because what we actually ship is OpenWrt's official binary. That cost ~50
minutes of CI and was the cause of the local `configure: error: cannot run /bin/bash
./config.sub` failure — a toolchain problem in a dependency we never wanted built.

`EXTRA_DEPENDS` writes the dependency straight into the package metadata at pack time
(`include/package-pack.mk`) and never triggers a `select`. Measured: dependency compiles
drop to **zero**.

The catch, and the reason a first attempt failed: OpenWrt rejects unversioned entries with
*"Extra dependencies must have version constraints"*. Reading the check, it is simply
`$(word 2,...)` — it only asks that a second word exist, not that the constraint be
meaningful. So `travelmate (>=0)` satisfies it while constraining nothing, which is what we
want under a rolling snapshot. Note the **space before `(`** is mandatory; the same macro
errors out without it. Precedent: `EXTRA_DEPENDS:=ucode (>=2022.03.22)` in `firewall4`.

This trades a compile-time guarantee for an install-time one, so the closure is no longer
proven by the build — it is proven by `verify-offline-install.sh`, which resolves the real
closure into the actual rootfs with `--network none` and asserts it equals
`configs/packages.lock`. If the metadata were wrong, that gate fails.

### Known-good vs not-yet-proven

- ✅ Proven on hardware: AT discovery, `atq`/denylist, APN programming, proto registration,
  Travelmate/Tailscale uci-defaults (idempotent over three runs, `fw4 check` clean).
- ✅ **Cell locking** via `AT+EMMCHLCK` (2026-07-28), LTE only — the RAT field accepts
  `0,2,7`, so the NR form circulating online is rejected here. Verified: lock to the serving
  cell (data at 91 ms), lock to a nonexistent PCI (65 s unregistered, **reverted itself**),
  and unlock restoring both the lock *and* the RAT. ⚠️ **The command is absent from
  `AT+CLAC`** — CLAC is a lower bound, not an inventory.
- ✅ **Band locking, verified including the failure path** (2026-07-28). Locking LTE to B3
  applied and carried data; locking LTE-only to B14 — no coverage here — spent 45 s
  unregistered and then **reverted itself**, restoring the link without intervention.
  `atq` refuses `AT+GTACT=`/`AT+GTDUALSIM=` writes (rc 4) while still allowing the `AT+GTACT=?`
  capability read (rc 0), so the guard cannot be bypassed.
- ✅ **Multipart SMS reassembly**, against a real six-segment Chinese message whose segments
  arrived in slots 1–6 as parts 6,3,2,4,5,1. Deleting the reassembled row removes all six
  slots in one request — a partial delete used to orphan the rest silently.
- ⚠️ **The SMS archive (`h5000m-sms-archive`) has a settings page (Network → FM350 → SMS
  Archive) but has never run an archive+delete pass against real messages.** Ships
  `enabled=0`; the merge/UI/backup plumbing is verified, but an actual archive cycle needs to
  be exercised on hardware — ideally against a throwaway message rather than a real inbox —
  before turning it on for normal use.
- ✅ **TTL**, verified on the wire with `tcpdump` at a distinctive value — not by reading
  `nft list`, whose counters prove traversal but not the value that actually leaves.
- ⚠️ **`AT+GTACT` is NOT reliably non-persistent**, despite the manual marking it so: an
  NR-only lock survived a full sysupgrade and reboot. Do not treat a power cycle as the escape
  hatch from a bad band lock; clear it explicitly.
- ⚠️ **A `+GTACT` value read from the modem may not be replayable** — it reports empty
  preference fields but refuses to accept one, so every revert path must sanitise before
  replaying. This was a live bug in the guard's revert, not a theoretical one.
- ⚠️ **`sms_tool` can hang holding the AT port**, taking the dialer down with it. Now bounded
  by `timeout` in the wrapper, with a shorter cap for deletes so a bad slot cannot exceed
  ubus's request budget.
- ⚠️ **The SIM-slot switch is NOT hardware-tested.** It is persistent in firmware, is known
  to break PDP activation until the APN type changes, and has previously half-killed the AT
  endpoint. Exercise it with physical access, never over the link it can take away.
- ⚠️ **`h5000m-ttl` disables flow offloading while enabled.** Offloaded flows never traverse
  postrouting, so only a flow's first packets would be rewritten — a mix of 64 and 63 on the
  wire fingerprints tethering just as well as no rewrite at all. Ships `enabled=0`, so the
  base image keeps offloading; `manage_offload=0` opts out of the interaction.
- ✅ **All six packages build and the cellular closure verifies end to end.** With
  `EXTRA_DEPENDS` the dependency source-builds vanish: each package compiles in 5-10s, and
  the `config.sub` toolchain failure went away with the chain that caused it.
  `verify-offline-install.sh cellular` installs the full 13-package closure - including the
  ABI-locked kmods, `464xlat`, `kmod-nat46` and `coreutils-stty` - into the exact base
  rootfs with `--network none` and no `--allow-untrusted`, all 4 negative controls failing
  as required.
- ⚠️ **`EXTRA_DEPENDS` names are not validated at build time.** They are a free-form
  string, so a typo (`travelmatee (>=0)`) builds cleanly and only fails at install. The
  only thing that catches it is `verify-offline-install.sh` - and only for feature sets we
  actually verify. **Verify the `all` set in CI** so every package's dependencies are
  exercised, or this hole stays open for the unverified ones.
- ✅ **Cellular works end to end and comes up unattended at boot.** The earlier note here
  said attach was blocked by the SIM — that was true of the SIM then fitted and is no
  longer the situation. See `../openwrt-H5000M/FM350-GL-SETUP.md` for what actually made
  it work: exactly one active PDP context, `+EAPNACT` rather than `+CGACT`, and `arp off`
  on the RNDIS netdev.
- ✅ **AT priority, batch mode, logging and the web UI verified on hardware.** Priority 30
  waited 1 s against five competing pollers where priority 1 waited 11 s; `atq -b` runs
  four commands in 1.07 s under one lock; trace-level redaction was checked against the
  real 15-digit IMSI; all seven `luci.fm350` ubus methods answer with live data.
- ⚠️ **The eUICC exists but lpac cannot reach it.** `AT+EID` returns a real EID and the
  card reports `EMPTY_EUICC`, but `AT+CCHO` to the ISD-R AID is refused on both SIM slots
  and the `at_csim` backend is not compiled into the packaged lpac.

### Usage

```sh
modem-ports                              # discovered ports and the data netdev
modem-ports --rescan                     # re-probe after a re-enumeration
atq 'AT+CSQ'                             # one AT command
atq -b 'AT+CESQ' 'AT+COPS?'              # several, under ONE lock acquisition
atq 'AT+GTACT?'                          # current RAT + band configuration
atq -t 12 'AT+GTCCINFO?'                 # serving + neighbour cells
fm350-usb-reset                          # recover a deaf AT port (detached, ~70s)

# Band/slot changes NEVER go through atq - it refuses them - because they must be
# verified and reverted if the link does not come back.
printf 'ACTION=band\nRAT=20\nBANDS="103"\nPERSIST=0\n' > /var/run/fm350-radio.req
# cell lock: an empty CELL_ARFCN clears it (and restores any RAT the lock narrowed)
printf 'ACTION=cell\nCELL_ARFCN=1650\nCELL_PCI=187\nCELL_LTE_ONLY=1\nPERSIST=0\n' > /var/run/fm350-radio.req
/etc/init.d/fm350-radio start            # apply, verify against DATA, revert on failure
cat /var/run/fm350-radio.state           # applying|verifying|reverting|ok|failed|reverted
at-lease lpac chip info                  # hand the port to a foreign tool
h5000m-sms -j recv                       # inbox as JSON
h5000m-sms send 10086 '余额'              # send

uci set h5000m.sms_archive.enabled=1     # turn on the FIFO archiver (also: Network > FM350 >
uci commit h5000m                        # SMS Archive - the LuCI page just edits this same UCI)

uci set h5000m.logging.fm350=trace       # error|warn|info|debug|trace, per component
uci commit h5000m                        # long-lived processes need a restart to notice
h5000m-log-capture 120 fm350=trace       # bounded capture to /tmp, reverted on exit
```

### Next

Third-party source builds (PassWall2 and friends) remain deferred; `configs/sources.lock`
is empty and `build-packages.sh` fails loudly if it is not. The in-feed `luci-app-v2raya`
covers the proxy case without one.
