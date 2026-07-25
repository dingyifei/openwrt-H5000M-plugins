#!/usr/bin/env bash
#
# fetch-official-sdk.sh — fetch + integrity-check the official OpenWrt SDK, then unpack it
# to ./sdk/. Rolling by default (matches the base's OPENWRT_ROLLING philosophy): the SDK is
# verified against the mirror's own live `sha256sums`, not a committed hash, because OpenWrt
# snapshots roll ~hourly and are not archived.
#
# IMPORTANT: the SDK must come from the SAME snapshot as the base image (kmods/ABI). When
# building alongside a rolling base build, pass the revision the base adopted via
# OPENWRT_REVISION so a mid-build mirror roll is detected instead of silently mismatching.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=configs/openwrt-sdk.env
# shellcheck disable=SC1090
[ -f "$ENV" ] && . "$ENV"

BASE_URL="${OPENWRT_BASE_URL:-https://downloads.openwrt.org/snapshots/targets/mediatek/filogic}"
SDK_FILE="${OPENWRT_SDK_FILE:-openwrt-sdk-mediatek-filogic_gcc-14.4.0_musl.Linux-x86_64.tar.zst}"

mkdir -p dl sdk

echo ">> reading live sha256sums from the mirror"
sums="$(curl -fsSL --retry 5 --retry-all-errors "$BASE_URL/sha256sums")"
want="$(awk -v f="*$SDK_FILE" '$2==f {print $1}' <<<"$sums")"
[ -n "$want" ] || { echo "ERROR: $SDK_FILE not listed in the current snapshot sha256sums (name changed?)"; exit 1; }

# Optional pin guard: if a real hash is committed and rolling is off, require an exact match.
if [ "${OPENWRT_ROLLING:-1}" != 1 ] && [ -n "${OPENWRT_SDK_SHA256:-}" ] && \
   [[ "${OPENWRT_SDK_SHA256}" != *___* ]] && [ "${OPENWRT_SDK_SHA256}" != "${want}" ]; then
  echo "ERROR: live SDK hash ${want} != pinned ${OPENWRT_SDK_SHA256} (mirror rolled; pinned SDK is gone)."; exit 1
fi

out="dl/$SDK_FILE"
echo ">> fetching $BASE_URL/$SDK_FILE"
curl -fSL --retry 5 --retry-all-errors -o "$out.part" "$BASE_URL/$SDK_FILE"
mv "$out.part" "$out"

echo ">> verifying against live sha256"
have="$(shasum -a 256 "$out" | awk '{print $1}')"
[ "$have" = "$want" ] || { echo "ERROR: SDK hash mismatch (mirror rolled mid-fetch); re-run."; exit 3; }

echo ">> unpacking to ./sdk"
rm -rf sdk && mkdir -p sdk
tar --strip-components=1 -xf "$out" -C sdk
rev="$(sed -n 's/^REVISION:=//p' sdk/include/version.mk 2>/dev/null | head -1)"
if [ -n "${OPENWRT_REVISION:-}" ] && [[ "${OPENWRT_REVISION}" != *___* ]] && [ -n "$rev" ] && [ "$rev" != "${OPENWRT_REVISION}" ]; then
  echo "WARNING: SDK revision $rev != requested ${OPENWRT_REVISION} — base and plugins must share one snapshot."
fi
echo ">> OK: SDK ${rev:-?} ready in ./sdk"
