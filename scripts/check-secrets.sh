#!/usr/bin/env bash
# check-secrets.sh — secret scan across git files, built APK payloads, and the assembled
# offline repo. Vendored from ../openwrt-H5000M/scripts/check-secrets.sh and extended for
# the plugin pipeline:
#   * base coverage: private-key blocks, provider tokens, proxy URIs, sensitive assignments,
#     credential filenames (unchanged, byte-for-byte behaviour on tracked/untracked files).
#   * plugin coverage: Tailscale auth/node keys (tskey-, nodekey:), eSIM activation material
#     (LPA:1$, SM-DP+ with a matching id), Travelmate upstream credentials baked into
#     package/*/files/, and any "BEGIN * PRIVATE KEY" (text or binary).
#   * extra scan passes over ./bin (built .apk) and ./offline-repo, with
#     offline-repo/official/** allowlisted (upstream, OpenWrt-signed, not ours to police).
#
# Exit non-zero (1) if anything matches. Findings print as category:path:line; matched
# secret VALUES are never echoed.
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [repository]" >&2
  exit 2
fi

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if ! ROOT_DIR="$(git -C "${ROOT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Not a Git repository: ${ROOT_DIR}" >&2
  exit 2
fi

findings=0

report() {
  printf '%s:%s:%s\n' "$1" "$2" "$3"
  findings=$((findings + 1))
}

is_skipped_path() {
  case "$1" in
    .git/*|.claude/worktrees/*|.codex-remote-attachments/*|.remember/*|.work/*|\
    artifacts/*|codex-thread-data/*|logs/*|outputs/*|.cache/*|cache/*|tmp/*|.tmp/*|\
    sdk/*|dl/*|build_dir/*|staging_dir/*|\
    __pycache__/*|*/__pycache__/*|.pytest_cache/*|*/.pytest_cache/*|\
    .mypy_cache/*|*/.mypy_cache/*|.ruff_cache/*|*/.ruff_cache/*|\
    node_modules/*|*/node_modules/*|build/*|*/build/*|dist/*|*/dist/*)
      return 0
      ;;
  esac
  return 1
}

# Upstream, OpenWrt-signed packages we copy in verbatim. We verify their signatures in the
# pipeline; scanning their binary payloads for secrets would only produce noise.
is_official_repo_path() {
  case "$1" in
    offline-repo/official/*) return 0 ;;
  esac
  return 1
}

lowercase() {
  LC_ALL=C printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_risky_credential_name() {
  local lower
  lower="$(lowercase "$1")"
  case "${lower}" in
    *.key|*.key.*|*.p8|*.p12|*.pfx|*.pkcs12|*.jks|*.keystore|*.kdbx|*.ppk|*.ovpn|*.mobileconfig|*.credentials)
      return 0
      ;;
  esac
  return 1
}

is_pem_name() {
  local lower
  lower="$(lowercase "$1")"
  case "${lower}" in
    *.pem) return 0 ;;
  esac
  return 1
}

is_private_key_line() {
  local begin finish private_part re
  begin='----''-BEGIN'
  finish='----''-'
  private_part='PRI''VATE'
  re="${begin}[[:space:]][[:upper:][:digit:][:space:]]*${private_part}[[:space:]]KEY([[:space:]]BLOCK)?${finish}"
  [[ "$1" =~ $re ]]
}

is_public_pem_line() {
  local begin finish public_part re
  begin='----''-BEGIN'
  finish='----''-'
  public_part='PUB''LIC'
  re="${begin}[[:space:]]([[:upper:][:digit:]]+[[:space:]])?(${public_part}[[:space:]]KEY|CERTIFICATE)${finish}"
  [[ "$1" =~ $re ]]
}

has_provider_material() {
  local text pfx re
  text="$1"

  pfx='g''h'
  re="${pfx}[pours]_[[:alnum:]]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='g''ithub'
  re="${pfx}_pat_[[:alnum:]_]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='g''l'
  re="${pfx}pat-[[:alnum:]_-]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='xo''x'
  re="${pfx}[abprs]-[[:alnum:]-]{12,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='s''k-'
  re="${pfx}[[:alnum:]_-]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='A''KIA'
  re="${pfx}[[:upper:][:digit:]]{16}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='AI''za'
  re="${pfx}[[:alnum:]_-]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='n''pm_'
  re="${pfx}[[:alnum:]]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='h''f_'
  re="${pfx}[[:alnum:]]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='dop''_v1_'
  re="${pfx}[[:alnum:]]{20,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='S''G.'
  re="${pfx}[[:alnum:]_-]{12,}\.[[:alnum:]_-]{12,}"
  [[ "${text}" =~ $re ]] && return 0

  return 1
}

# Plugin-specific material: Tailscale keys and eSIM activation secrets.
has_plugin_material() {
  local text pfx re
  text="$1"

  pfx='tsk''ey-'
  re="${pfx}[[:alnum:]-]{6,}"
  [[ "${text}" =~ $re ]] && return 0

  pfx='node''key:'
  re="${pfx}[[:alnum:]]{16,}"
  [[ "${text}" =~ $re ]] && return 0

  # eSIM activation code carrier: LPA scheme, address and matching id separated by dollars.
  re='LPA:1\$[^[:space:]]+\$[^[:space:]]+'
  [[ "${text}" =~ $re ]] && return 0

  # SM-DP+ address paired with a matching id (the secret carrier, not the bare spec term).
  re='SM-DP\+[^[:space:]]*\$[[:alnum:]-]{8,}'
  [[ "${text}" =~ $re ]] && return 0

  return 1
}

has_proxy_material() {
  local text re pfx tail encoded body
  text="$1"
  tail='[^[:space:]@/]+@[^[:space:]/]+'
  encoded='[[:alnum:]_=-]{24,}'
  body='[[:alnum:]][[:alnum:]_:@%?&=./+-]{7,}'

  for pfx in 'vl''ess' 'tro''jan' 'tu''ic' 'hyst''eria' 'hyst''eria2' 'h''y2' 'so''cks' 'so''cks5'; do
    re="${pfx}://${tail}"
    [[ "${text}" =~ $re ]] && return 0
    re="${pfx}://${body}"
    [[ "${text}" =~ $re ]] && return 0
  done

  for pfx in 'vm''ess' 's''s' 's''sr'; do
    re="${pfx}://${encoded}"
    [[ "${text}" =~ $re ]] && return 0
    re="${pfx}://${tail}"
    [[ "${text}" =~ $re ]] && return 0
    re="${pfx}://${body}"
    [[ "${text}" =~ $re ]] && return 0
  done

  return 1
}

looks_sensitive_label() {
  local lower
  lower="$(lowercase "$1")"
  case "${lower}" in
    *password*|*passwd*|*passphrase*|*secret*|*token*|*credential*|*authorization*|*bearer*|\
    *api_key*|*apikey*|*access_key*|*private_key*|*client_key*|*auth_key*|\
    *signing_key*|*encryption_key*|*ssh_key*|*database_url*|*db_url*|*redis_url*|*smtp_url*)
      return 0
      ;;
  esac
  return 1
}

trim() {
  local value
  value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

unquote() {
  local value first last
  value="$1"
  if [ "${#value}" -ge 2 ]; then
    first="${value:0:1}"
    last="${value:${#value}-1:1}"
    if { [ "${first}" = '"' ] && [ "${last}" = '"' ]; } || \
       { [ "${first}" = "'" ] && [ "${last}" = "'" ]; }; then
      printf '%s' "${value:1:${#value}-2}"
      return
    fi
  fi
  printf '%s' "${value}"
}

is_allowed_assignment_value() {
  local label value lower re
  label="$1"
  value="$(trim "$2")"
  value="$(unquote "${value}")"

  re='^\$\{\{[[:space:]]*[^}]+[[:space:]]*\}\}$'
  [[ "${value}" =~ $re ]] && return 0
  re='^\$[[:alpha:]_][[:alnum:]_]*$'
  [[ "${value}" =~ $re ]] && return 0
  re='^\$\{[[:alpha:]_][[:alnum:]_]*\}$'
  [[ "${value}" =~ $re ]] && return 0
  re='^\$\{[[:alpha:]_][[:alnum:]_]*\}/[[:alnum:]_./-]+$'
  [[ "${value}" =~ $re ]] && return 0

  lower="$(lowercase "${label}")"
  case "${value}:${lower}" in
    root:password|root:*root*password*|root:*admin*password*|root:*default*password*)
      return 0
      ;;
    77778888:password|77778888:*wifi*password*|77778888:*wlan*password*|\
    77778888:*wireless*password*|77778888:*wifi*key*|77778888:*wlan*key*|77778888:*wireless*key*)
      return 0
      ;;
  esac
  return 1
}

assignment_from_line() {
  local text
  text="$1"
  ASSIGN_LABEL=""
  ASSIGN_DATA=""

  if [[ "${text}" =~ ^[[:space:]]*(export|ENV)[[:space:]]+([[:alpha:]_][[:alnum:]_]*)[[:space:]]*[:=][[:space:]]*(.+)$ ]]; then
    ASSIGN_LABEL="${BASH_REMATCH[2]}"
    ASSIGN_DATA="${BASH_REMATCH[3]}"
    return 0
  fi
  if [[ "${text}" =~ ^[[:space:]]*([[:alpha:]_][[:alnum:]_]*)[[:space:]]*[:=][[:space:]]*(.+)$ ]]; then
    ASSIGN_LABEL="${BASH_REMATCH[1]}"
    ASSIGN_DATA="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Travelmate (and other UCI) upstream credentials must never be baked into a package payload.
# Only enforced under package/*/files/ (the payload staging tree).
is_package_payload_path() {
  case "$1" in
    package/*/files/*) return 0 ;;
  esac
  return 1
}

is_uci_credential_line() {
  local text re
  text="$1"
  re="^[[:space:]]*(option|list)[[:space:]]+(key|password|psk|encryption_key|wpa_psk|auth_secret)[[:space:]]+['\"]?[^'\"[:space:]]{6,}"
  [[ "${text}" =~ $re ]]
}

scan_regular_file() {
  local relative full line line_number has_private has_public has_name_finding
  relative="$1"
  full="$2"
  has_private=0
  has_public=0
  has_name_finding=0

  if is_risky_credential_name "${relative}"; then
    report credential-filename "${relative}" 1
    has_name_finding=1
  fi

  if [ -s "${full}" ] && ! LC_ALL=C grep -Iq '' -- "${full}"; then
    if is_pem_name "${relative}"; then
      report credential-filename "${relative}" 1
    fi
    return
  fi

  line_number=0
  while IFS= read -r line || [ -n "${line}" ]; do
    line_number=$((line_number + 1))

    if is_private_key_line "${line}"; then
      report private-key "${relative}" "${line_number}"
      has_private=1
    fi
    if is_public_pem_line "${line}"; then
      has_public=1
    fi
    if has_proxy_material "${line}"; then
      report proxy-uri "${relative}" "${line_number}"
    fi
    if has_provider_material "${line}"; then
      report provider-token "${relative}" "${line_number}"
    fi
    if has_plugin_material "${line}"; then
      report plugin-secret "${relative}" "${line_number}"
    fi
    if is_package_payload_path "${relative}" && is_uci_credential_line "${line}"; then
      report baked-credential "${relative}" "${line_number}"
    fi
    if assignment_from_line "${line}" && looks_sensitive_label "${ASSIGN_LABEL}" && ! is_allowed_assignment_value "${ASSIGN_LABEL}" "${ASSIGN_DATA}"; then
      report sensitive-assignment "${relative}" "${line_number}"
    fi
  done < "${full}"

  if [ "${has_name_finding}" -eq 0 ] && is_pem_name "${relative}" && \
     [ "${has_private}" -eq 0 ] && [ "${has_public}" -eq 0 ]; then
    report credential-filename "${relative}" 1
  fi
}

# High-signal literal patterns for binary payloads (.apk/.adb/tar) we cannot read as text.
# (embedded quotes split the tskey-/nodekey: literals so this scanner never self-matches;
# the variable is named to avoid the sensitive-assignment heuristic flagging its own source.)
BINARY_LITERAL_RE='-----BEGIN[[:space:]][[:upper:][:digit:][:space:]]*PRIVATE KEY|tsk'"'"'ey-[[:alnum:]-]{6,}|node'"'"'key:[[:alnum:]]{16,}|LPA:1\$[^ ]+\$[^ ]+'

scan_binary_file() {
  local relative full
  relative="$1"
  full="$2"
  if LC_ALL=C grep -aoE -e "${BINARY_LITERAL_RE}" -- "${full}" >/dev/null 2>&1; then
    report binary-secret "${relative}" 1
  fi
}

scan_path() {
  local relative full
  relative="$1"
  is_skipped_path "${relative}" && return 0
  full="${ROOT_DIR}/${relative}"
  [ -f "${full}" ] || return 0
  scan_regular_file "${relative}" "${full}"
}

scan_list() {
  local relative
  while IFS= read -r -d '' relative; do
    scan_path "${relative}"
  done
}

# --- Pass 1: tracked + untracked git files (base behaviour) ---
scan_list < <(git -C "${ROOT_DIR}" ls-files -z)
scan_list < <(git -C "${ROOT_DIR}" ls-files --others --exclude-standard -z)

# --- Pass 2: build outputs not tracked by git (./bin, ./offline-repo) ---
for tree in bin offline-repo; do
  base_dir="${ROOT_DIR}/${tree}"
  [ -d "${base_dir}" ] || continue
  while IFS= read -r -d '' full; do
    relative="${full#"${ROOT_DIR}/"}"
    is_official_repo_path "${relative}" && continue
    if [ -s "${full}" ] && LC_ALL=C grep -Iq '' -- "${full}"; then
      scan_regular_file "${relative}" "${full}"
    else
      scan_binary_file "${relative}" "${full}"
    fi
  done < <(find "${base_dir}" -type f -print0)
done

if [ "${findings}" -ne 0 ]; then
  exit 1
fi
