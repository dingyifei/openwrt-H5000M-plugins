#!/bin/sh
# Unit tests for the FM350 dead-bearer recovery ladder (fm350-watchdog.sh), runnable on the
# BUILD HOST with no device.
#
# What a mocked run can prove and a hardware run cannot: the tier SELECTION and the counter
# bookkeeping. The bug this whole feature fixes is that the dialer believed a dead-but-addressed
# bearer was healthy; the ladder is what turns a confirmed-dead bearer into escalating recovery
# WITHOUT letting a marginal link storm up the tiers or letting a truly-stuck link reboot the
# router forever. Those are exactly the invariants below.
#
# The library is sourced directly (it has no side effects on source). Every irreversible action
# is redirected to a recording stub: FM350_USB_RESET and FM350_REBOOT_CMD point at scripts that
# only append to a log, and `ping` is stubbed on PATH so probe_ok is deterministic. The counter
# files are redirected off the real system via FM350_RECOV_DIR / FM350_GUARD_DIR.
#
# Usage: tests/test-fm350-recovery-ladder.sh [repo-root]
#   H5TEST_LIB may override the library under test (used for a negative control against a
#   deliberately-broken copy).
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB="${H5TEST_LIB:-${ROOT}/package/h5000m-fm350/files/usr/lib/h5000m/fm350-watchdog.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
checks=0
ok()  { checks=$((checks+1)); printf '  [PASS] %s\n' "$1"; }
bad() { checks=$((checks+1)); fails=$((fails+1)); printf '  [FAIL] %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }

# --- stubs on PATH and via the library seams ----------------------------------
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/etc"

# ping: succeeds only for targets listed in $H5TEST_PING_OK (last arg is the target).
cat > "$TMP/bin/ping" <<'EOF'
#!/bin/sh
for a in "$@"; do t="$a"; done
case " ${H5TEST_PING_OK:-} " in *" $t "*) exit 0 ;; *) exit 1 ;; esac
EOF
# usb-reset / reboot: record the call, never actually do it.
cat > "$TMP/bin/usb-reset" <<'EOF'
#!/bin/sh
printf 'reset %s\n' "$*" >> "$H5TEST_USBRESET"
EOF
cat > "$TMP/bin/reboot-stub" <<'EOF'
#!/bin/sh
printf 'reboot\n' >> "$H5TEST_REBOOT"
EOF
chmod +x "$TMP/bin/ping" "$TMP/bin/usb-reset" "$TMP/bin/reboot-stub"
PATH="$TMP/bin:$PATH"; export PATH

H5TEST_USBRESET="$TMP/usbreset.calls"; : > "$H5TEST_USBRESET"
H5TEST_REBOOT="$TMP/reboot.calls";     : > "$H5TEST_REBOOT"
export H5TEST_USBRESET H5TEST_REBOOT

# Library seams (must be set BEFORE sourcing so the library's := defaults keep them).
FM350_RECOV_DIR="$TMP/run"
FM350_GUARD_DIR="$TMP/etc"
FM350_USB_RESET="$TMP/bin/usb-reset"
FM350_REBOOT_CMD="$TMP/bin/reboot-stub"
export FM350_RECOV_DIR FM350_GUARD_DIR FM350_USB_RESET FM350_REBOOT_CMD

# Deterministic tunables (kept small so the tiers are easy to reason about).
WATCHDOG=1
PROBE_TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
PROBE_INTERVAL=15
PROBE_TIMEOUT=2
PROBE_FAILS=4
REDIAL_LIMIT=3
MODEM_RESET_LIMIT=2
REBOOT_LIMIT=2
HEALTHY_HOLD=120

# shellcheck source=/dev/null
. "$LIB"

IF=cellular
reset_state() {
	rm -f "$TMP/run/"* "$TMP/etc/"* 2>/dev/null
	: > "$H5TEST_USBRESET"; : > "$H5TEST_REBOOT"
}
usbreset_count() { grep -c . "$H5TEST_USBRESET" 2>/dev/null || true; }
reboot_count()   { grep -c . "$H5TEST_REBOOT"   2>/dev/null || true; }

# ==============================================================================
echo "== ladder_tier maps attempts to tiers (redial x3 -> reset x2 -> reboot), cyclic =="
# cycle = REDIAL_LIMIT + MODEM_RESET_LIMIT = 5; positions 0..2 redial, 3..4 reset, 5 reboot,
# then it wraps so a refused reboot keeps the link cycling instead of wedging.
eq "R=1 redial" "$(ladder_tier 1)" redial
eq "R=3 redial" "$(ladder_tier 3)" redial
eq "R=4 reset"  "$(ladder_tier 4)" reset
eq "R=5 reset"  "$(ladder_tier 5)" reset
eq "R=6 reboot" "$(ladder_tier 6)" reboot
eq "R=7 wraps to redial" "$(ladder_tier 7)" redial
eq "R=12 wraps to reboot" "$(ladder_tier 12)" reboot
# Negative control: the boundary is exclusive - attempt 4 must NOT still be a re-dial.
[ "$(ladder_tier 4)" != redial ] && ok "negative control: R=4 is not redial (no off-by-one)" \
	|| bad "R=4 selected redial - REDIAL_LIMIT boundary is off by one"

