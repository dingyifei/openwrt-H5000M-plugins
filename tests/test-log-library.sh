#!/bin/sh
# Unit tests for /usr/lib/h5000m/log.sh, runnable on the BUILD HOST with no device.
#
# The library is pure logic - level filtering, redaction, repeat collapsing - so none of it
# needs a modem, and testing it here is the difference between "looks right" and "verified".
# Redaction in particular is a privacy control: it must be proven, not eyeballed, which is
# why the assertions below grep for the actual identifiers rather than for the mask.
#
# `uci` and `logger` are stubbed: uci replays a fixture config, logger appends to a file.
#
# Usage: tests/test-log-library.sh [repo-root]
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB="${ROOT}/package/h5000m-modem-atd/files/usr/lib/h5000m/log.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
checks=0
ok()  { checks=$((checks+1)); printf '  [PASS] %s\n' "$1"; }
bad() { checks=$((checks+1)); fails=$((fails+1)); printf '  [FAIL] %s\n' "$1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/logger" <<'EOF'
#!/bin/sh
# Stub: record only the message, dropping -t/-p, so assertions match on content.
while [ $# -gt 0 ]; do
	case "$1" in -t|-p) shift 2 ;; *) break ;; esac
done
printf '%s\n' "$*" >> "$H5TEST_LOG"
EOF
cat > "$TMP/bin/uci" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -q) shift ;; *) break ;; esac; done
[ "${1:-}" = show ] || exit 0
cat "$H5TEST_UCI" 2>/dev/null
EOF
chmod +x "$TMP/bin/logger" "$TMP/bin/uci"
PATH="$TMP/bin:$PATH"
export PATH

# run <level> <redact> <shell-snippet> -> emitted lines on stdout
run() {
	H5TEST_UCI="$TMP/uci.txt"; H5TEST_LOG="$TMP/out.txt"
	export H5TEST_UCI H5TEST_LOG
	: > "$H5TEST_LOG"
	cat > "$H5TEST_UCI" <<EOF
h5000m.logging.level='$1'
h5000m.logging.trace_redact='$2'
h5000m.logging.dedup_max='5'
EOF
	shift 2
	( . "$LIB"; h5000m_log_init test; eval "$*"; h5000m_log_flush ) >/dev/null 2>&1
	cat "$H5TEST_LOG"
}

echo "== level filtering =="
out="$(run info 1 "log_info 'shown'; log_debug 'hidden'; log_error 'err'")"
case "$out" in *shown*) ok "info emitted at level info" ;; *) bad "info missing at level info" ;; esac
case "$out" in *hidden*) bad "debug leaked at level info" ;; *) ok "debug suppressed at level info" ;; esac
case "$out" in *err*) ok "error emitted at level info" ;; *) bad "error missing" ;; esac

out="$(run debug 1 "log_debug 'now-visible'")"
case "$out" in *now-visible*) ok "debug emitted at level debug" ;; *) bad "debug missing at level debug" ;; esac

echo "== log_want predicate =="
out="$(run info 1 "log_want trace && log_trace 'should-not-appear'; log_want info && log_info 'want-info-ok'")"
case "$out" in *should-not-appear*) bad "log_want trace was true at level info" ;; *) ok "log_want trace false at level info" ;; esac
case "$out" in *want-info-ok*) ok "log_want info true at level info" ;; *) bad "log_want info false at level info" ;; esac

echo "== redaction (privacy control - assert the SECRET is absent) =="
# IMSI 15 digits, EID 32 digits, a PDU-ish hex run, a long quoted string.
out="$(run trace 1 "log_trace 'imsi %s' 460110123456789; log_trace 'eid %s' 89033023426300000000033217590106; log_trace 'pdu %s' 0791448720003023240DD0E474D81C0EBB01; log_trace 'apn %s' '\"subscription-default\"'")"
case "$out" in *460110123456789*) bad "IMSI survived redaction" ;; *) ok "IMSI redacted" ;; esac
case "$out" in *89033023426300000000033217590106*) bad "EID survived redaction" ;; *) ok "EID redacted" ;; esac
case "$out" in *0791448720003023240DD0E474D81C0EBB01*) bad "PDU survived redaction" ;; *) ok "PDU redacted" ;; esac
case "$out" in *subscription-default*) bad "long quoted string survived redaction" ;; *) ok "long quoted value redacted" ;; esac
# Short, non-identifying values must NOT be mangled or the logs become useless.
out="$(run trace 1 "log_trace '%s' '+CESQ: 99,99,255,255,255,255,83,73,77'; log_trace '%s' 'OK'")"
case "$out" in *"99,99,255"*) ok "short numeric fields left intact" ;; *) bad "over-redacted CESQ fields" ;; esac
case "$out" in *OK*) ok "bare OK left intact" ;; *) bad "over-redacted OK" ;; esac

echo "== redaction applies at ALL levels, not just trace =="
out="$(run info 1 "log_warn 'iccid %s' 8986011234567890123")"
case "$out" in *8986011234567890123*) bad "ICCID survived redaction at warn level" ;; *) ok "ICCID redacted at warn level" ;; esac

echo "== redaction can be disabled deliberately =="
out="$(run trace 0 "log_trace 'imsi %s' 460110123456789")"
case "$out" in *460110123456789*) ok "trace_redact=0 emits raw (opt-in)" ;; *) bad "trace_redact=0 still redacted" ;; esac
case "$out" in *UNREDACTED*) ok "warns loudly when redaction is off" ;; *) bad "no warning when redaction disabled" ;; esac

echo "== repeat collapsing =="
out="$(run info 1 "log_info 'same'; log_info 'same'; log_info 'same'; log_info 'different'")"
n="$(printf '%s\n' "$out" | grep -c '^same$')"
[ "$n" = 1 ] && ok "3 identical messages emitted once" || bad "identical messages emitted $n times (want 1)"
case "$out" in *"repeated 3 times"*) ok "repeat count flushed on change" ;; *) bad "no repeat count emitted" ;; esac
case "$out" in *different*) ok "differing message emitted" ;; *) bad "differing message lost" ;; esac

out="$(run info 1 "log_info 'a'; log_info 'b'; log_info 'a'")"
case "$out" in *"repeated"*) bad "non-consecutive repeat wrongly collapsed" ;; *) ok "only CONSECUTIVE repeats collapse" ;; esac

echo "== dedup_max caps an unbounded run =="
out="$(run info 1 "i=0; while [ \$i -lt 12 ]; do log_info 'loop'; i=\$((i+1)); done")"
case "$out" in *"repeated 5 times"*) ok "run flushed at dedup_max" ;; *) bad "dedup_max cap did not flush" ;; esac

echo "== format safety =="
out="$(run info 1 "log_info '%s' 'literal %d and %s stay put'")"
case "$out" in *"literal %d and %s stay put"*) ok "%-containing payload not reinterpreted" ;; *) bad "payload format specifiers were expanded" ;; esac

echo
echo "checks=${checks} failures=${fails}"
[ "$fails" -eq 0 ] || exit 1
echo "ALL LOG LIBRARY TESTS PASSED"
