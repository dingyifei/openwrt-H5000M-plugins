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

echo "== every LuCI resource module must RETURN a class =="
# The generalisation of the check above, added after the SAME trap was hit a second time.
# LuCI's require/compileClass treats a module's return value as a class and INSTANTIATES it, so
# a module ending in a plain object literal dies at load with
#   TypeError: "fm350.progress" factory yields invalid constructor
# and takes every page that requires it down with it. `node --check` passes either way.
#
# First occurrence: protocol/fm350.js with no `return` at all. Second: resources/fm350/progress.js
# returning `{ create: ..., outageWarning: ... }`. Both shipped. The valid shapes are a
# `.extend(` call - view.extend, L.Class.extend, form.Value.extend, network.registerProtocol -
# so the rule is simply: the module's `return` must hand back something built with `.extend(`
# or registerProtocol, never a bare object.
_mod=0
for f in $(find "$PKGDIR" -type f -path '*/luci-static/resources/*.js' | sort); do
	# Views and modules both qualify; anything under resources/ is require-able.
	if grep -qE '^[[:space:]]*return[[:space:]]+([A-Za-z_$.]+\.extend\(|network\.registerProtocol)' "$f"; then
		continue
	fi
	bad "$(basename "$f") does not return a class (LuCI will call it as a constructor)"
	_mod=1
done
[ "$_mod" -eq 0 ] && ok "all LuCI resource modules return a class"

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

echo "== LuCI rpcd backends: no serial access, lowest AT priority =="
# The single AT port is shared with the dialer that keeps the link up. A web backend that
# opened a tty directly would desynchronise it - the exact reason QModem was rejected - and
# one that polled at default priority could delay a reconnect.
for f in $(find "$PKGDIR" -type f -path '*/rpcd/ucode/*' | sort); do
	if code_of "$f" | grep -qE '/dev/tty'; then
		bad "$(basename "$f") references a tty directly"
	else
		ok "$(basename "$f") takes no direct serial access"
	fi
	if code_of "$f" | grep -q 'AT_PRIO=1'; then
		ok "$(basename "$f") polls at the lowest AT priority"
	else
		bad "$(basename "$f") does not set AT_PRIO=1"
	fi
done

echo "== ucode rpcd backends must live in /usr/share/rpcd/ucode =="
# /usr/libexec/rpcd is the EXEC plugin protocol (rpcd forks the file and parses stdout).
# A ucode script placed there is never loaded, and the only symptom is a missing menu entry.
if find "$PKGDIR" -type d -path '*/libexec/rpcd*' | grep -q .; then
	bad "a package ships into /usr/libexec/rpcd (wrong dir for ucode backends)"
else
	ok "no ucode backend in the exec-plugin directory"
fi

echo "== bounded waits must count down, not deadline against the wall clock =="
# This board has NO RTC (no /dev/rtc*, empty /sys/class/rtc), so the clock starts at the image
# build date and sysntpd STEPS it forward as soon as the network is up - which lands inside the
# dialer's 120s modem wait. A deadline built as `$(date +%s) + N` before that step is already in
# the past after it, so the loop exits on its first check with NO_MODEM + proto_block_restart and
# cellular stays down until a human runs `ifup`. Shipped exactly that way in three loops; all
# three are now decrementing counters, the same idiom at_flock_wait uses.
_clock=0
for f in $(find "$PKGDIR" -type f \( -path '*/files/usr/sbin/*' -o -path '*/files/usr/lib/*' \) | sort); do
	if code_of "$f" | grep -qE 'date[[:space:]]+\+%s'; then
		bad "$(basename "$f") derives a timeout from the wall clock (date +%s)"
		_clock=1
	fi
done
[ "$_clock" -eq 0 ] && ok "no wall-clock deadlines in timing loops"

echo "== the USB authorized window must be signal-isolated =="
# Deauthorising the modem and re-authorising 8s later is the only recovery for a deaf AT port.
# Run as a backgrounded popen() from the rpcd backend it sat in RPCD'S process group, so an
# `/etc/init.d/rpcd restart` mid-window - which LuCI triggers on package install - stranded the
# modem at authorized=0 until a power cycle. The window now lives in fm350-usb-reset under setsid.
# Match the WRITE, not the word: these backends legitimately explain the mechanism in `//`
# comments, which code_of() does not strip (it only knows `#`). Grepping for "authorized"
# flagged the explanation of the fix as the bug.
if find "$PKGDIR" -type f -path '*/rpcd/ucode/*' \
		-exec grep -lE '>[[:space:]]*/sys/bus/usb' {} \; | grep -q .; then
	bad "an rpcd backend writes the USB authorized flag directly"
else
	ok "rpcd backends delegate the USB reset window"
fi

echo "== LuCI app packages must reload rpcd in postinst =="
# Without it rpcd never loads the new backend or learns the new ACL group: the menu entry
# vanishes or every page reports "Access denied" until a reboot. luci.mk generates this
# automatically and these packages deliberately do not use luci.mk.
for mk in $(find "$PKGDIR" -maxdepth 2 -name Makefile -path '*luci-app-*' | sort); do
	if grep -q 'rpcd reload' "$mk"; then
		ok "$(basename "$(dirname "$mk")") reloads rpcd in postinst"
	else
		bad "$(basename "$(dirname "$mk")") has no rpcd reload in postinst"
	fi
done

echo
echo "checks=${checks} failures=${fails}"
[ "$fails" -eq 0 ] || exit 1
echo "ALL PLUGIN INVARIANTS PASSED"
