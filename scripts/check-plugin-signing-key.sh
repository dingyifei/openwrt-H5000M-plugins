#!/usr/bin/env bash
# check-plugin-signing-key.sh — validate the persistent APK signing key before any build.
#
# Ported from ../openwrt-H5000M/scripts/check-plugin-signing-key.sh, extended with a
# release/dev key mode. All checks are fatal.
#
# Modes (H5000M_APK_KEY_MODE, default "release"):
#   release : signing dir defaults to ~/.config/h5000m-apk; the public-key fingerprint
#             MUST equal H5000M_PLUGIN_KEY_SHA256 in configs/openwrt-sdk.env (the firmware
#             trust anchor). This is the only key whose artifacts may be published.
#   dev     : signing dir defaults to ~/.config/h5000m-apk-dev; the fingerprint equality
#             check is SKIPPED (any well-formed keypair is accepted). A throwaway keypair is
#             generated on first use if the dir is empty. Artifacts built with a dev key are
#             marked non-publishable (configure-sdk.sh writes sdk/.h5000m-dev-key, which
#             build-offline-repo.sh refuses to publish from).
#
# Signing-dir resolution order: positional $1 > $H5000M_APK_SIGNING_DIR > mode default.
#
# Checks (all fatal): dir exists / not a symlink / no symlink in the resolved path /
# owner == current uid / dir mode 0700-or-stricter / both keys exist, are files, not
# symlinks, owned by current uid / private-key mode 0600-or-stricter / openssl pkey -check
# passes / public derived from private matches the shipped public key / (release) fingerprint
# equals the pinned anchor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../configs/openwrt-sdk.env
source "${ROOT_DIR}/configs/openwrt-sdk.env"

KEY_MODE="${H5000M_APK_KEY_MODE:-release}"
case "${KEY_MODE}" in
  release) DEFAULT_DIR="${HOME}/.config/h5000m-apk" ;;
  dev)     DEFAULT_DIR="${HOME}/.config/h5000m-apk-dev" ;;
  *) echo "Signing-key check failed: unknown H5000M_APK_KEY_MODE '${KEY_MODE}' (want release|dev)" >&2; exit 1 ;;
esac

SIGNING_DIR="${1:-${H5000M_APK_SIGNING_DIR:-${DEFAULT_DIR}}}"
PRIVATE_KEY="${SIGNING_DIR}/private-key.pem"
PUBLIC_KEY="${SIGNING_DIR}/public-key.pem"

fail() {
  echo "Signing-key check failed: $*" >&2
  exit 1
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

file_uid() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

public_fingerprint() {
  openssl pkey -pubin -in "$1" -pubout -outform DER 2>/dev/null | sha256_hex
}

private_fingerprint() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256_hex
}

# dev convenience: mint a throwaway keypair on first use so dev builds are turnkey.
if [ "${KEY_MODE}" = dev ] && [ ! -e "${PRIVATE_KEY}" ] && [ "${SIGNING_DIR}" = "${DEFAULT_DIR}" ]; then
  echo "dev mode: generating a throwaway signing key at ${SIGNING_DIR}" >&2
  ( umask 077; mkdir -p "${SIGNING_DIR}" )
  openssl ecparam -name prime256v1 -genkey -noout -out "${PRIVATE_KEY}" 2>/dev/null
  openssl pkey -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}" 2>/dev/null
  chmod 0600 "${PRIVATE_KEY}"
  chmod 0644 "${PUBLIC_KEY}"
fi

[ -d "${SIGNING_DIR}" ] || fail "missing signing directory: ${SIGNING_DIR}"
[ ! -L "${SIGNING_DIR}" ] || fail "signing directory must not be a symlink"
[ "$(cd "${SIGNING_DIR}" && pwd)" = "$(cd "${SIGNING_DIR}" && pwd -P)" ] || \
  fail "signing directory path contains a symlink"
[ "$(file_uid "${SIGNING_DIR}")" -eq "$(id -u)" ] || fail "signing directory has the wrong owner"
dir_mode="$(file_mode "${SIGNING_DIR}")"
[ $((8#${dir_mode} & 8#077)) -eq 0 ] || fail "signing directory permissions must be 0700 or stricter"

for key in "${PRIVATE_KEY}" "${PUBLIC_KEY}"; do
  [ -f "${key}" ] || fail "missing key: ${key}"
  [ ! -L "${key}" ] || fail "key must not be a symlink: ${key}"
  [ "$(file_uid "${key}")" -eq "$(id -u)" ] || fail "key has the wrong owner: ${key}"
done
private_mode="$(file_mode "${PRIVATE_KEY}")"
[ $((8#${private_mode} & 8#077)) -eq 0 ] || fail "private key permissions must be 0600 or stricter"

openssl pkey -in "${PRIVATE_KEY}" -check -noout >/dev/null 2>&1 || fail "private key validation failed"
openssl pkey -pubin -in "${PUBLIC_KEY}" -noout >/dev/null 2>&1 || fail "public key validation failed"

private_sha256="$(private_fingerprint "${PRIVATE_KEY}")"
public_sha256="$(public_fingerprint "${PUBLIC_KEY}")"
[ "${private_sha256}" = "${public_sha256}" ] || fail "private and public keys do not match"

if [ "${KEY_MODE}" = release ]; then
  [ "${public_sha256}" = "${H5000M_PLUGIN_KEY_SHA256}" ] || \
    fail "signing key does not match the pinned firmware trust anchor"
  printf 'Signing key matches pinned H5000M trust anchor: %s\n' "${public_sha256}"
else
  printf 'dev signing key OK (fingerprint check skipped): %s\n' "${public_sha256}"
fi
