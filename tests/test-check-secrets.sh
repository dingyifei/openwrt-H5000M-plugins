#!/usr/bin/env bash
# Tests for scripts/check-secrets.sh: base categories plus the plugin extensions
# (Tailscale / eSIM / baked UCI credentials / binary payload scan / official allowlist).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER_SOURCE="${ROOT_DIR}/scripts/check-secrets.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-secrets.XXXXXX")"
WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"
REPO_DIR="${WORK_DIR}/repository"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

require_line() {
  printf '%s\n' "$2" | grep -Fqx -- "$1" || fail "missing finding $1"
}

mkdir -p "${REPO_DIR}/scripts"
cp "${SCANNER_SOURCE}" "${REPO_DIR}/scripts/check-secrets.sh"
chmod +x "${REPO_DIR}/scripts/check-secrets.sh"
git -C "${REPO_DIR}" init -q

# Match the real repo: build outputs are gitignored, so only the explicit pass-2 walk sees them.
printf '/offline-repo/\n/bin/\n' > "${REPO_DIR}/.gitignore"

# Split literals so THIS test file never trips the scanner scanning its own repo.
private_part='PRI''VATE'
public_part='PUB''LIC'
proxy_scheme='vl''ess'
provider_prefix='g''h'
known_provider="${provider_prefix}p_abcdefghijklmnopqrstuvwxyz1234567890"
tailscale_key='tsk''ey-auth-abcdef0123456789'
node_key='node''key:deadbeefdeadbeefdeadbeef'
# Quote-break so this file's own source never contains the contiguous activation-code literal
# (avoid self-match); the assembled value has the real dollar-separated LPA activation shape.
esim_code='LPA:1'"$"'smdp.example.com'"$"'MATCHING-ID-12345'
assignment_name='API_TOKEN'
literal_value='literal-credential-material'

git -C "${REPO_DIR}" add .gitignore scripts/check-secrets.sh
git -C "${REPO_DIR}" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures

# --- positive fixtures (tracked in git => pass 1) ---
printf '%s\n%s\n' "-----BEGIN ${private_part} KEY-----" 'redacted' > "${REPO_DIR}/tracked-private.pem"
printf '%s\n' "${proxy_scheme}://123e4567-e89b-12d3-a456-426614174000@example.invalid:443" > "${REPO_DIR}/proxy.txt"
printf '%s\n' "${known_provider}" > "${REPO_DIR}/provider.txt"
printf '%s=%s\n' "${assignment_name}" "${literal_value}" > "${REPO_DIR}/env.sh"
printf 'opaque\n' > "${REPO_DIR}/creds.p12"
printf '%s\n' "${tailscale_key}" > "${REPO_DIR}/tailscale.txt"
printf '%s\n' "${node_key}" > "${REPO_DIR}/nodekey.txt"
printf '%s\n' "${esim_code}" > "${REPO_DIR}/esim.txt"

# baked upstream credential inside a package payload tree
mkdir -p "${REPO_DIR}/package/h5000m-x/files/etc/config"
printf "config wifi-iface\n\toption key 'supersecretpsk123'\n" > "${REPO_DIR}/package/h5000m-x/files/etc/config/travelmate"

# --- binary payload fixtures (gitignored => pass 2 only) ---
mkdir -p "${REPO_DIR}/offline-repo/h5000m/pkgs" "${REPO_DIR}/offline-repo/official/feed"
printf 'ADBd\0-----BEGIN %s KEY-----\0payload' "${private_part}" > "${REPO_DIR}/offline-repo/h5000m/pkgs/evil.apk"
# same secret under the official allowlist must be IGNORED
printf 'ADBd\0-----BEGIN %s KEY-----\0payload' "${private_part}" > "${REPO_DIR}/offline-repo/official/feed/upstream.apk"
printf 'clean provenance\n' > "${REPO_DIR}/offline-repo/h5000m/PROVENANCE.txt"

# --- allowed / benign fixtures that must NOT be reported ---
printf '%s\n' "-----BEGIN ${public_part} KEY-----" > "${REPO_DIR}/safe-public.pem"
printf '%s: %s\n' "${assignment_name}" '${{ secrets.API_TOKEN }}' > "${REPO_DIR}/ci-reference.yml"
printf 'ROOT_PASSWORD=root\nWIFI_PASSWORD=77778888\n' > "${REPO_DIR}/public-bootstrap.env"
# bare SM-DP+ spec mention (no matching id) must not be flagged
printf 'The SM-DP+ server address is configured by the carrier.\n' > "${REPO_DIR}/esim-doc.md"

set +e
result="$("${REPO_DIR}/scripts/check-secrets.sh" "${REPO_DIR}")"
status=$?
set -e
[ "${status}" -eq 1 ] || fail "scanner status was ${status}, expected 1"

require_line 'private-key:tracked-private.pem:1' "${result}"
require_line 'proxy-uri:proxy.txt:1' "${result}"
require_line 'provider-token:provider.txt:1' "${result}"
require_line 'sensitive-assignment:env.sh:1' "${result}"
require_line 'credential-filename:creds.p12:1' "${result}"
require_line 'plugin-secret:tailscale.txt:1' "${result}"
require_line 'plugin-secret:nodekey.txt:1' "${result}"
require_line 'plugin-secret:esim.txt:1' "${result}"
require_line 'baked-credential:package/h5000m-x/files/etc/config/travelmate:2' "${result}"
require_line 'binary-secret:offline-repo/h5000m/pkgs/evil.apk:1' "${result}"

# secret VALUES must never appear in output
case "${result}" in
  *supersecretpsk123*|*"${known_provider}"*|*"${tailscale_key}"*|*MATCHING-ID*|*"${literal_value}"*)
    fail "scanner output exposed a matched value" ;;
esac

# allowlisted / benign fixtures must be absent
case "${result}" in
  *offline-repo/official/*|*safe-public.pem*|*ci-reference.yml*|*public-bootstrap.env*|*esim-doc.md*)
    fail "scanner reported an allowlisted, public, or benign fixture" ;;
esac

# --- clean sweep: remove every positive, expect exit 0 and no findings ---
rm -f \
  "${REPO_DIR}/tracked-private.pem" "${REPO_DIR}/proxy.txt" "${REPO_DIR}/provider.txt" \
  "${REPO_DIR}/env.sh" "${REPO_DIR}/creds.p12" "${REPO_DIR}/tailscale.txt" \
  "${REPO_DIR}/nodekey.txt" "${REPO_DIR}/esim.txt"
rm -rf "${REPO_DIR}/package" "${REPO_DIR}/offline-repo/h5000m"

set +e
clean_result="$("${REPO_DIR}/scripts/check-secrets.sh" "${REPO_DIR}")"
clean_status=$?
set -e
[ "${clean_status}" -eq 0 ] || fail "scanner reported findings after removing positives: ${clean_result}"
[ -z "${clean_result}" ] || fail "scanner emitted findings for allowed fixtures: ${clean_result}"

printf 'check-secrets tests passed.\n'
