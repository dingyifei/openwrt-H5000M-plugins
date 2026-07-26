#!/usr/bin/env bash
# build-offline-repo.sh — assemble the SIGNED offline plugin repository by record/replay.
#
# Method: unpack the exact base rootfs (its trust store already holds OpenWrt's snapshot key
# and our h5000m key), point apk at the LIVE official mirror plus our locally-built h5000m
# feed, and run `apk add` for a feature set WITH network and WITHOUT --allow-untrusted. That
# single call IS the signature verification: every fetched .apk — ours and upstream — must
# verify against a trust anchor or the call fails. The packages apk downloads to resolve the
# delta over the base ARE the closure; we harvest them from the cache, demux each upstream
# .apk into its originating feed by index membership, and fetch each upstream index verbatim.
#
# Layout produced:
#   offline-repo/h5000m/            our signed packages.adb + .apk (trusted by h5000m key)
#   offline-repo/official/<feed>/   byte-identical upstream packages.adb + the closure .apk
#   offline-repo/{SHA256SUMS,PROVENANCE.txt,INSTALL.md}
#
# Refuses to publish from a dev-key SDK (sdk/.h5000m-dev-key present).
#
# Runs on Linux against the amd64 SDK; needs the base artifact (H5000M_BASE_ARTIFACT) and
# network. Must run as uid 0 (apk add --root needs root).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
# shellcheck source=../configs/openwrt-sdk.env
source configs/openwrt-sdk.env

SDK="${ROOT_DIR}/sdk"
APK="${SDK}/staging_dir/host/bin/apk"
OUT="${ROOT_DIR}/offline-repo"
FEATURE_SET="${1:-travelmate}"

fail() { echo "build-offline-repo: $*" >&2; exit 1; }

[ -x "${APK}" ] || fail "missing SDK apk host tool"
[ -f "${SDK}/.h5000m-configured" ] || fail "SDK not configured"
[ ! -e "${SDK}/.h5000m-dev-key" ] || fail "refusing to publish: sdk/.h5000m-dev-key present (dev key)"
[ -d "${ROOT_DIR}/bin/h5000m" ] || fail "missing built packages — run scripts/build-packages.sh"
BASE_ARTIFACT="${H5000M_BASE_ARTIFACT:-}"
[ -n "${BASE_ARTIFACT}" ] && [ -d "${BASE_ARTIFACT}" ] || fail "set H5000M_BASE_ARTIFACT to the base artifact dir"

sha256_hex() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
file_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# provenance inputs
revision="$(sed -n 's/^revision=//p' "${SDK}/.h5000m-configured")"
key_fpr="$(sed -n 's/^key_fingerprint=//p' "${SDK}/.h5000m-configured")"
kernel="$(sed -n 's/^kernel=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
kernel_abi="$(sed -n 's/^kernel_abi=//p' "${BASE_ARTIFACT}/BUILD-INFO.txt")"
sdk_tarball="${ROOT_DIR}/dl/${OPENWRT_SDK_FILE}"
sdk_sha256="unknown"; [ -f "${sdk_tarball}" ] && sdk_sha256="$(file_sha256 "${sdk_tarball}")"
repo_git_sha="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"

