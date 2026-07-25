#!/usr/bin/env bash
# verify-offline-install.sh — prove the offline repo installs into the EXACT base artifact
# with networking disabled and only the firmware's embedded trust store.
#
# Contract:
#   in:  ./offline-repo (build-offline-repo.sh), the base sysupgrade image for the SAME
#        pinned revision (from ../openwrt-H5000M artifacts)
#   out: pass/fail; a log of resolved+installed packages
#   method: unpack the base rootfs, point apk at ./offline-repo only, network cut, install
#           the feature set, assert every package resolves + signature-verifies.
#   rules: no network; no --allow-untrusted; revision/arch/kernel/ABI must match the base.
set -euo pipefail
cd "$(dirname "$0")/.."
. configs/openwrt-sdk.env

echo "TODO: locate the base sysupgrade for $OPENWRT_REVISION and assert arch/kernel/ABI match."
echo "TODO: unpack rootfs; run apk in an offline root with only ./offline-repo configured."
echo "TODO: install the feature set; assert all resolve + verify; dump the installed list."
