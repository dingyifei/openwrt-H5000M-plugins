#!/usr/bin/env bash
# Negative + positive tests for scripts/check-plugin-signing-key.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${ROOT_DIR}/scripts/check-plugin-signing-key.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plugin-signing-key.XXXXXX")"
# Canonicalize: on macOS ${TMPDIR} lives under /var -> /private/var (a symlink), which would
# otherwise trip the script's legitimate "path contains a symlink" check.
WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_keypair() {
  local directory="$1"
  mkdir -m 0700 "${directory}"
  openssl ecparam -name prime256v1 -genkey -noout -out "${directory}/private-key.pem" 2>/dev/null
  openssl pkey -in "${directory}/private-key.pem" -pubout -out "${directory}/public-key.pem" 2>/dev/null
  chmod 0600 "${directory}/private-key.pem"
  chmod 0644 "${directory}/public-key.pem"
}

# release mode: a freshly generated key does not match the pinned anchor -> reject.
fresh="${WORK_DIR}/fresh"
make_keypair "${fresh}"
if H5000M_APK_KEY_MODE=release "${CHECK}" "${fresh}" >/dev/null 2>&1; then
  fail "release mode accepted a key that does not match the pinned anchor"
fi

# release mode: over-permissive private key -> reject (even before the fingerprint check).
wrong_mode="${WORK_DIR}/wrong-mode"
make_keypair "${wrong_mode}"
chmod 0644 "${wrong_mode}/private-key.pem"
if H5000M_APK_KEY_MODE=release "${CHECK}" "${wrong_mode}" >/dev/null 2>&1; then
  fail "over-permissive private key was accepted"
fi

# release mode: missing key pair -> reject.
missing="${WORK_DIR}/missing"
mkdir -m 0700 "${missing}"
if H5000M_APK_KEY_MODE=release "${CHECK}" "${missing}" >/dev/null 2>&1; then
  fail "missing key pair was accepted"
fi

# release mode: symlinked signing dir -> reject.
real="${WORK_DIR}/real"
make_keypair "${real}"
link="${WORK_DIR}/link"
ln -s "${real}" "${link}"
if H5000M_APK_KEY_MODE=release "${CHECK}" "${link}" >/dev/null 2>&1; then
  fail "symlinked signing directory was accepted"
fi

# release mode: mismatched private/public pair -> reject.
mismatched="${WORK_DIR}/mismatched"
make_keypair "${mismatched}"
other="${WORK_DIR}/other"
make_keypair "${other}"
cp "${other}/public-key.pem" "${mismatched}/public-key.pem"
if H5000M_APK_KEY_MODE=release "${CHECK}" "${mismatched}" >/dev/null 2>&1; then
  fail "mismatched private/public keypair was accepted"
fi

# dev mode: the fingerprint check is skipped, so a well-formed non-pinned key is ACCEPTED.
devdir="${WORK_DIR}/dev"
make_keypair "${devdir}"
if ! H5000M_APK_KEY_MODE=dev "${CHECK}" "${devdir}" >/dev/null 2>&1; then
  fail "dev mode rejected a well-formed keypair"
fi

# dev mode: an over-permissive private key is STILL rejected (mode checks are not relaxed).
devbad="${WORK_DIR}/dev-bad"
make_keypair "${devbad}"
chmod 0644 "${devbad}/private-key.pem"
if H5000M_APK_KEY_MODE=dev "${CHECK}" "${devbad}" >/dev/null 2>&1; then
  fail "dev mode accepted an over-permissive private key"
fi

printf 'plugin signing-key tests passed.\n'
