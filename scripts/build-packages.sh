#!/usr/bin/env bash
# build-packages.sh — deterministic build of the custom + source-built packages, signed
# with the persistent key. Never uses an ephemeral key for publishable artifacts.
#
# Contract:
#   in:  configured ./sdk (configure-sdk.sh), package/*, patches/*, configs/sources.lock
#   out: signed APKs under ./bin, recorded into configs/packages.lock
#   rules: pin every external source to sources.lock (repo/commit/hash); EPM patch --fuzz=0
set -euo pipefail
cd "$(dirname "$0")/.."

echo "TODO: for each source-built pkg (passwall2 wrapper, luci-app-epm), fetch pinned"
echo "      source per configs/sources.lock and verify hash before build."
echo "TODO: (cd sdk && make package/h5000m-travelmate-defaults/compile V=s) etc."
echo "TODO: apply patches/luci-app-epm at --fuzz=0 (fail on fuzz)."
echo "TODO: sign built APKs with the persistent key; record name/version/arch/sha256 ->"
echo "      configs/packages.lock"
