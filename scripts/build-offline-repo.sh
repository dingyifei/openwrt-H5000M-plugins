#!/usr/bin/env bash
# build-offline-repo.sh — assemble the SIGNED offline plugin repository.
#
# Collects the exact dependency closure: our custom/source-built APKs PLUS the official
# feed APKs the features need (travelmate, mwan3, tailscale, openconnect, lpac, and the
# full FM350 modem driver set). Official APKs are COPIED in as-is and their OpenWrt
# signatures verified — never rebuilt, never --allow-untrusted.
#
# Contract:
#   in:  ./bin (built pkgs), configs/packages.lock (resolved closure), official feed APKs
#   out: ./offline-repo/ with a signed packages.adb, SHA256SUMS, provenance, INSTALL.md
#   fail: any APK whose signature does not verify against an accepted trust root
set -euo pipefail
cd "$(dirname "$0")/.."

echo "TODO: resolve closure from configs/packages.lock (fail on any unpinned dep)."
echo "TODO: verify EVERY apk signature (official OpenWrt key for feed pkgs; H5000M key for"
echo "      ours). Reject unsigned/untrusted. NEVER pass --allow-untrusted."
echo "TODO: build + SIGN packages.adb with the persistent key."
echo "TODO: emit SHA256SUMS, provenance (revision/SDK/feed hashes, per-pkg refs), INSTALL.md"
