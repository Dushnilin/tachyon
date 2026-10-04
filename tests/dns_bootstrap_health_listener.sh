#!/usr/bin/env bash
# The failover worker probes a single server - so the health listener must exist.
#
# dns_failover.uc's choose_index deliberately probes a kind even when it holds
# only one server (commit 93195fdb: "a single dead resolver reported as alive"):
# a dead lone resolver must not be reported as alive. The probe digs the health
# port returned by dns.uc health_port(). But dns.uc only emitted the listener
# when the kind held more than one server, so on the common multi-main /
# single-bootstrap configuration the probe always hit a port nothing binds:
#
#   [warn] all configured bootstrap DNS servers are unavailable
#           (PROBE_DETAIL: port 10054 no A for example.com in 2s x2;
#            dig said: connection refused)
#
# logged on every start of 192.168.1.205 while DNS worked fine - the warning
# was produced by the missing listener, not by the resolver.
#
# The listener now exists whenever failover is active at all (mirroring the
# worker's own early return, which only stays silent when both kinds are
# single), and a fully single-server config still gets none, because no probe
# ever runs there.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR="$TACHYON_LIB/singbox/generator.uc"

generate() {
  local fixture="$1"
  local output="$2"
  TACHYON_LIB="$TACHYON_LIB" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-state.json" \
    ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$fixture" "$output" 192.168.1.1 0
}

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# Fixture A: several main servers, one bootstrap - the router's shape.
cat >"$WORK_DIR/multi-main-one-boot.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
    "bootstrap_dns_server": "77.88.8.8"
  },
"section": [
    {
      ".name": "direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

# Fixture B: one main, one bootstrap - failover inactive, worker never starts.
cat >"$WORK_DIR/single-single.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "dns.google/dns-query",
    "bootstrap_dns_server": "77.88.8.8"
  },
"section": [
    {
      ".name": "direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

# Fixture C: one main, two bootstraps - failover active, main is the lone one.
cat >"$WORK_DIR/one-main-multi-boot.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "dns.google/dns-query",
    "bootstrap_dns_server": [ "77.88.8.8", "77.88.54.54" ]
  },
"section": [
    {
      ".name": "direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

generate "$WORK_DIR/multi-main-one-boot.json" "$WORK_DIR/a.json"
generate "$WORK_DIR/single-single.json" "$WORK_DIR/b.json"
generate "$WORK_DIR/one-main-multi-boot.json" "$WORK_DIR/c.json"

# A: the single bootstrap must have a listener, or the probe's
# "connection refused" is indistinguishable from a dead resolver.
grep -Fq '"listen_port": 10054' "$WORK_DIR/a.json" ||
  fail "multi-main/one-bootstrap config is missing the bootstrap health listener (port 10054):
$(grep -o '"listen[^,]*' "$WORK_DIR/a.json" | head -20)"
ok
grep -Fq 'dns-health-bootstrap-1-in' "$WORK_DIR/a.json" ||
  fail "bootstrap health inbound tag missing in A"
ok
grep -Fq '"listen_port": 10053' "$WORK_DIR/a.json" ||
  fail "main health listener (port 10053) missing in A"
ok

# B: both kinds single - the worker returns before any probe, so no listeners.
if grep -Fq '"listen_port": 10053' "$WORK_DIR/b.json" ||
   grep -Fq '"listen_port": 10054' "$WORK_DIR/b.json"; then
  fail "a fully single-server config must keep no health listeners (no probe ever runs)"
fi
ok
if grep -Fq 'dns-health-' "$WORK_DIR/b.json"; then
  fail "single-server config contains health machinery it can never use"
fi
ok

# C: lone main inside an active failover still needs its listener (the worker
# probes it whenever a bootstrap candidate switches).
grep -Fq '"listen_port": 10053' "$WORK_DIR/c.json" ||
  fail "one-main/multi-bootstrap config is missing the main health listener (port 10053)"
ok
grep -Fq '"listen_port": 10054' "$WORK_DIR/c.json" ||
  fail "bootstrap health listener missing in C"
ok

# The port formula itself is part of the contract: without it the worker and
# the config would drift apart again.
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let dns = require("singbox.dns");
function assert(v, m) { if (!v) { warn("FAIL: ", m, "\n"); exit(1); } }
assert(dns.health_port("bootstrap", 0) == 10054, "bootstrap port 0 must be 10054");
assert(dns.health_port("main", 0) == 10053, "main port 0 must be 10053");
assert(dns.health_port("active", 0) == 12053, "active port must sit above the candidate range");
'
ok

printf 'dns bootstrap health listener: %d checks passed\n' "$pass_count"
printf 'PASS: dns_bootstrap_health_listener\n'
