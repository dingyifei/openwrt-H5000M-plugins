#!/bin/sh
# Unit tests for the Travelmate uci-defaults script, runnable on the BUILD HOST with no device.
#
# The rules this proves are exactly the ones a mocked run can prove and a hardware run cannot:
# the script must (a) leave the same state when run twice, (b) create ZERO wifi-iface sections,
# (c) delete our SSID-less orphan STA VIF, and CRUCIALLY (d) never touch a section that carries
# an SSID - because a section with an SSID is a real Travelmate uplink the user configured, and
# the whole safety of the change is that one guard. An AP section must also survive untouched,
# and the trm_wwan DHCP interface plus its wan-zone membership must still be established.
#
# Why this exists: the script used to CREATE a disabled, SSID-less STA VIF as a "placeholder"
# for Travelmate to fill in. Travelmate never fills it - f_setif() matches a section's EXISTING
# ssid against its uplink list and never writes one - so the placeholder resolved enabled=0
# forever and LuCI rendered it as "SSID: ?". The fix removes the placeholder and reaps any orphan
# a prior release left, guarded so a real uplink is never reaped. These assertions pin that guard.
#
# `uci` and `logger` are stubbed on PATH: uci is STATEFUL here (unlike the read-only stub in
# test-log-library.sh) because the whole point is to observe the state the script leaves behind.
#
# Usage: tests/test-travelmate-defaults.sh [repo-root]
#   H5TEST_SCRIPT may override the script under test (used to run negative controls against a
#   deliberately-broken copy without touching the shipped file).
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="${H5TEST_SCRIPT:-${ROOT}/package/h5000m-travelmate-defaults/files/etc/uci-defaults/99-h5000m-travelmate}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
checks=0
ok()  { checks=$((checks+1)); printf '  [PASS] %s\n' "$1"; }
bad() { checks=$((checks+1)); fails=$((fails+1)); printf '  [FAIL] %s\n' "$1"; }

# --- Stateful uci + logger stubs on PATH --------------------------------------
# State lives in $H5TEST_UCI as flat `config.section[.option]=value` lines, i.e. `uci show`
# format WITHOUT the value quoting - the script compares against unquoted `uci get` output and
# its section-discovery sed matches unquoted `=wifi-iface`/`=wifi-device`/`=zone` type lines.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/logger" <<'EOF'
#!/bin/sh
# Record only the message (drop -t/-p) so assertions match on content.
while [ $# -gt 0 ]; do case "$1" in -t|-p) shift 2 ;; *) break ;; esac; done
printf '%s\n' "$*" >> "$H5TEST_LOG"
EOF
cat > "$TMP/bin/uci" <<'EOF'
#!/bin/sh
# Minimal STATEFUL uci: enough of show/get/set/delete/rename/add_list/commit to run the
# uci-defaults script and inspect its result. Not a general uci - just the verbs used here.
db="$H5TEST_UCI"
[ -f "$db" ] || : > "$db"
while [ $# -gt 0 ]; do case "$1" in -q) shift ;; *) break ;; esac; done
cmd="${1:-}"; shift 2>/dev/null || true

# Escape regex-significant characters so a key's dots match literally, never as wildcards.
re() { printf '%s' "$1" | sed 's/[][\\.^$*/]/\\&/g'; }

case "$cmd" in
	show)
		if [ -n "${1:-}" ]; then grep "^$(re "$1")\\." "$db"; else cat "$db"; fi
		;;
	get)
		line="$(grep "^$(re "$1")=" "$db" | head -n1)" || true
		[ -n "$line" ] || exit 1
		printf '%s\n' "${line#*=}"
		;;
	set)
		key="${1%%=*}"; val="${1#*=}"
		grep -v "^$(re "$key")=" "$db" > "$db.t" || true
		printf '%s=%s\n' "$key" "$val" >> "$db.t"
		mv "$db.t" "$db"
		;;
	delete)
		# Remove the key and, when it names a section, every option under it.
		grep -v "^$(re "$1")=" "$db" | grep -v "^$(re "$1")\\." > "$db.t" || true
		mv "$db.t" "$db"
		;;
	rename)
		old="${1%%=*}"; new="${old%%.*}.${1#*=}"
		sed "s|^$(re "$old")=|${new}=|; s|^$(re "$old")\\.|${new}.|" "$db" > "$db.t"
		mv "$db.t" "$db"
		;;
	add_list)
		key="${1%%=*}"; val="${1#*=}"
		cur="$(grep "^$(re "$key")=" "$db" | head -n1)" || true
		if [ -n "$cur" ]; then
			grep -v "^$(re "$key")=" "$db" > "$db.t" || true
			printf '%s=%s %s\n' "$key" "${cur#*=}" "$val" >> "$db.t"
			mv "$db.t" "$db"
		else
			printf '%s=%s\n' "$key" "$val" >> "$db"
		fi
		;;
	commit) : ;;
	*) : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/logger" "$TMP/bin/uci"
