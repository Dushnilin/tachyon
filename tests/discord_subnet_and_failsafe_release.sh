#!/usr/bin/env bash
# Two defects from the report that followed 75d3f9a6.
#
#  Discord subnet  DISCORD_DEDICATED_SUBNETS was 162.159.128.0/21, which stops at
#      .135.255. Discord's own DNS answers on .136, .137 and .138 as well, so
#      roughly half of the addresses a resolver hands out fell outside the
#      Discord section and reached it with no zapret applied. The whole /20 is
#      CLOUDFLARENET per RIPE, the operator Discord already runs on, so widening
#      it sweeps in nothing unrelated.
#
#  Emergency failsafe  The L5 failsafe writes /etc/tachyon/emergency_state.json,
#      which lives on the overlay and so survives a reboot. Nothing cleared it
#      but the emergency-reset CLI, so a router that recovered kept reporting
#      emergency_failsafe and kept bypassing the proxy indefinitely. Clearing has
#      to rebuild the nft runtime first, otherwise the flag reports healthy while
#      the router stays in bypass.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

IP_UC="$TACHYON_LIB/core/ip.uc"
WATCHDOG="$TACHYON_LIB/service/watchdog.uc"
[ -f "$IP_UC" ] || fail "core/ip.uc not found"
[ -f "$WATCHDOG" ] || fail "service/watchdog.uc not found"

# --- the subnet, checked against the addresses Discord actually serves -----
# print() renders the array directly; strip the decoration rather than build
# strings in ucode, where += and push are not available in -e scripts.
printed="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let core_ip = require("core.ip");
print(core_ip.DISCORD_DEDICATED_SUBNETS);
')" || true
subnets="$(printf '%s' "$printed" | tr -d '[]" ' | tr -s ' ')"
[ "$subnets" = "162.159.128.0/20" ] ||
  fail "DISCORD_DEDICATED_SUBNETS must be 162.159.128.0/20, got '$subnets'"
ok

# Every address Discord's DNS hands out has to fall inside the configured set.
# From a live lookup: discord.com answers on .128, .135, .136, .137 and .138.
ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

in_cidr() {
  local ip="$1" cidr="$2" bits ipn netn mask
  bits="${cidr#*/}"
  ipn="$(ip_to_int "$ip")"
  netn="$(ip_to_int "${cidr%%/*}")"
  if [ "$bits" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  fi
  [ $(( ipn & mask )) -eq $(( netn & mask )) ]
}

base="${subnets%%/*}"
prefix="${subnets#*/}"
missing=""
for a in 162.159.128.233 162.159.135.232 162.159.136.232 162.159.137.232 \
         162.159.138.232 162.159.136.234 162.159.137.234 162.159.138.234; do
  in_cidr "$a" "$base/$prefix" || missing="$missing $a"
done
[ -z "$missing" ] ||
  fail "these live Discord addresses fall outside $base/$prefix and would bypass the section:$missing"
ok

# The literals in the nft and singbox fallbacks must not drift back to /21.
for f in "$TACHYON_LIB/nft/apply.uc" "$TACHYON_LIB/singbox/generator_routes.uc"; do
  [ -f "$f" ] || fail "missing $f"
  if grep -q '162\.159\.128\.0/21' "$f"; then
    fail "$f still falls back to the /21 literal; the constant and the fallback must agree"
  fi
  ok
done

# --- the failsafe has to release itself once the proxy is back ------------
grep -q 'function release_emergency_failsafe_if_recovered' "$WATCHDOG" ||
  fail "watchdog.uc must release the failsafe on its own; today only the emergency-reset CLI clears it"
ok

subscribed="$(grep -c 'release_emergency_failsafe_if_recovered,' "$WATCHDOG" || true)"
[ "$subscribed" -ge 2 ] ||
  fail "the release handler must be subscribed to recovery events, found $subscribed subscription(s)"
ok

# Clearing the flag without rebuilding nft would report healthy while the router
# still bypasses the proxy, so the rebuild has to happen inside the handler.
handler="$(sed -n '/^function release_emergency_failsafe_if_recovered/,/^}/p' "$WATCHDOG")"
printf '%s' "$handler" | grep -q 'reload-firewall' ||
  fail "the handler must rebuild the nft runtime (lifecycle reload-firewall) before clearing, or the router stays in bypass while reporting healthy"
ok

printf '%s' "$handler" | grep -q 'healthy_streak' ||
  fail "one recovered probe must not be enough; require a settled healthy streak so a flapping proxy does not clear the failsafe"
ok

printf 'discord subnet and failsafe release: %d checks passed\n' "$pass_count"
printf 'PASS: discord_subnet_and_failsafe_release\n'