#!/usr/bin/env bash
# The FakeIP cache must survive a reboot, and saying so when it does not.
#
# sing-box hands out addresses from the FakeIP pool and keeps the reverse
# mapping. Clients (and dnsmasq) cache the address they were given, so if the
# mapping is gone when a packet arrives, the core logs "missing fakeip record"
# and that connection dies. The mapping therefore has to outlive a reboot: the
# only client that can repair the mismatch is the client, and it will not.
#
# The default path used to be /tmp/sing-box/cache.db, which is tmpfs. Both
# routers checked carry /usr/share/sing-box/cache.db instead, so the deployed
# behaviour and the generated default disagreed - and a router following the
# default would lose every mapping on each reboot.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GEN_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/generator.uc"

[ -f "$GEN_UC" ] || fail "singbox/generator.uc not found"

# --- the default must be on persistent storage ------------------------------
default_path="$(grep -oE 'option\(settings, "cache_path", "[^"]*"\)' "$GEN_UC" | head -1 | sed -E 's/.*"cache_path", "([^"]*)".*/\1/')"
[ -n "$default_path" ] || fail "could not read the default cache_path"

case "$default_path" in
  /tmp/*|/var/run/*|/var/tmp/*)
    fail "the default FakeIP cache path is $default_path (volatile storage): every reboot drops the domain mappings and the next packet for a cached address fails with 'missing fakeip record'"
    ;;
esac

# The directory is created, not just the file named.
grep -q 'fs.mkdir(cache_dir' "$GEN_UC" ||
  fail "the cache directory is never created, so a fresh install would fail to start"

# --- and a volatile override must not be silent -----------------------------
grep -q 'cache_path_on_volatile' "$GEN_UC" ||
  fail "pointing the cache at volatile storage is not detected"
# The warning has to actually be emitted, not merely computed.
grep -qE 'generator_log\(|log_message\(|log_warn\(' "$GEN_UC" ||
  fail "the volatility check never reaches a logger"

printf 'fakeip cache persistence: checks passed\n'