PATH="$TMP/bin:$PATH"; export PATH

# --- Harness ------------------------------------------------------------------
H5TEST_UCI="$TMP/uci.txt"; H5TEST_LOG="$TMP/log.txt"
export H5TEST_UCI H5TEST_LOG

seed()  { cat > "$H5TEST_UCI"; : > "$H5TEST_LOG"; }              # stdin -> fresh config, fresh log
runsh() { sh "$SCRIPT" >/dev/null 2>&1; }                        # one run of the script under test
# uci get through the stub, for assertions
u() { PATH="$TMP/bin:$PATH" uci -q get "$1"; }
# number of wifi-iface sections currently in the config. grep -c already prints 0 on no
# match (and then exits 1), so swallow only the status - never add a second `echo 0`.
ifaces() { grep -c '=wifi-iface$' "$H5TEST_UCI" 2>/dev/null || true; }
# a section's presence (its type line)
has_section() { grep -q "^$1=" "$H5TEST_UCI"; }

# ==============================================================================
echo "== creates zero STA VIFs and is idempotent =="
# Radio present, no STA at all. The script must not conjure one, and a second run must be a
# no-op (state identical). This is the "exactly one -> now zero" half of the old placeholder.
seed <<'EOF'
wireless.radio0=wifi-device
wireless.radio0.band=2g
firewall.wanzone=zone
firewall.wanzone.name=wan
firewall.wanzone.network=wan
EOF
runsh
snap1="$(sort "$H5TEST_UCI")"
[ "$(ifaces)" -eq 0 ] && ok "no wifi-iface section created" || bad "script created a wifi-iface section (count=$(ifaces))"
runsh
snap2="$(sort "$H5TEST_UCI")"
[ "$snap1" = "$snap2" ] && ok "second run is a no-op (idempotent)" || bad "second run changed the config (not idempotent)"

echo "== establishes trm_wwan DHCP interface and wan-zone membership =="
[ "$(u network.trm_wwan)" = interface ] && ok "network.trm_wwan created as interface" || bad "network.trm_wwan not created"
[ "$(u network.trm_wwan.proto)" = dhcp ] && ok "trm_wwan proto is dhcp" || bad "trm_wwan proto not dhcp"
case " $(u firewall.wanzone.network) " in *" trm_wwan "*) ok "trm_wwan added to wan zone" ;; *) bad "trm_wwan not in wan zone" ;; esac
case " $(u firewall.wanzone.network) " in *" wan "*) ok "existing wan-zone member preserved" ;; *) bad "clobbered the existing wan-zone network list" ;; esac

# ==============================================================================
echo "== a real configured uplink SURVIVES untouched (the load-bearing guard) =="
# mode=sta + network=trm_wwan but WITH an ssid and key: this is a real Travelmate uplink.
# It must be left exactly as-is. This is the assertion the entire change hinges on.
seed <<'EOF'
wireless.radio0=wifi-device
wireless.radio0.band=2g
wireless.uplink=wifi-iface
wireless.uplink.device=radio0
wireless.uplink.mode=sta
wireless.uplink.network=trm_wwan
wireless.uplink.ssid=SomeCafe
wireless.uplink.key=hunter2pass
wireless.uplink.disabled=0
firewall.wanzone=zone
firewall.wanzone.name=wan
firewall.wanzone.network=wan
EOF
runsh; runsh
has_section wireless.uplink && ok "real uplink section still present" || bad "real uplink section was deleted"
[ "$(u wireless.uplink.ssid)" = SomeCafe ]    && ok "uplink ssid preserved"     || bad "uplink ssid changed/removed"
[ "$(u wireless.uplink.key)" = hunter2pass ]  && ok "uplink key preserved"      || bad "uplink key changed/removed"
[ "$(u wireless.uplink.disabled)" = 0 ]       && ok "uplink left enabled"       || bad "uplink was disabled"

