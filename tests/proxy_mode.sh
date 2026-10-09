#!/usr/bin/env bash
# proxy_mode is one setting with three answers, and each one has to remove
# something as well as add something:
#
#   socks  - a client listener, and no transparent interception at all
#   tproxy - the historical behaviour: a tproxy socket that nft steers into
#   tun    - the core owns the routes, so nft must not also steer
#
# The failure this guards against is the overlap. tun and socks both have to take
# the tproxy redirect out of the ruleset: in tun mode the kernel's policy routing
# sends traffic into tun0 while a stale redirect would hand the same packets to a
# listener nothing is steering towards, and the two fight.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="$TACHYON_LIB"
GEN="$LIB_DIR/singbox/generator.uc"
NFT="$LIB_DIR/nft/apply.uc"
VAL="$LIB_DIR/config/validator.uc"

pass_count=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass_count=$((pass_count + 1)); }

mode_is() {
  value="$1"
  out="$(ucode -L "$LIB_DIR" "$VAL" proxy-mode-valid "$value" 2>/dev/null && echo yes || echo no)"
  [ "$out" = yes ] || fail "proxy_mode '$value' was not recognised as the active mode"
  ok
}

rejects() {
  value="$1"
  if ucode -L "$LIB_DIR" "$VAL" proxy-mode-valid "$value" >/dev/null 2>&1; then
    fail "proxy_mode '$value' was accepted; an unknown mode would silently switch behaviour"
  fi
  ok
}

mode_is socks
mode_is tproxy
mode_is tun
rejects ""
rejects socks5
rejects transparent
rejects "tun0"

# ─── the capability table knows about tun as an inbound ─────────────────────
# A core that has no tun inbound cannot be asked for one: the generator would
# otherwise write a section the binary rejects and `sing-box check` would take
# the whole config down over it.
ucode -L "$LIB_DIR" "$LIB_DIR/singbox/runtime.uc" core-supports-inbound tun "0.0.1-tachyon.0" \
  || fail "tachyon-core must report a tun inbound; it implements one on smoltcp"
ok
ucode -L "$LIB_DIR" "$LIB_DIR/singbox/runtime.uc" core-supports-inbound tun "1.15.0" \
  || fail "upstream sing-box must report a tun inbound"
ok

# ─── the generator honours the mode ─────────────────────────────────────────
# These grep the generator rather than running it: the alternative needs a full
# UCI fixture per mode, and what is being checked here is that the mode reaches
# the inbound list at all - the shape of the generated file is the preflight
# tests' job.
grep -q 'proxy_mode(settings) != "tun"' "$GEN" \
  || fail "the tun inbound is no longer gated on proxy_mode"
ok
grep -q 'if (mode == "tproxy")' "$GEN" \
  || fail "the tproxy inbound is no longer conditional on the mode"
ok
grep -q 'if (mode == "socks")' "$GEN" \
  || fail "socks mode does not add a client-facing listener"
ok

# ─── nft takes the redirect out ────────────────────────────────────────────
# The rules are skipped whole rather than made conditional one by one: marking a
# packet without redirecting it is harmless, redirecting it to a socket nobody is
# steering towards is not.
grep -q 'function tproxy_intercept_enabled' "$NFT" \
  || fail "nft has no way to ask whether transparent interception is wanted"
ok
grep -q '!tproxy_intercept_enabled() ||' "$NFT" \
  || fail "the tproxy redirect rules are no longer gated by the mode"
ok

# A typo in the mode must not read as tproxy in the firewall layer while reading
# as something else in the generator - the two gates are separate functions, so
# both have to exclude the same two values.
grep -q 'mode != "socks" && mode != "tun"' "$NFT" \
  || fail "nft does not exclude both socks and tun from interception"
ok

echo "ok - $pass_count checks passed"