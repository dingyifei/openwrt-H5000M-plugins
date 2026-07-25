#!/usr/bin/env bash
#
# fetch-official-sdk.sh — fetch and hash-verify the exact official OpenWrt SDK pinned in
# configs/openwrt-sdk.env, then unpack it to ./sdk/. Refuses to proceed on hash drift or
# unfilled placeholders. Also preserves the fetched tarball under ./dl/ because OpenWrt
# snapshot SDKs are NOT re-downloadable once the mirror rolls (~hourly).
#
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=configs/openwrt-sdk.env
[ -f "$ENV" ] || { echo "missing $ENV"; exit 1; }
# shellcheck disable=SC1090
. "$ENV"

for v in OPENWRT_REVISION OPENWRT_BASE_URL OPENWRT_SDK_FILE OPENWRT_SDK_SHA256; do
  val=${!v:-}
  case "$val" in
    ""|*___FILL_AFTER_REPIN___*)
      echo "ERROR: $v is unset/placeholder in $ENV — run the base SDK re-pin first."; exit 2;;
  esac
done

mkdir -p dl sdk
url="$OPENWRT_BASE_URL/$OPENWRT_SDK_FILE"
out="dl/$OPENWRT_SDK_FILE"

if [ ! -f "$out" ]; then
  echo ">> fetching $url"
  curl -fSL --retry 3 -o "$out.part" "$url"
  mv "$out.part" "$out"
fi

echo ">> verifying sha256"
have=$(shasum -a 256 "$out" | awk '{print $1}')
if [ "$have" != "$OPENWRT_SDK_SHA256" ]; then
  echo "ERROR: SDK hash mismatch"
  echo "  expected $OPENWRT_SDK_SHA256"
  echo "  got      $have"
  echo "  (mirror likely rolled past $OPENWRT_REVISION — the pinned SDK is gone; re-pin the base.)"
  exit 3
fi

echo ">> unpacking to ./sdk"
rm -rf sdk && mkdir -p sdk
tar --strip-components=1 -xf "$out" -C sdk
echo ">> OK: SDK $OPENWRT_REVISION ready in ./sdk (tarball preserved in $out)"
