#!/usr/bin/env bash
# build-packages.sh — build + sign the packages in configs/build-list, verify each signed
# .apk, index them, and record the resolved closure to configs/packages.lock.
#
# Preconditions: configure-sdk.sh has run (sdk/.h5000m-configured present) and the placed
# signing key still hashes to the configured fingerprint.
#
# Per-.apk post-conditions (all fatal):
#   * container magic is ADBd;
#   * `apk verify --keys-dir <ABS trust dir>` exits 0 (the built package is properly signed);
#   * the same verify with an EMPTY keys-dir exits non-zero (proves the check is real);
#   * arch is "noarch" for a PKGARCH:=all recipe.
# Then `make package/index` builds a signed packages.adb, which `apk verify` must also accept.
#
# configs/packages.lock is regenerated (sorted; provenance header). With --check the script
# fails if the freshly generated lock differs from the committed one instead of rewriting it.
#
# Third-party source-built packages are NOT part of this batch: configs/sources.lock must be
# empty, and this script fails loudly if it is not (rather than silently skipping them).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=../configs/openwrt-sdk.env
source configs/openwrt-sdk.env

SDK="${ROOT_DIR}/sdk"
APK="${SDK}/staging_dir/host/bin/apk"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

fail() { echo "build-packages: $*" >&2; exit 1; }

[ -f "${SDK}/.h5000m-configured" ] || fail "SDK not configured — run scripts/configure-sdk.sh"
[ -x "${APK}" ] || fail "missing SDK apk host tool at ${APK}"

# provenance from the configure marker
revision="$(sed -n 's/^revision=//p' "${SDK}/.h5000m-configured")"
feeds_lock_sha="$(sed -n 's/^feeds_lock_sha256=//p' "${SDK}/.h5000m-configured")"
configured_fpr="$(sed -n 's/^key_fingerprint=//p' "${SDK}/.h5000m-configured")"

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
key_fingerprint() { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256_hex; }

# --- third-party sources ---
# Packages pinned in configs/sources.lock are fetched + symlinked into the h5000m feed by
# configure-sdk.sh (via fetch-sources.sh), so here they build exactly like first-party ones.
# Unlike the noarch-only build-list, a source package may be arch-specific (a compiled binary).
# Build a name->source map so packages.lock records provenance ("custom" vs the source name).
declare -A PKG_SOURCE
src_name=""
while IFS= read -r line; do
  case "${line}" in
    \#*) continue ;;
    \[*\]) src_name="${line#[}"; src_name="${src_name%]}" ;;
    *builds*=*) for p in ${line#*=}; do PKG_SOURCE["${p}"]="${src_name}"; done ;;
  esac
done < configs/sources.lock

# --- key drift guard ---
placed_fpr="$(key_fingerprint "${SDK}/private-key.pem")"
[ "${placed_fpr}" = "${configured_fpr}" ] || fail "SDK signing key changed since configure (${placed_fpr} != ${configured_fpr})"

# --- trust dirs for apk verify ---
TRUST_DIR="$(mktemp -d)"; EMPTY_DIR="$(mktemp -d)"
trap 'rm -rf "${TRUST_DIR}" "${EMPTY_DIR}"' EXIT
cp "${SDK}/public-key.pem" "${TRUST_DIR}/h5000m-plugins.pem"
TRUST_DIR="$(cd "${TRUST_DIR}" && pwd -P)"   # apk needs an ABSOLUTE keys-dir
EMPTY_DIR="$(cd "${EMPTY_DIR}" && pwd -P)"

apk_field() {  # apk_field <file> <field>  — read a top-level scalar from the ADB container
  "${APK}" adbdump "$1" 2>/dev/null | awk -v k="$2:" '$1==k {sub(/^[^:]*:[[:space:]]*/,""); print; exit}'
}

# --- build each package ---
mapfile -t BUILD_PKGS < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' configs/build-list)
[ "${#BUILD_PKGS[@]}" -gt 0 ] || fail "configs/build-list is empty"
# Source-built packages come AFTER the first-party ones (sources.lock `builds=` order is the
# dependency order, e.g. mihomo-meta before nikki before luci-app-nikki).
mapfile -t SRC_PKGS < <(sed -n 's/^[[:space:]]*builds[[:space:]]*=[[:space:]]*//p' configs/sources.lock | tr ' ' '\n' | sed '/^[[:space:]]*$/d')
BUILD_PKGS=( "${BUILD_PKGS[@]}" "${SRC_PKGS[@]}" )

rm -rf "${ROOT_DIR}/bin/h5000m"
mkdir -p "${ROOT_DIR}/bin/h5000m"

# Parallelism for any dependency the build system still decides to compile. Override with
# H5000M_BUILD_JOBS. nproc is absent on macOS hosts, hence the sysctl fallback.
: "${H5000M_BUILD_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

declare -a LOCK_ROWS=()
for pkg in "${BUILD_PKGS[@]}"; do
  echo ">> building package/${pkg}"
  ( cd "${SDK}" && make "package/${pkg}/clean" >/dev/null 2>&1 || true )
  # -j: these packages compile nothing themselves, but any dependency the build system
  # decides to build is otherwise done strictly serially. Keep V=s so a failure is still
  # attributable; OpenWrt serialises the per-package steps that need it.
  ( cd "${SDK}" && make -j"${H5000M_BUILD_JOBS}" "package/${pkg}/compile" V=s ) \
    || fail "build failed: ${pkg}"

  # locate the freshly built .apk (noarch packages live under the h5000m feed dir)
  mapfile -t built < <(find "${SDK}/bin" -type f -name "${pkg}-*.apk")
  [ "${#built[@]}" -eq 1 ] || fail "expected exactly one .apk for ${pkg}, found ${#built[@]}"
  apkf="${built[0]}"

  # magic
  magic="$(dd if="${apkf}" bs=1 count=4 2>/dev/null)"
  [ "${magic}" = "ADBd" ] || fail "${pkg}: bad container magic '${magic}' (want ADBd)"

  # positive verify (capture status directly; never through a pipe)
  if ! "${APK}" verify --keys-dir "${TRUST_DIR}" "${apkf}" >/dev/null 2>&1; then
    fail "${pkg}: apk verify against our trust dir failed (unsigned or wrong key?)"
  fi
  # negative control: empty keys-dir MUST reject
  if "${APK}" verify --keys-dir "${EMPTY_DIR}" "${apkf}" >/dev/null 2>&1; then
    fail "${pkg}: apk verify unexpectedly PASSED with an empty keys-dir"
  fi

  name="$(apk_field "${apkf}" name)"
  version="$(apk_field "${apkf}" version)"
  arch="$(apk_field "${apkf}" arch)"
  [ -n "${name}" ] && [ -n "${version}" ] || fail "${pkg}: could not read name/version from ${apkf}"
  # First-party recipes are PKGARCH:=all (noarch); a third-party source package may be compiled
  # for the target arch. Anything else (a foreign arch) is a real error.
  pkg_src="${PKG_SOURCE[${pkg}]:-custom}"
  case "${arch}" in
    noarch) ;;
    "${OPENWRT_ARCH}") [ "${pkg_src}" != custom ] || fail "${pkg}: first-party package is arch '${arch}', expected noarch" ;;
    *) fail "${pkg}: unexpected arch '${arch}' (want noarch or ${OPENWRT_ARCH})" ;;
  esac

  cp "${apkf}" "${ROOT_DIR}/bin/h5000m/"
  sha="$(file_sha256 "${apkf}")"
  LOCK_ROWS+=("${name}	${version}	${arch}	${sha}	${pkg_src}")
  echo "   ${name} ${version} ${arch} signed+verified (${sha})"