# ==============================================================================
echo "== an SSID-less orphan STA VIF is REMOVED, and the removal is logged once =="
seed <<'EOF'
wireless.radio1=wifi-device
wireless.radio1.band=5g
wireless.h5000m_sta=wifi-iface
wireless.h5000m_sta.device=radio1
wireless.h5000m_sta.mode=sta
wireless.h5000m_sta.network=trm_wwan
wireless.h5000m_sta.disabled=1
firewall.wanzone=zone
firewall.wanzone.name=wan
firewall.wanzone.network=wan
EOF
runsh
has_section wireless.h5000m_sta && bad "orphan STA VIF was NOT removed" || ok "orphan STA VIF removed"
[ "$(ifaces)" -eq 0 ] && ok "no wifi-iface sections remain" || bad "a wifi-iface section survived (count=$(ifaces))"
grep -qi 'remov' "$H5TEST_LOG" && ok "removal was logged" || bad "removal was not logged"
logs1="$(grep -ci 'remov' "$H5TEST_LOG" 2>/dev/null || true)"
runsh
logs2="$(grep -ci 'remov' "$H5TEST_LOG" 2>/dev/null || true)"
[ "$logs1" = "$logs2" ] && ok "second run logs nothing (no orphan left to remove)" || bad "second run logged a removal with nothing to remove"

echo "== an empty-string ssid also counts as orphan =="
seed <<'EOF'
wireless.radio1=wifi-device
wireless.radio1.band=5g
wireless.h5000m_sta=wifi-iface
wireless.h5000m_sta.mode=sta
wireless.h5000m_sta.network=trm_wwan
wireless.h5000m_sta.ssid=
wireless.h5000m_sta.disabled=1
firewall.wanzone=zone
firewall.wanzone.name=wan
firewall.wanzone.network=wan
EOF
runsh
has_section wireless.h5000m_sta && bad "empty-ssid orphan was NOT removed" || ok "empty-ssid orphan removed"

# ==============================================================================
echo "== unrelated sections are never touched =="
# An AP (mode=ap) and a foreign-network STA (network!=trm_wwan) must both survive: the guard
# is mode=sta AND network=trm_wwan AND no-ssid, all three. Break any conjunct and one of these
# innocents dies - which is exactly what the negative controls verify.
seed <<'EOF'
wireless.radio0=wifi-device
wireless.radio0.band=2g
wireless.ap0=wifi-iface
wireless.ap0.device=radio0
wireless.ap0.mode=ap
wireless.ap0.ssid=HomeAP
wireless.ap0.network=lan
wireless.other=wifi-iface
wireless.other.mode=sta
wireless.other.network=wwan2
wireless.orphan=wifi-iface
wireless.orphan.mode=sta
wireless.orphan.network=trm_wwan
firewall.wanzone=zone
firewall.wanzone.name=wan
firewall.wanzone.network=wan
EOF
runsh
has_section wireless.ap0 && ok "AP section untouched" || bad "AP section was deleted"
[ "$(u wireless.ap0.ssid)" = HomeAP ] && ok "AP ssid preserved" || bad "AP ssid changed"
has_section wireless.other && ok "foreign-network STA (network!=trm_wwan) untouched" || bad "foreign-network STA was deleted"
has_section wireless.orphan && bad "trm_wwan orphan not removed alongside innocents" || ok "trm_wwan orphan removed, innocents kept"

echo
echo "checks=${checks} failures=${fails}"
[ "$fails" -eq 0 ] || exit 1
echo "ALL TRAVELMATE DEFAULTS TESTS PASSED"