# feature set -> package list from configs/feature-sets.conf
mapfile -t FEATURE_PKGS < <(awk -v want="[${FEATURE_SET}]" '
  /^\[/ { insec = ($1==want); next }
  { sub(/#.*/,""); gsub(/[[:space:]]/,""); if (insec && length) print }
' configs/feature-sets.conf)
[ "${#FEATURE_PKGS[@]}" -gt 0 ] || fail "feature set '${FEATURE_SET}' not found / empty in configs/feature-sets.conf"

# Names of our own packages, so we never demux them into official/.
#
# Sourced from configs/build-list, NOT configs/packages.lock: this script APPENDS the
# official half of the closure to the lock, so on any run after the first the lock also
# contains upstream names. Reading it back here made is_ours() claim upstream packages
# (464xlat, the kmods, ...) as ours and then look for them in bin/h5000m/, where they
# obviously are not. build-list is by definition exactly what we build.
mapfile -t OUR_NAMES < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' \
  configs/build-list)
is_ours() { local n="$1"; for o in "${OUR_NAMES[@]}"; do [ "$n" = "$o" ] && return 0; done; return 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/rootfs"; CACHE="${WORK}/cache"; IDX="${WORK}/idx"
mkdir -p "${CACHE}" "${IDX}"

echo ">> unpacking base rootfs for closure resolution"
tar -xf "${BASE_ARTIFACT}/openwrt-mediatek-filogic-hiveton_h5000m-squashfs-sysupgrade.bin" -C "${WORK}"
unsquashfs -q -n -d "${STAGE}" "${WORK}/sysupgrade-hiveton_h5000m/root" >/dev/null 2>&1
[ -f "${STAGE}/lib/apk/db/installed" ] || fail "unpacked rootfs missing apk db"

# distfeeds the base ships (the authoritative upstream URLs) + our local feed
mapfile -t DISTFEEDS < <(grep -E '^https?://' "${STAGE}/etc/apk/repositories.d/distfeeds.list")
[ "${#DISTFEEDS[@]}" -gt 0 ] || fail "no distfeeds in base rootfs"
printf '%s\n' "${ROOT_DIR}/bin/h5000m/packages.adb" >> "${STAGE}/etc/apk/repositories.d/customfeeds.list"

echo ">> apk add (network ON, NO --allow-untrusted) — this verifies every signature"
# --no-scripts: we resolve + fetch + signature-verify the closure into the cache; maintainer
# scripts belong to on-device first boot (the ImageBuilder installs the same way). Without it,
# a post-install script failing in a bare rootfs would mask a successful, verified resolution.
add_log="${WORK}/add.log"
if ! "${APK}" add --root "${STAGE}" --cache-dir "${CACHE}" --cache-packages --update-cache \
      --no-scripts "${FEATURE_PKGS[@]}" >"${add_log}" 2>&1; then
  cat "${add_log}" >&2
  fail "apk add failed (signature/resolution) — see log above"
fi
if grep -Eqi 'UNTRUSTED|BAD signature' "${add_log}"; then
  cat "${add_log}" >&2; fail "apk reported an untrusted/bad signature"
fi

# harvested closure = every .apk apk cached to resolve the delta over the base
mapfile -t CACHED < <(find "${CACHE}" -type f -name '*.apk' | sort)
[ "${#CACHED[@]}" -gt 0 ] || fail "apk cached no packages — closure resolution produced nothing"
echo ">> closure: ${#CACHED[@]} package(s) fetched"

# map "name version" -> feed by reading each upstream index; also record index url+sha
declare -A FEED_OF URL_OF
feed_name_from_url() {
  case "$1" in
    */targets/*/kmods/*/packages.adb) echo kmods ;;
    */targets/*/packages/packages.adb) echo target ;;
    */packages/*/base/packages.adb) echo base ;;
    */packages/*/luci/packages.adb) echo luci ;;
    */packages/*/packages/packages.adb) echo packages ;;
    */packages/*/routing/packages.adb) echo routing ;;
    */packages/*/telephony/packages.adb) echo telephony ;;
    */packages/*/video/packages.adb) echo video ;;
    *) echo "$1" | sed -E 's#.*/([^/]+)/packages.adb#\1#' ;;
  esac
}

echo ">> fetching upstream indexes verbatim + building membership map"
for url in "${DISTFEEDS[@]}"; do
  feed="$(feed_name_from_url "${url}")"
  URL_OF["${feed}"]="${url}"
  curl -fsSL --retry 5 --retry-all-errors -o "${IDX}/${feed}.adb" "${url}" || fail "could not fetch index ${url}"
  # record (name version) -> feed from this index
  while IFS=$'\t' read -r n v; do
    [ -n "${n}" ] || continue
    FEED_OF["${n} ${v}"]="${feed}"
  # `apk adbdump` renders an index as a YAML-ish list, so each package record STARTS with a
  # list marker:
  #     - name: iwinfo
  #       version: 2026.05.26~66bdd1a0-r1
  # i.e. on the name line $1 is "-" and $2 is "name:" — matching $1=="name:" never fires and
  # silently yields an empty name for every entry. Pair "- name:" with the NEXT "version:"
  # and clear the pairing afterwards so unrelated version-ish fields can't be misattributed.
  done < <("${APK}" adbdump "${IDX}/${feed}.adb" 2>/dev/null | awk '
    $1=="-" && $2=="name:" { name=$3; next }
    $1=="version:" && name!="" { print name "\t" $2; name="" }')
done

# assemble the tree
rm -rf "${OUT}"; mkdir -p "${OUT}/h5000m"
# Ship our signed index verbatim, but ONLY the .apk files this feature set actually
# resolves to. bin/h5000m/ holds every package we build; copying all of them made the
# offline repo advertise a closure larger than the requested set, which
# verify-offline-install then correctly rejected (installed != repo contents). The index
# stays a superset - it lists everything we build - which is fine and already verified:
# apk resolves against the index and only needs the .apk files it installs to be present.
cp "${ROOT_DIR}/bin/h5000m/packages.adb" "${OUT}/h5000m/packages.adb"

# Which of OUR packages does this feature set actually resolve to?
#
# NOT from the download cache: apk only caches what it fetches over the network, and our
# repo is a local file, so our packages never appear there (the run above reported
# "11 package(s) fetched" for a 13-package closure). The authoritative answer is the
# resolved install database in the staged rootfs.
while IFS=' ' read -r n v; do
  [ -n "${n}" ] || continue
  is_ours "${n}" || continue
  src="${ROOT_DIR}/bin/h5000m/${n}-${v}.apk"
  [ -f "${src}" ] || fail "closure needs ${n} ${v} but ${src} is missing"
  cp "${src}" "${OUT}/h5000m/${n}-${v}.apk"
  echo ">> shipping our package ${n} ${v}"
done < <(awk '/^P:/{p=substr($0,3)} /^V:/{if (p!="") {print p" "substr($0,3); p=""}}' \
  "${STAGE}/lib/apk/db/installed")

declare -A USED_FEEDS
apk_field() { "${APK}" adbdump "$1" 2>/dev/null | awk -v k="$2:" '$1==k {sub(/^[^:]*:[[:space:]]*/,""); print; exit}'; }

for apkf in "${CACHED[@]}"; do
  n="$(apk_field "${apkf}" name)"; v="$(apk_field "${apkf}" version)"
  [ -n "${n}" ] || fail "cached apk without a name: ${apkf}"
  if is_ours "${n}"; then
    # Already placed above from bin/h5000m (the artifact build-packages.sh signed and
    # verified). In practice ours never reach the cache at all - see the note above.
    continue
  fi
  feed="${FEED_OF["${n} ${v}"]:-}"
  [ -n "${feed}" ] || fail "could not place ${n} ${v} — not found in any upstream index"
  mkdir -p "${OUT}/official/${feed}"
  # the apk cache names files <name>-<version>.<hash>.apk; a repo expects the canonical
  # <name>-<version>.apk the upstream index refers to.
  cp "${apkf}" "${OUT}/official/${feed}/${n}-${v}.apk"
  USED_FEEDS["${feed}"]=1
done

# copy the verbatim upstream index for each feed that contributed at least one package
for feed in "${!USED_FEEDS[@]}"; do
  cp "${IDX}/${feed}.adb" "${OUT}/official/${feed}/packages.adb"
done

# Record the OFFICIAL half of the closure in configs/packages.lock. build-packages.sh writes
# the `custom` rows for what we build; without this the lock would list only our own package
# and silently fail to describe the closure it claims to lock, making drift in the upstream
# half invisible to review.
echo ">> appending official rows to configs/packages.lock"
LOCK="${ROOT_DIR}/configs/packages.lock"
lock_tmp="$(mktemp)"
grep -v -E '[[:space:]]official$' "${LOCK}" > "${lock_tmp}"   # keep header + custom rows
while IFS= read -r apkf; do
  n="$(apk_field "${apkf}" name)"; v="$(apk_field "${apkf}" version)"
  a="$(apk_field "${apkf}" arch)"
  s="$(sha256sum "${apkf}" | cut -d' ' -f1)"
  printf '%s\t%s\t%s\t%s\tofficial\n' "${n}" "${v}" "${a:-unknown}" "${s}"
done < <(find "${OUT}/official" -type f -name '*.apk' | sort) >> "${lock_tmp}"
mv -f "${lock_tmp}" "${LOCK}"

echo ">> writing PROVENANCE.txt"
{
  echo "# H5000M offline plugin repository — provenance"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "feature_sets=${FEATURE_SET}"
  echo "feature_packages=${FEATURE_PKGS[*]}"
  echo "revision=${revision}"
  echo "kernel=${kernel}"
  echo "kernel_abi=${kernel_abi}"
  echo "sdk_file=${OPENWRT_SDK_FILE}"
  echo "sdk_sha256=${sdk_sha256}"
  echo "key_fingerprint=${key_fpr}"
  echo "repo_git_sha=${repo_git_sha}"
  echo "dev_key_used=false"
  echo "# feed commit pins:"
  sed -e 's/^/#   /' configs/feeds.lock
  echo "# upstream indexes (verbatim):"
  for feed in $(printf '%s\n' "${!USED_FEEDS[@]}" | sort); do
    idxsha="$(file_sha256 "${OUT}/official/${feed}/packages.adb")"
    echo "index ${feed} ${URL_OF["${feed}"]} ${idxsha}"
  done
  echo "# our packages:"
  for apkf in "${OUT}"/h5000m/*.apk; do
    [ -e "${apkf}" ] || continue
    echo "h5000m $(basename "${apkf}") $(file_sha256 "${apkf}")"
  done
} > "${OUT}/PROVENANCE.txt"

echo ">> generating INSTALL.md"
{
  echo "# Installing the H5000M ${FEATURE_SET} plugin set (offline)"
  echo
  echo "Built against OpenWrt \`${revision}\` (kernel ${kernel}~${kernel_abi}). No network and no"
  echo "\`--allow-untrusted\`: every package verifies against the firmware's embedded trust keys"
  echo "(\`/etc/apk/keys/h5000m-plugins.pem\` for ours, \`openwrt-snapshots.pem\` for upstream)."
  echo
  echo "1. Copy this \`offline-repo/\` directory to the device, e.g. \`/tmp/offline-repo\`."
  echo "2. Register the local feeds (append to \`/etc/apk/repositories.d/customfeeds.list\`):"
  echo
  echo '   ```'
  echo "   /tmp/offline-repo/h5000m/packages.adb"
  for feed in $(printf '%s\n' "${!USED_FEEDS[@]}" | sort); do
    echo "   /tmp/offline-repo/official/${feed}/packages.adb"
  done
  echo '   ```'
  echo
  echo "3. Install the feature set (no \`--allow-untrusted\`):"
  echo
  echo '   ```'
  echo "   apk update"
  echo "   apk add ${FEATURE_PKGS[*]}"
  echo '   ```'
  echo
  echo "The dependency closure is present in \`official/<feed>/\`; the upstream \`packages.adb\` in"
  echo "each feed is byte-identical to the mirror, so OpenWrt's own signatures verify unchanged."
} > "${OUT}/INSTALL.md"

echo ">> writing SHA256SUMS"
( cd "${OUT}" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )

echo ">> OK: offline repo assembled at offline-repo/ (feeds used: ${!USED_FEEDS[*]})"
