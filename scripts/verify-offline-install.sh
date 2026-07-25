#!/usr/bin/env bash
# verify-offline-install.sh — prove the offline repo installs into the EXACT base rootfs with
# the network cut and only the firmware's embedded trust store, and prove the trust checks are
# real via four negative controls that MUST fail.
#
# Positive path (M1 gate):
#   * preconditions: base artifact SHA256SUMS verifies; BUILD-INFO arch/profile match the env;
#     the rootfs installed db carries kernel=<ver>~<abi>; both trust anchors are present.
#   * install the feature set with `apk add --root <rootfs> --keys-dir <ABS rootfs keys>
#     --repositories-file /dev/null --no-network -X <each offline-repo feed>` — no network, no
#     --allow-untrusted. Assert exit 0, no UNTRUSTED lines, every requested package installed,
#     and the newly-installed set equals the offline-repo closure.
#
# Negative controls (each MUST fail, else this script fails):
#   1. empty keys-dir            (no trust anchor at all)
#   2. one byte flipped in an .apk (content no longer matches its signed hash)
#   3. an .apk re-signed by a throwaway key (valid signature, untrusted signer)
#   4. a package absent from the repo (resolution must fail)
#
# Must run as uid 0 in a --network none amd64 container. --keys-dir is always ABSOLUTE (a
# relative keys-dir silently reports UNTRUSTED).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=../configs/openwrt-sdk.env
source configs/openwrt-sdk.env

SDK="${ROOT_DIR}/sdk"
APK="${SDK}/staging_dir/host/bin/apk"
OUT="$(cd "${ROOT_DIR}/offline-repo" 2>/dev/null && pwd -P || true)"
FEATURE_SET="${1:-travelmate}"
BASE_ARTIFACT="${H5000M_BASE_ARTIFACT:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo ">> $*"; }

[ -x "${APK}" ] || fail "missing SDK apk host tool"
[ -n "${OUT}" ] && [ -f "${OUT}/h5000m/packages.adb" ] || fail "no offline-repo — run build-offline-repo.sh"
[ -n "${BASE_ARTIFACT}" ] && [ -d "${BASE_ARTIFACT}" ] || fail "set H5000M_BASE_ARTIFACT to the base artifact dir"

# --- preconditions ---
note "verifying base artifact SHA256SUMS"
( cd "${BASE_ARTIFACT}" && sha256sum -c SHA256SUMS >/dev/null ) || fail "base artifact SHA256SUMS mismatch"

arch="$(sed -n 's/^architecture=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
profile="$(sed -n 's/^profile=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
kernel="$(sed -n 's/^kernel=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
kernel_abi="$(sed -n 's/^kernel_abi=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
[ "${arch}" = "${OPENWRT_ARCH}" ] || fail "artifact arch ${arch} != ${OPENWRT_ARCH}"
[ "${profile}" = "${OPENWRT_PROFILE}" ] || fail "artifact profile ${profile} != ${OPENWRT_PROFILE}"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
note "unpacking base rootfs"
tar -xf "${BASE_ARTIFACT}/openwrt-mediatek-filogic-hiveton_h5000m-squashfs-sysupgrade.bin" -C "${WORK}"
PRISTINE="${WORK}/pristine"
unsquashfs -q -n -d "${PRISTINE}" "${WORK}/sysupgrade-hiveton_h5000m/root" >/dev/null 2>&1
[ -f "${PRISTINE}/lib/apk/db/installed" ] || fail "unpacked rootfs missing apk db"

grep -q "kernel=${kernel}~${kernel_abi}" "${PRISTINE}/lib/apk/db/installed" \
  || fail "rootfs installed db does not carry kernel=${kernel}~${kernel_abi}"
for k in h5000m-plugins.pem openwrt-snapshots.pem; do
  [ -f "${PRISTINE}/etc/apk/keys/${k}" ] || fail "missing trust anchor ${k} in base rootfs"
done
# neutralize the online distfeeds in every staged copy: we install ONLY from offline-repo
rm -f "${PRISTINE}/etc/apk/repositories.d/distfeeds.list" \
      "${PRISTINE}/etc/apk/repositories.d/customfeeds.list"

