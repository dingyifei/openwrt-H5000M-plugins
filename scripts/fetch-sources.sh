#!/usr/bin/env bash
# fetch-sources.sh — materialize the third-party package sources pinned in configs/sources.lock,
# and assemble the aggregated h5000m feed directory the SDK builds from.
#
# Why an aggregate feed: the whole signing/index/offline-repo pipeline treats "our packages" as
# the single `h5000m` feed. Rather than teach every downstream step about a second feed, we point
# the h5000m src-link at .sources/h5000m-feed/, a directory of symlinks to BOTH the first-party
# package/* dirs and the fetched third-party package dirs. One feed, one signed index, one harvest.
#
# Reproducibility: `commit` in sources.lock is the immutable anchor. We download the GitHub
# codeload archive AT that commit and verify it against the recorded `sha256` (fail-closed). A
# compiled/arch-specific package is allowed from here — unlike the noarch-only build-list.
#
# Idempotent. Called by configure-sdk.sh. Safe to run with an EMPTY sources.lock: the aggregate
# then contains only the first-party symlinks, i.e. it is equivalent to linking package/ directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SRC_ROOT="${ROOT_DIR}/.sources"
FEED_DIR="${SRC_ROOT}/h5000m-feed"
LOCK="${ROOT_DIR}/configs/sources.lock"

fail() { echo "fetch-sources: $*" >&2; exit 1; }
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- (re)build the aggregate feed dir with the first-party packages ------------------------
rm -rf "${FEED_DIR}"
mkdir -p "${FEED_DIR}"
for d in "${ROOT_DIR}"/package/*/; do
  [ -f "${d}Makefile" ] || continue
  ln -s "${d%/}" "${FEED_DIR}/$(basename "${d}")"
done

# --- parse + fetch each [section] in sources.lock ------------------------------------------
# Format (documented in the file): a "[name]" header, then key = value lines
#   repo=  commit=  sha256=  license=  builds=
name="" repo="" commit="" sha256="" builds=""
entries=0

emit_entry() {
  [ -n "${name}" ] || return 0
  [ -n "${repo}" ] && [ -n "${commit}" ] && [ -n "${sha256}" ] && [ -n "${builds}" ] \
    || fail "incomplete entry [${name}] (need repo/commit/sha256/builds)"
  case "${commit}" in
    *[!0-9a-f]* | "") fail "[${name}] commit is not a 40-char hex sha: ${commit}" ;;
  esac
  [ "${#commit}" -eq 40 ] || fail "[${name}] commit is not 40 chars: ${commit}"

  local owner_repo="${repo#https://github.com/}"; owner_repo="${owner_repo%.git}"
  local url="https://codeload.github.com/${owner_repo}/tar.gz/${commit}"
  local tgz="${SRC_ROOT}/${name}.tar.gz"
  local dir="${SRC_ROOT}/${name}"

  echo ">> fetching ${name} @ ${commit:0:12} from ${url}"
  curl -fsSL --retry 5 --retry-all-errors -o "${tgz}.part" "${url}" || fail "download failed: ${url}"
  mv "${tgz}.part" "${tgz}"
  local got; got="$(file_sha256 "${tgz}")"
  [ "${got}" = "${sha256}" ] || fail "[${name}] archive sha256 mismatch: got ${got} want ${sha256} (repin: the pinned commit is the anchor)"

  rm -rf "${dir}"; mkdir -p "${dir}"
  tar -xzf "${tgz}" -C "${dir}" --strip-components=1

  # symlink ONLY the packages we build (e.g. mihomo-meta, not the conflicting mihomo-alpha)
  local pkg
  for pkg in ${builds}; do
    [ -f "${dir}/${pkg}/Makefile" ] || fail "[${name}] builds names '${pkg}' but ${pkg}/Makefile is absent"
    ln -sfn "${dir}/${pkg}" "${FEED_DIR}/${pkg}"
  done
  entries=$((entries + 1))
}

while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in
    \#*) continue ;;
    \[*\]) emit_entry; name="${line#[}"; name="${name%]}"; repo="" commit="" sha256="" builds="" ;;
    *=*)
      key="${line%%=*}"; val="${line#*=}"
      key="$(printf '%s' "${key}" | tr -d '[:space:]')"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      case "${key}" in
        repo) repo="${val}" ;; commit) commit="${val}" ;; sha256) sha256="${val}" ;;
        license) : ;; builds) builds="${val}" ;;
      esac
      ;;
  esac
done < "${LOCK}"
emit_entry

echo ">> fetch-sources: ${entries} third-party source(s); aggregate feed at ${FEED_DIR}"
