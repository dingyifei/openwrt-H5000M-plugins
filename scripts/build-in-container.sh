#!/usr/bin/env bash
# build-in-container.sh — run a pipeline script inside the amd64 OpenWrt builder container.
#
# The SDK host tools (apk, fakeroot, the toolchain) are x86_64 Linux binaries, so on a non-x86
# host every SDK step must run in the linux/amd64 builder image. CI runs the scripts directly
# on an amd64 runner and does not need this wrapper; locally it provides the same environment.
#
# Usage:
#   scripts/build-in-container.sh [--network none] [--mount-base] <script.sh> [args...]
#
#   --network none : cut the container network (offline install verification).
#   --mount-base   : bind-mount the base artifact dir read-only at /base-artifact.
#
# Key handling: in release mode (default) the persistent signing key is copied from the host
# into a container-internal dir owned by uid 0 with 0700/0600 perms, so the in-container
# signing-key check passes cleanly. In dev mode (H5000M_APK_KEY_MODE=dev) no host key is
# mounted and the check script mints a throwaway key inside the container.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../configs/openwrt-sdk.env
source "${ROOT_DIR}/configs/openwrt-sdk.env"

IMAGE="${H5000M_BUILDER_IMAGE:-openwrt-h5000m-imagebuilder:ubuntu-24.04-amd64}"
KEY_MODE="${H5000M_APK_KEY_MODE:-release}"
NETWORK_ARGS=()
MOUNT_BASE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --network) NETWORK_ARGS=(--network "$2"); shift 2 ;;
    --network=*) NETWORK_ARGS=(--network "${1#*=}"); shift ;;
    --mount-base) MOUNT_BASE=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || { echo "usage: $0 [--network none] [--mount-base] <script.sh> [args...]" >&2; exit 2; }

SCRIPT="$1"; shift
ARGS=("$@")

docker_args=(
  run --rm --platform linux/amd64 --user 0:0
  -v "${ROOT_DIR}:/work" -w /work
  -e "HOME=/root"
  -e "H5000M_APK_KEY_MODE=${KEY_MODE}"
  "${NETWORK_ARGS[@]}"
)

case "${KEY_MODE}" in
  release) HOST_KEY_DIR="${H5000M_APK_SIGNING_DIR:-${HOME}/.config/h5000m-apk}"
           [ -d "${HOST_KEY_DIR}" ] || { echo "missing signing dir ${HOST_KEY_DIR}" >&2; exit 1; }
           docker_args+=(-v "${HOST_KEY_DIR}:/host-key:ro") ;;
  dev)     : ;;
  *) echo "unknown H5000M_APK_KEY_MODE '${KEY_MODE}'" >&2; exit 1 ;;
esac

if [ "${MOUNT_BASE}" -eq 1 ]; then
  BASE_ARTIFACT="${H5000M_BASE_ARTIFACT:-/Users/yifeiding/projects/personal/openwrt-H5000M/artifacts/H5000M-official-base-r35533-3b2bc55dcb}"
  [ -d "${BASE_ARTIFACT}" ] || { echo "missing base artifact ${BASE_ARTIFACT}" >&2; exit 1; }
  docker_args+=(-v "${BASE_ARTIFACT}:/base-artifact:ro" -e "H5000M_BASE_ARTIFACT=/base-artifact")
fi

# Build the in-container bootstrap: git trust, key install (release), then exec the script.
bootstrap='set -euo pipefail
git config --global --add safe.directory "*" 2>/dev/null || true'
if [ "${KEY_MODE}" = release ]; then
  bootstrap+='
mkdir -p /root/.config
cp -r /host-key /root/.config/h5000m-apk
chown -R 0:0 /root/.config/h5000m-apk
chmod 0700 /root/.config/h5000m-apk
chmod 0600 /root/.config/h5000m-apk/private-key.pem
chmod 0644 /root/.config/h5000m-apk/public-key.pem'
fi
printf -v arg_str '%q ' "./${SCRIPT#scripts/}"
# rebuild with scripts/ prefix preserved
arg_str="./scripts/$(basename "${SCRIPT}")"
for a in "${ARGS[@]}"; do printf -v q '%q' "$a"; arg_str+=" ${q}"; done
bootstrap+="
exec ${arg_str}"

exec docker "${docker_args[@]}" "${IMAGE}" bash -lc "${bootstrap}"