echo "== healthy_cycles = ceil(HEALTHY_HOLD / PROBE_INTERVAL), min 1 =="
eq "120/15 -> 8" "$(HEALTHY_HOLD=120 PROBE_INTERVAL=15; healthy_cycles)" 8
eq "100/15 -> 7 (rounds up)" "$(HEALTHY_HOLD=100 PROBE_INTERVAL=15; healthy_cycles)" 7
eq "0 -> 1 (floor)" "$(HEALTHY_HOLD=0 PROBE_INTERVAL=15; healthy_cycles)" 1
[ "$(HEALTHY_HOLD=100 PROBE_INTERVAL=15; healthy_cycles)" != 6 ] \
	&& ok "negative control: 100/15 is not truncated to 6" || bad "healthy_cycles truncated instead of rounding up"

# ==============================================================================
echo "== bearer_recover escalates and advances the recovery counter =="
reset_state
i=1
while [ "$i" -le 3 ]; do eq "attempt $i -> redial" "$(bearer_recover "$IF" probe 2>/dev/null)" redial; i=$((i+1)); done
eq "recov counter after 3 re-dials" "$(recov_read "$IF")" 3
eq "no modem reset yet"  "$(usbreset_count)" 0
eq "no reboot yet"       "$(reboot_count)" 0

eq "attempt 4 -> reset" "$(bearer_recover "$IF" probe 2>/dev/null)" reset
eq "attempt 5 -> reset" "$(bearer_recover "$IF" probe 2>/dev/null)" reset
eq "modem reset invoked twice" "$(usbreset_count)" 2
eq "still no reboot"           "$(reboot_count)" 0

eq "attempt 6 -> reboot" "$(bearer_recover "$IF" probe 2>/dev/null)" reboot
eq "reboot invoked once"       "$(reboot_count)" 1
eq "reboot guard now 1"        "$(guard_read "$IF")" 1

# ==============================================================================
echo "== the reboot guard caps reboots and then refuses, cycling tiers 1-2 instead =="
reset_state
# Guard already at the limit; next reboot-tier hit (recov 5 -> attempt 6) must be REFUSED.
recov_write "$IF" 5
printf '%s\n' "$REBOOT_LIMIT" > "$TMP/etc/fm350-${IF}.reboot-guard"
tier="$(bearer_recover "$IF" probe 2>/dev/null)"
eq "reboot refused at the guard limit" "$tier" reboot-refused
eq "no reboot was issued"              "$(reboot_count)" 0
eq "recovery counter reset to restart the cycle" "$(recov_read "$IF")" 0

echo "== negative control: one BELOW the limit still reboots =="
reset_state
recov_write "$IF" 5
printf '%s\n' "$((REBOOT_LIMIT-1))" > "$TMP/etc/fm350-${IF}.reboot-guard"
tier="$(bearer_recover "$IF" probe 2>/dev/null)"
eq "reboots when guard below limit" "$tier" reboot
eq "reboot issued"                  "$(reboot_count)" 1
eq "guard incremented to the limit" "$(guard_read "$IF")" "$REBOOT_LIMIT"

echo "== reboot_limit=0 disables the reboot tier entirely (kill switch) =="
reset_state
recov_write "$IF" 5
REBOOT_LIMIT=0
tier="$(bearer_recover "$IF" probe 2>/dev/null)"
REBOOT_LIMIT=2
eq "reboot tier refused when reboot_limit=0" "$tier" reboot-refused
eq "no reboot issued with reboot_limit=0"    "$(reboot_count)" 0

# ==============================================================================
echo "== probe_ok: any reachable target is UP; all-fail is DOWN =="
H5TEST_PING_OK="8.8.8.8"; export H5TEST_PING_OK
probe_ok eth-test && ok "one reachable target -> up" || bad "one reachable target reported down (should be any-success)"
H5TEST_PING_OK=""; export H5TEST_PING_OK
probe_ok eth-test && bad "all targets unreachable but probe_ok said up" || ok "all targets unreachable -> down"
# Negative control: a single dead target must NOT drag the whole probe down.
H5TEST_PING_OK="9.9.9.9"; export H5TEST_PING_OK
probe_ok eth-test && ok "negative control: one live among dead -> up" || bad "a single dead target tripped probe_ok"

echo "== probe_recovered clears BOTH counters =="
reset_state
recov_write "$IF" 4
printf '1\n' > "$TMP/etc/fm350-${IF}.reboot-guard"
probe_recovered "$IF"
eq "recovery counter cleared" "$(recov_read "$IF")" 0
eq "reboot guard cleared"     "$(guard_read "$IF")" 0

echo "== a corrupt/malformed counter file reads as 0, never wedges recovery =="
reset_state
printf 'garbage\n' > "$TMP/run/fm350-${IF}.recov"
eq "malformed recov reads as 0" "$(recov_read "$IF")" 0

echo
echo "checks=${checks} failures=${fails}"
[ "$fails" -eq 0 ] || exit 1
echo "ALL FM350 RECOVERY-LADDER TESTS PASSED"
