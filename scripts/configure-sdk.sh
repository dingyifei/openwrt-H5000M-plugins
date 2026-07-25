#!/usr/bin/env bash
# configure-sdk.sh — package-only SDK configuration. Sets up feeds and the persistent
# signing key; does NOT select an image profile or unrelated packages.
#
# Contract:
#   in:  ./sdk (from fetch-official-sdk.sh), configs/openwrt-sdk.env, the persistent
#        signing key at ${H5000M_APK_KEY:-~/.config/h5000m-apk/private-key.pem}
#   out: ./sdk configured to build the recipes in package/ + the source-built feeds
#   fail: if the key fingerprint != H5000M_PLUGIN_KEY_SHA256 in openwrt-sdk.env
set -euo pipefail
cd "$(dirname "$0")/.."
. configs/openwrt-sdk.env

echo "TODO: wire feeds.conf (official feeds for deps + local package/), then:"
echo "  (cd sdk && ./scripts/feeds update -a && ./scripts/feeds install -a)"
echo "TODO: verify signing key fingerprint == \$H5000M_PLUGIN_KEY_SHA256 (fail otherwise)"
echo "TODO: make defconfig with ONLY the custom + source-built packages selected =m"
