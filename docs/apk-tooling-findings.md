# apk v3 tooling — verified behaviour

Empirically established against the real `apk` binary shipped in the OpenWrt ImageBuilder
(`staging_dir/host/bin/apk`, **apk-tools 3.0.5, x86_64**) on 2026-07-26, before writing any
pipeline code. Everything here was *run*, not inferred from docs.

Reproduce inside the amd64 builder container **as uid 0**:
`docker run --rm --platform linux/amd64 --user 0:0 -v "$IB:/ib:ro" <builder-image> sh -c '…'`

## Signing

| Question | Answer |
|---|---|
| Is `--sign` a valid abbreviation of `--sign-key`? | **Yes.** Both `--sign priv.pem` and `--sign-key priv.pem` produce a signed package (335 B signed vs 236 B unsigned for the same payload). OpenWrt's own Makefiles pass `--sign`, and that is safe. |
| Does `mkndx` sign the index? | **Yes** — `--sign-key` on `mkndx` produces a signed `packages.adb`. |
| Package/index container magic | `41 44 42 64` = **`ADBd`** for both `.apk` and `packages.adb`. |

## Verification

`apk verify` accepts **both package files and indexes** — the man page says "package files",
but an index verifies fine. So the pipeline *can* assert index signatures directly.

| Case | Result |
|---|---|
| signed pkg + correct `--keys-dir` | `signed.apk: OK` (exit 0) |
| signed pkg + **empty** `--keys-dir` | `UNTRUSTED signature` (exit 1) |
| **unsigned** pkg + correct keys-dir | `UNTRUSTED signature` (exit 1) |
| **index** + correct keys-dir | `packages.adb: OK` (exit 0) |

The negative cases genuinely fail, so they are usable as CI negative controls.

## ⚠️ `--keys-dir` must be an ABSOLUTE path

A **relative** `--keys-dir` silently fails to resolve and every input is reported
`UNTRUSTED signature` — with no hint that the path was the problem. This cost one debugging
cycle. Always pass an absolute path.

> This also explains why OpenWrt's `package/Makefile` passes `--allow-untrusted` to
> `mkndx`: `mkndx` verifies its *input* packages against the trust store. That flag is
> **input-side only** and is not an install-time relaxation — do not "clean it up".

## Superset indexes work — the two-repo model is viable

The key risk for shipping upstream indexes byte-identical while carrying only a subset of
`.apk` files. Tested with an index listing 2 packages where only 1 `.apk` was present:

- Installing the **present** package: `(1/1) Installing pkgkeep (1.0) / OK` — **succeeds**.
- Requesting the **absent** package fails cleanly and legibly:
  `ERROR: pkggone-1.0: package mentioned in index not found (try 'apk update')`.

So we can ship official `packages.adb` files verbatim (≈1.4 MB total) alongside only the
closure's `.apk` files, and the device verifies **OpenWrt's own signatures** end to end.
No need for the merged-index fallback (which would have required re-attesting ~200 upstream
packages under our key).

## Other flags

- **`--no-network` is accepted** (`--network[=BOOL]` supports the `--no-` negation).
  Still run the offline verification in a `--network none` container — a kernel-level
  guarantee beats an apk-level promise.
- **`apk add --root` requires root**, else: `ERROR: Use --usermode to allow creating
  database as non-root`. `--usermode` changes what is being tested, so
  `verify-offline-install.sh` should run as **uid 0 inside the container** rather than use it.
- `mkndx` also offers `--filter-spec PKGNAME_SPEC` and `--cache-max-age`.

## Testing note

Piping apk's output into `tail` masks its exit status — `$?` then reflects `tail`. Use
`${PIPESTATUS[0]}`, or capture output to a file and test the status directly. The findings
above were read from the `ERROR:`/`OK:` lines, which are unambiguous.
