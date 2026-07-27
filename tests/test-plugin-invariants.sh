#!/bin/sh
# Static invariants for every custom package. Each assertion below exists because the
# corresponding mistake was actually made (or nearly made) during Stage 2, not as
# hypothetical hygiene.
#
# Usage: tests/test-plugin-invariants.sh [repo-root]
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PKGDIR="${ROOT}/package"
fails=0
checks=0

ok()   { checks=$((checks+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { checks=$((checks+1)); fails=$((fails+1)); printf '  [FAIL] %s\n' "$1"; }

# Strip comments and blank lines so assertions test CODE, not prose. Every one of these
# rules is discussed at length in comments, so a naive grep would flag its own docs.
code_of() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

echo "== shell syntax =="
for f in $(find "$PKGDIR" -type f \
		\( -path '*/files/usr/sbin/*' -o -path '*/files/usr/lib/*' \
		   -o -path '*/files/etc/uci-defaults/*' -o -path '*/files/etc/hotplug.d/*' \
		   -o -path '*/files/lib/netifd/*' \) | sort); do
	if sh -n "$f" 2>/dev/null; then ok "syntax $(basename "$f")"
	else bad "syntax $(basename "$f")"; fi
done

echo "== no bashisms (base ships busybox ash, not bash) =="
for f in $(find "$PKGDIR" -type f -path '*/files/*' | sort); do
	if code_of "$f" | grep -qE '\[\[|\bmapfile\b|<<<|\bdeclare\b|\$\{[A-Za-z_]+,,'; then
		bad "bashism in $(basename "$f")"
	fi
done
[ "$fails" -eq 0 ] && ok "no bashisms found"

echo "== netifd proto must never set keep =="
# proto_set_keep 1 leaves the previous address attached when the network renumbers us,
# giving two addresses and traffic sourced from the dead one: a silent, total loss of
# the uplink that presents as a carrier fault.
if find "$PKGDIR" -type f -path '*/files/*' -exec sh -c 'code_of() { sed -e "s/[[:space:]]*#.*$//" "$1"; }; code_of "$1"' _ {} \; \
		| grep -qE 'proto_set_keep[[:space:]]+1'; then
	bad "proto_set_keep 1 is present"
else
	ok "proto_set_keep 1 absent"
fi

echo "== no hard-coded modem/net device names =="
# The whole point of sysfs discovery and the custom netifd proto is that ttyUSB and RNDIS
# names renumber. A literal name in code silently works on the bench and fails in the field.
hard=0
for f in $(find "$PKGDIR" -type f -path '*/files/*' | sort); do
	if code_of "$f" | grep -qE '/dev/ttyUSB[0-9]|["= ]eth[0-9]'; then
		bad "hard-coded device name in $(basename "$f")"
		hard=1
	fi
done
[ "$hard" -eq 0 ] && ok "no hard-coded device names"

echo "== no credentials =="
if find "$PKGDIR" -type f -path '*/files/*' \
		-exec grep -lEi 'tskey-|LPA:1\$|psk[[:space:]]*=|password[[:space:]]*=|\bkey=[^$]' {} \; \
		| grep -q .; then
	bad "possible credential material in package files"
else
	ok "no credential material"
fi

echo "== busybox flock has no -w; bounded waits must use -n + retry =="
if find "$PKGDIR" -type f -path '*/files/*' -exec sh -c 'sed -e "s/[[:space:]]*#.*$//" "$1"' _ {} \; \
		| grep -qE 'flock[^|]*[[:space:]]-w[[:space:]]'; then
	bad "flock -w used (unsupported by busybox; reads as 'port busy')"
else
	ok "no flock -w"
fi

echo "== netifd proto commands must not use 'set -u' =="
# /lib/functions.sh dereferences $IPKG_INSTROOT unset, so set -u kills the script on
# source; netifd then respawns it immediately, producing a restart storm.
for f in "$PKGDIR"/*/files/usr/sbin/*dialer; do
	[ -f "$f" ] || continue
	if code_of "$f" | grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*u'; then
		bad "$(basename "$f") uses set -u"
	else
		ok "$(basename "$f") does not use set -u"
	fi
done

echo "== LuCI protocol handlers must RETURN the registered class =="
# Shipped broken: fm350.js called network.registerProtocol() without `return`, so LuCI's
# require/compileClass got undefined and the interface page died with
#   TypeError: "protocol.fm350" factory yields invalid constructor
# `node --check` passes either way, because this is a contract violation and not a syntax
# error - which is exactly why no existing check caught it.
for f in $(find "$PKGDIR" -type f -path '*/resources/protocol/*.js' | sort); do
	if grep -qE '^[[:space:]]*return[[:space:]]+network\.registerProtocol' "$f"; then
		ok "$(basename "$f") returns its protocol class"
	else
		bad "$(basename "$f") calls registerProtocol without return"
	fi
done

echo "== uci-defaults must not create anonymous wireless sections =="
# `uci add wireless wifi-iface` yields an anonymous section, which is precisely what LuCI's
# wireless-migration prompt exists to rewrite - and it restarts the network to do it. Name
# the section instead so a fresh flash never greets the user with that dialog.
_anon=0
for f in $(find "$PKGDIR" -type f -path '*/files/etc/uci-defaults/*' | sort); do
	code_of "$f" | grep -qE 'uci[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*add[[:space:]]+wireless' \
		&& _anon=1
done
if [ "$_anon" -eq 1 ]; then
	bad "uci add wireless creates an anonymous section"
else
	ok "no anonymous wireless sections created"
fi

echo
echo "checks=${checks} failures=${fails}"
[ "$fails" -eq 0 ] || exit 1
echo "ALL PLUGIN INVARIANTS PASSED"
