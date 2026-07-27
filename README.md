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

Nine config/script-only packages, all `PKGARCH:=all`, no credentials:

| Package | Provides |
|---|---|
| `h5000m-modem-atd` | FM350 AT broker: sysfs discovery, `atq`, `at-lease`, `modem-ports`, hotplug rules |
| `h5000m-fm350` | netifd proto `fm350` + dialer + IMSI→APN table + `cellular` interface |
| `h5000m-lpac` | `h5000m-esim` — lpac over its AT backend, under the port lease |
| `h5000m-sms` | `h5000m-sms` — `sms_tool` under the port lease; no PDU codec of our own |
| `luci-proto-fm350` | LuCI handler so the `cellular` interface is editable in the web UI |
| `luci-app-fm350` | Network → FM350: status, SMS, and recovery actions |
| `h5000m-travelmate-defaults` | one disabled STA VIF → `trm_wwan` |
| `h5000m-tailscale-defaults` | `tailscale0` firewall zone, shipped logged out |
| `h5000m-mwan3-policy` | wan → trm_wwan → cellular failover, public-IP tracking |

Two host-side suites, both negative-controlled — injecting each violation makes them fail:

`tests/test-plugin-invariants.sh` (31 checks) enforces rules learned the hard way on
hardware: no `proto_set_keep 1`, no hard-coded `ttyUSB`/`eth` names, no `flock -w`
(busybox has no such flag), no `set -u` in a netifd proto command, no bashisms, no
credentials, no anonymous `wifi-iface` sections, LuCI protocol handlers must `return` the
registered class, and rpcd backends must take no direct serial access, set `AT_PRIO=1`,
live in `/usr/share/rpcd/ucode`, and reload rpcd in postinst.

`tests/test-log-library.sh` (21 checks) unit-tests the logging library with `uci` and
`logger` stubbed, so it needs no device. The redaction assertions grep for the actual
IMSI/EID/ICCID/PDU rather than for the mask — a privacy control has to be proven, not
eyeballed.

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
at-lease lpac chip info                  # hand the port to a foreign tool
h5000m-sms -j recv                       # inbox as JSON
h5000m-sms send 10086 '余额'              # send

uci set h5000m.logging.fm350=trace       # error|warn|info|debug|trace, per component
uci commit h5000m                        # long-lived processes need a restart to notice
h5000m-log-capture 120 fm350=trace       # bounded capture to /tmp, reverted on exit
```

### Next

Third-party source builds (PassWall2 and friends) remain deferred; `configs/sources.lock`
is empty and `build-packages.sh` fails loudly if it is not. The in-feed `luci-app-v2raya`
covers the proxy case without one.
