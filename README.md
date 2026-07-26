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

### Next

Add feature sets (Tailscale, FM350, mwan3) to `configs/feature-sets.conf` plus their glue
packages — each is now a config edit rather than new machinery. Third-party source builds
(`luci-app-epm`, PassWall2) remain deferred; `configs/sources.lock` is empty and
`build-packages.sh` fails loudly if it is not.
