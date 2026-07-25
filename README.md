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
- Pin everything: SDK, external sources, resolved package closure — reproducible offline build.

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

## Status

⛔ **Blocked on the SDK re-pin.** The base is pinned at snapshot r35420, whose SDK is no
longer downloadable (snapshots aren't archived). The base must first be re-pinned to a
current snapshot (see `../openwrt-H5000M` WS-D-pre) that ships a fetchable SDK; then
`configs/openwrt-sdk.env` here is filled with that revision + SDK SHA256. Scripts and
structure are revision-agnostic and ready.