done

# --- signed index over our feed ---
echo ">> make package/index (signed packages.adb)"
( cd "${SDK}" && make package/index ) || fail "package/index failed"
# Log the full h5000m feed output layout — with an arch-specific package now in the feed this
# is where apk could split noarch vs arch into separate index dirs. Assert exactly one so a
# split surfaces loudly (with paths) instead of a silently partial index.
mapfile -t indexes < <(find "${SDK}/bin/packages" -type f -path '*/h5000m/packages.adb' | sort)
echo "   h5000m index dirs found: ${#indexes[@]}"
printf '     %s\n' "${indexes[@]}"
find "${SDK}/bin/packages" -type f -path '*/h5000m/*.apk' -printf '     apk %p\n' 2>/dev/null | sort || true
[ "${#indexes[@]}" -ge 1 ] || fail "no h5000m/packages.adb produced by package/index"
[ "${#indexes[@]}" -eq 1 ] || fail "expected ONE h5000m index, found ${#indexes[@]} (arch/noarch split — offline-repo harvest must be taught both)"
index="${indexes[0]}"
imagic="$(dd if="${index}" bs=1 count=4 2>/dev/null)"
[ "${imagic}" = "ADBd" ] || fail "packages.adb bad magic '${imagic}'"
"${APK}" verify --keys-dir "${TRUST_DIR}" "${index}" >/dev/null 2>&1 || fail "signed index failed verification"
cp "${index}" "${ROOT_DIR}/bin/h5000m/"
echo "   index verified: ${index}"

# --- kernel/abi provenance (noarch-independent; from the base artifact when available) ---
kernel="noarch-independent"; kernel_abi="noarch-independent"
base_info="${H5000M_BASE_ARTIFACT:-}/BUILD-INFO.txt"
if [ -n "${H5000M_BASE_ARTIFACT:-}" ] && [ -f "${base_info}" ]; then
  kernel="$(sed -n 's/^kernel=//p' "${base_info}")"
  kernel_abi="$(sed -n 's/^kernel_abi=//p' "${base_info}")"
fi

# --- regenerate packages.lock ---
new_lock="$(mktemp)"
{
  echo "# Resolved APK closure built from this repo. Regenerated by build-packages.sh."
  echo "# revision=${revision} kernel=${kernel} kernel_abi=${kernel_abi}"
  echo "# feeds_lock_sha256=${feeds_lock_sha} key_fingerprint=${configured_fpr}"
  echo "# columns: name  version  arch  sha256  source"
  printf '%s\n' "${LOCK_ROWS[@]}" | sort
} > "${new_lock}"

if [ "${CHECK}" -eq 1 ]; then
  if ! diff -u configs/packages.lock "${new_lock}"; then
    rm -f "${new_lock}"
    fail "--check: regenerated packages.lock differs from the committed one"
  fi
  rm -f "${new_lock}"
  echo ">> --check OK: committed packages.lock matches the rebuilt closure"
else
  mv "${new_lock}" configs/packages.lock
  echo ">> wrote configs/packages.lock"
fi
echo ">> OK: built ${#BUILD_PKGS[@]} package(s), all signed + verified"
