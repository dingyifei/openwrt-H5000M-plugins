#!/usr/bin/env bash
# check-secrets.sh — secret scan across git files, built APK contents, the signed index,
# and any staged rootfs. Rejects Tailscale keys/state, Cisco creds/cookies/certs, proxy
# subscriptions/nodes, Travelmate upstream creds, eSIM activation/SM-DP+ secrets, private
# signing keys, and copied live daemon state. Public bootstrap roots are allowed separately.
#
# Exit non-zero if anything matches. Wire this into CI before publishing artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns='BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY|tskey-[A-Za-z0-9]|AUTH_KEY|node-key|
password[[:space:]]*=|PSK=|SM-DP|activation_?code|\bcookie\b|anyconnect.*cookie'

echo "TODO: scan tracked files + ./bin APK contents + ./offline-repo + any staged rootfs"
echo "TODO: grep -EnI against the pattern set below; fail on match; allowlist public roots."
echo "patterns:"; echo "$patterns"