# --- helpers ---
FEATURE_PKGS=()
mapfile -t FEATURE_PKGS < <(awk -v want="[${FEATURE_SET}]" '
  /^\[/ { insec = ($1==want); next }
  { sub(/#.*/,""); gsub(/[[:space:]]/,""); if (insec && length) print }
' configs/feature-sets.conf)
[ "${#FEATURE_PKGS[@]}" -gt 0 ] || fail "feature set '${FEATURE_SET}' empty"

apk_name()    { "${APK}" adbdump "$1" 2>/dev/null | awk '$1=="name:"{print $2; exit}'; }
apk_ver()     { "${APK}" adbdump "$1" 2>/dev/null | awk '$1=="version:"{print $2; exit}'; }
db_names()    { awk '/^P:/{print substr($0,3)}' "$1/lib/apk/db/installed" | sort -u; }

# expected closure = every .apk present in the offline repo (ours + official)
expected="${WORK}/expected.txt"
: > "${expected}"
while IFS= read -r a; do apk_name "${a}"; done \
  < <(find "${OUT}/h5000m" "${OUT}/official" -type f -name '*.apk' 2>/dev/null) | sort -u > "${expected}"
[ -s "${expected}" ] || fail "offline repo contains no .apk"

# build the -X repo argument list from a given repo root
repo_args=()
build_repo_args() {
  local root="$1"; repo_args=()
  local adb
  [ -f "${root}/h5000m/packages.adb" ] && repo_args+=( -X "${root}/h5000m/packages.adb" )
  for adb in "${root}"/official/*/packages.adb; do
    [ -f "${adb}" ] && repo_args+=( -X "${adb}" )
  done
}

fresh_root() {  # fresh_root <dest>  — a pristine copy of the base rootfs
  cp -a "${PRISTINE}" "$1"
}

# --- POSITIVE: the M1 install ---
STAGE="${WORK}/stage"; fresh_root "${STAGE}"
KEYSDIR="$(cd "${STAGE}/etc/apk/keys" && pwd -P)"   # ABSOLUTE
before="${WORK}/before.txt"; db_names "${STAGE}" > "${before}"
build_repo_args "${OUT}"

note "INSTALL (network cut, keys-dir=${KEYSDIR}, no --allow-untrusted)"
# --no-scripts: maintainer scripts run on-device at first boot (as with the ImageBuilder);
# here we assert resolution + signature verification + db update, not script execution in a
# bare offline rootfs. Signature verification is unaffected by this flag.
log="${WORK}/install.log"
if ! "${APK}" add --root "${STAGE}" --keys-dir "${KEYSDIR}" \
      --repositories-file /dev/null --no-network --no-scripts \
      "${repo_args[@]}" "${FEATURE_PKGS[@]}" >"${log}" 2>&1; then
  cat "${log}" >&2
  fail "offline install returned non-zero"
fi
if grep -Eqi 'UNTRUSTED|BAD signature' "${log}"; then
  cat "${log}" >&2; fail "install log reports an untrusted/bad signature"
fi
sed 's/^/   apk| /' "${log}"

after="${WORK}/after.txt"; db_names "${STAGE}" > "${after}"
delta="${WORK}/delta.txt"; comm -13 "${before}" "${after}" > "${delta}"

for p in "${FEATURE_PKGS[@]}"; do
  grep -qx "${p}" "${after}" || fail "requested package not installed: ${p}"
done
if ! diff -u "${expected}" "${delta}" >/dev/null; then
  echo "--- expected closure vs newly-installed ---" >&2
  diff -u "${expected}" "${delta}" >&2 || true
  fail "newly-installed set != offline-repo closure"
fi
# our built packages (configs/packages.lock) must be among the installed delta
while IFS= read -r ourpkg; do
  [ -n "${ourpkg}" ] || continue
  grep -qx "${ourpkg}" "${delta}" || fail "our package ${ourpkg} was not installed"
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' configs/packages.lock | awk '{print $1}')

note "POSITIVE OK: installed $(wc -l < "${delta}" | tr -d ' ') package(s); closure matches; anchors only"

# --- NEGATIVE CONTROLS ---
neg_pass=0
expect_fail() {  # expect_fail <label>; reads $? style via direct run passed as remaining args
  local label="$1"; shift
  local nlog="${WORK}/neg.log"
  if "$@" >"${nlog}" 2>&1; then
    echo "   [$label] UNEXPECTEDLY SUCCEEDED:" >&2; sed 's/^/     /' "${nlog}" >&2
    fail "negative control did not fail: ${label}"
  fi
  echo "   [PASS] ${label} correctly rejected (exit non-zero)"
  grep -Ei 'UNTRUSTED|BAD signature|not found|no such|unable' "${nlog}" | head -1 | sed 's/^/          reason: /' || true
  neg_pass=$((neg_pass + 1))
}

note "NEGATIVE CONTROLS (each must fail)"

# 1) empty keys-dir
NEG1="${WORK}/neg1"; fresh_root "${NEG1}"
EMPTY_KEYS="$(mktemp -d)"; EMPTY_KEYS="$(cd "${EMPTY_KEYS}" && pwd -P)"
build_repo_args "${OUT}"
expect_fail "empty keys-dir" \
  "${APK}" add --root "${NEG1}" --keys-dir "${EMPTY_KEYS}" \
    --repositories-file /dev/null --no-network --no-scripts "${repo_args[@]}" "${FEATURE_PKGS[@]}"

# 2) one byte flipped in one of our .apk files
NEG2="${WORK}/neg2"; fresh_root "${NEG2}"
CORRUPT_REPO="${WORK}/corrupt-repo"; cp -a "${OUT}" "${CORRUPT_REPO}"
victim="$(find "${CORRUPT_REPO}/h5000m" -name '*.apk' | head -1)"
[ -n "${victim}" ] || fail "no .apk to corrupt"
sz="$(wc -c < "${victim}")"; off=$(( sz / 2 ))
printf '\xff' | dd of="${victim}" bs=1 seek="${off}" count=1 conv=notrunc >/dev/null 2>&1
KEYSDIR2="$(cd "${NEG2}/etc/apk/keys" && pwd -P)"
build_repo_args "${CORRUPT_REPO}"
expect_fail "one byte flipped in an .apk" \
  "${APK}" add --root "${NEG2}" --keys-dir "${KEYSDIR2}" \
    --repositories-file /dev/null --no-network --no-scripts "${repo_args[@]}" "${FEATURE_PKGS[@]}"

# 3) an .apk re-signed by a throwaway key (valid signature, untrusted signer)
NEG3="${WORK}/neg3"; fresh_root "${NEG3}"
THROW="${WORK}/throwaway"; mkdir -p "${THROW}/feed"
openssl ecparam -name prime256v1 -genkey -noout -out "${THROW}/priv.pem" 2>/dev/null
our_apk="$(find "${OUT}/h5000m" -name '*.apk' | head -1)"
our_name="$(apk_name "${our_apk}")"
cp "${our_apk}" "${THROW}/feed/"
"${APK}" adbsign --sign-key "${THROW}/priv.pem" "${THROW}/feed/"*.apk >/dev/null 2>&1 \
  || fail "could not re-sign apk with throwaway key"
# input-side --allow-untrusted here only lets mkndx read our throwaway-signed input; the
# INSTALL below still runs WITHOUT --allow-untrusted and must reject it.
"${APK}" mkndx --allow-untrusted --sign-key "${THROW}/priv.pem" \
  -o "${THROW}/feed/packages.adb" "${THROW}/feed/"*.apk >/dev/null 2>&1 \
  || fail "could not index throwaway feed"
KEYSDIR3="$(cd "${NEG3}/etc/apk/keys" && pwd -P)"
expect_fail "apk signed by a throwaway (untrusted) key" \
  "${APK}" add --root "${NEG3}" --keys-dir "${KEYSDIR3}" \
    --repositories-file /dev/null --no-network --no-scripts -X "${THROW}/feed/packages.adb" "${our_name}"

# 4) a package absent from the repo
NEG4="${WORK}/neg4"; fresh_root "${NEG4}"
KEYSDIR4="$(cd "${NEG4}/etc/apk/keys" && pwd -P)"
build_repo_args "${OUT}"
expect_fail "package absent from repo" \
  "${APK}" add --root "${NEG4}" --keys-dir "${KEYSDIR4}" \
    --repositories-file /dev/null --no-network --no-scripts "${repo_args[@]}" "h5000m-does-not-exist-xyz"

[ "${neg_pass}" -eq 4 ] || fail "expected 4 negative controls to fail, got ${neg_pass}"
note "ALL NEGATIVE CONTROLS FAILED AS REQUIRED (4/4)"
note "M1 VERIFICATION PASSED"
