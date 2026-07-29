# openwrt-H5000M-plugins

Custom OpenWrt package feed for the **Hiveton H5000M** (MediaTek filogic router with a
**Fibocom FM350-GL** cellular modem). These packages are built with the official OpenWrt SDK
and installed onto the base image produced by the sibling repo **`openwrt-H5000M`**. The
canonical device/AT reference is `openwrt-H5000M/FM350-GL-SETUP.md`.

## The device
`192.168.10.1`, root SSH **key auth works** (no password needed). It is a **recoverable test
device** — you may run diagnostics *and* sensitive/destructive operations on it directly
(reflash, reboot, AT writes, modem reset). This supersedes any older "never touch
192.168.10.1" posture.

## Package layout (`package/`)
- `h5000m-fm350` — the cellular uplink: netifd proto (`fm350.sh`), `fm350-dialer`,
  `fm350-radio` (band/RAT/cell/SIM-slot), and `fm350-watchdog.sh` (dead-bearer recovery ladder).
- `h5000m-modem-atd` — the AT layer: `atio.sh` (locking + exec), `atq` (the AT CLI),
  `fm350-usb-reset`, `modem-discover.sh`, `log.sh`. Everything else depends on this.
- `h5000m-sms`, `h5000m-sms-archive`, `h5000m-lpac` (eSIM), `h5000m-ttl`,
  `h5000m-mwan3-policy`, `h5000m-tailscale-defaults`, `h5000m-travelmate-defaults`,
  `luci-app-fm350`, `luci-proto-fm350`.

## The shared AT port is the scarcest resource
One physical AT port; **nobody holds it across transactions**. All AT access goes through
`atio.sh`'s `at_locked` / `at_locked_batch` (the `atq` CLI is the sanctioned entry point;
`atq -b` batches many commands under one lock). Never open a `ttyUSB` node directly.
`AT_PRIO` tiers (higher wins, approximate — flock has no ordering): dialer 30, sms/esim 20,
`atq`/default 10, sms-archive 5, LuCI status poll 1. **Never run `AT+COPS=?`** casually — it
blocks the port for minutes.

## Helper libraries (`/usr/lib/h5000m`, sourced)
- `atio.sh` — `at_locked`/`at_locked_batch`/`at_exec`, `at_lockfile`, `at_state_load`
  (exports `MODEM_USBPATH`/`MODEM_AT_A`/`MODEM_AT_A_IF`/`MODEM_NETDEV`…), `at_reg_ok`/`at_reg_denied`.
- `log.sh` — printf-style `log_error/warn/info/debug/trace`, `h5000m_log_init <comp> <tag>`;
  levels/overrides read from UCI `h5000m.logging`.
- `modem-discover.sh` — sysfs discovery (VID `0e8d`/PID `7127`) → writes the modem state file.
- `fm350-watchdog.sh` — the data-path probe + `re-dial → modem-reset → reboot` ladder.

## Hard rules (enforced by `tests/test-plugin-invariants.sh`, ~52 static checks)
- **POSIX `sh` only** — no bashisms. `#!/bin/sh`, no `local` (the codebase uses `_`-prefixed
  vars instead).
- **No `set -u` in netifd proto commands** — `/lib/functions.sh` dereferences unset vars and
  would kill a sourced proto script; netifd respawns it, so that's a restart storm.
- **No hard-coded `ttyUSB`/`eth` names** — use `$MODEM_AT_*` / `$MODEM_NETDEV` from
  `at_state_load`. Node names renumber.
- **No wall-clock deadlines** — this board has **no RTC** and sysntpd steps the clock the
  moment the link comes up, so a `date +%s` deadline computed beforehand is already in the past
  afterwards. Use **decrementing counters** (the house style) or `/proc/uptime`, never `date`.
- Persistent state = **named files** under `/etc/h5000m` listed in `lib/upgrade/keep.d`
  (per-file, not the whole dir — `h5000m-sms-archive` owns the directory form).

## Modem facts worth not re-learning
- `cid 1` is **IMS** by design on China Telecom; the internet context is a modem-chosen `aid`
  activated via `AT+EAPNACT` (not `CGACT=1,1`). RNDIS bridges **exactly one** active context.
- The modem keeps advertising a **stale `CGPADDR` after the carrier drops the bearer** — the
  whole reason `fm350-watchdog.sh` exists (probe the data path, don't trust the address).

## Tests & build
- Tests are **hand-rolled POSIX-shell** assertion suites (+ one `ucode` suite), every check
  **negative-controlled** (inject the violation, confirm the test fails). Run `sh tests/test-*.sh`.
- CI (`.github/workflows/build.yml`): `bash -n` syntax over `scripts/*.sh tests/*.sh`, the
  invariants suite, the "Repo self-tests" step (add new shell tests here), a secret scan, then
  SDK fetch/configure/build and a signed offline apk repo + install verification.
- Local build: `scripts/fetch-official-sdk.sh` → `configure-sdk.sh` → `build-packages.sh`.
  `sdk/` is a large working dir.
