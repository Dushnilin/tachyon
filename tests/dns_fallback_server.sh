#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/singbox/generator.uc"
FAILOVER="$TACHYON_LIB/singbox/dns_failover.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate() {
  local fixture="$1"
  local output="$2"
  local state="${3:-$WORK_DIR/missing-state.json}"
  TACHYON_LIB="$TACHYON_LIB" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$state" \
    ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$fixture" "$output" 192.168.1.1 0
}

# ─── Fixture 1: primary DoH + explicit fallback UDP ───────────────────────────
cat >"$WORK_DIR/with-fallback.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "dns.google/dns-query",
    "dns_fallback_server": [ "1.1.1.1", "8.8.8.8" ],
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

# ─── Fixture 2: two primary + two fallback (all four as candidates) ────────────
cat >"$WORK_DIR/multi-with-fallback.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
    "dns_fallback_server": [ "1.1.1.1", "8.8.8.8" ],
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

# ─── State: fallback active (index=1 points to first fallback) ────────────────
cat >"$WORK_DIR/fallback-state.json" <<'JSON'
{
  "version": 1,
  "dns_type": "doh",
  "dns_detour": "",
  "main_servers": [ "dns.google/dns-query", "1.1.1.1", "8.8.8.8" ],
  "bootstrap_servers": [ "77.88.8.8" ],
  "main_index": 1,
  "bootstrap_index": 0
}
JSON

# ─── State: second fallback active (index=2) ─────────────────────────────────
cat >"$WORK_DIR/fallback-state2.json" <<'JSON'
{
  "version": 1,
  "dns_type": "doh",
  "dns_detour": "",
  "main_servers": [ "dns.google/dns-query", "1.1.1.1", "8.8.8.8" ],
  "bootstrap_servers": [ "77.88.8.8" ],
  "main_index": 2,
  "bootstrap_index": 0
}
JSON

generate "$WORK_DIR/with-fallback.json" "$WORK_DIR/with-fallback-config.json"
generate "$WORK_DIR/with-fallback.json" "$WORK_DIR/fallback-active-config.json" "$WORK_DIR/fallback-state.json"
generate "$WORK_DIR/with-fallback.json" "$WORK_DIR/fallback-active2-config.json" "$WORK_DIR/fallback-state2.json"
generate "$WORK_DIR/multi-with-fallback.json" "$WORK_DIR/multi-with-fallback-config.json"

ucode -e '
let fs = require("fs");

function cfg(path) { return json(fs.readfile(path)); }
function assert(value, message) {
  if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
}
function find_tag(values, tag) {
  for (let value in values || []) if (value.tag == tag) return value;
  return null;
}
function count_prefix(values, prefix) {
  let count = 0;
  for (let value in values || []) if (index(value.tag || "", prefix) == 0) count++;
  return count;
}

// ─── Test 1: primary DoH, no failover state — uses primary server ─────────────
let primary = cfg(ARGV[0]);
let main_srv = find_tag(primary.dns.servers, "dns-server");
assert(main_srv != null, "dns-server tag must exist");
assert(main_srv.type == "https", "primary DNS must be DoH type");
assert(main_srv.server == "dns.google", "primary DNS server must be dns.google");

// ─── Test 2: fallback state active (index=1 = 1.1.1.1) ───────────────────────
// Explicit fallback servers MUST always be plain UDP regardless of dns_type
let fallback_active = cfg(ARGV[1]);
let fb_main = find_tag(fallback_active.dns.servers, "dns-server");
assert(fb_main != null, "dns-server must exist in fallback-active config");
assert(fb_main.type == "udp", "explicit fallback DNS must use UDP even when dns_type=doh");
assert(fb_main.server == "1.1.1.1", "fallback server index 1 must be 1.1.1.1");
assert(fb_main.detour == null, "explicit fallback must not use proxy detour");

// ─── Test 3: second fallback server (index=2 = 8.8.8.8) ──────────────────────
let fallback_active2 = cfg(ARGV[2]);
let fb_main2 = find_tag(fallback_active2.dns.servers, "dns-server");
assert(fb_main2 != null, "dns-server must exist in fallback-active2 config");
assert(fb_main2.type == "udp", "second explicit fallback must also be UDP");
assert(fb_main2.server == "8.8.8.8", "fallback server index 2 must be 8.8.8.8");

// ─── Test 4: multi-primary with fallback generates health candidates ──────────
let multi = cfg(ARGV[3]);
// 2 main health candidates + 2 fallback candidates + 1 active-main inbound = 5 health rules
let health_rules = 0;
for (let rule in multi.dns.rules || []) {
  if (index(rule.inbound || "", "dns-health-") == 0) {
    health_rules++;
    assert(rule.disable_cache === true, "health checks must bypass DNS cache");
  }
}
// We have 2 primary + 2 fallback = 4 main candidates (all generate health probes)
// Plus 1 bootstrap (single) = no bootstrap health
// Plus 1 active health inbound = total 5 DNS health rules
assert(health_rules == 5, "2 main + 2 fallback candidates + 1 active = 5 health rules, got " + health_rules);
assert(count_prefix(multi.dns.servers, "dns-health-main-") == 4, "4 main health servers (2 primary + 2 fallback)");

' "$WORK_DIR/with-fallback-config.json" \
  "$WORK_DIR/fallback-active-config.json" \
  "$WORK_DIR/fallback-active2-config.json" \
  "$WORK_DIR/multi-with-fallback-config.json"

# ─── Test 5: is_explicit_fallback_index logic via dns.uc ─────────────────────
ucode -L "$TACHYON_LIB" -e '
let runtime_dns = require("singbox.dns");
let common = require("core.common");

function assert(value, message) {
  if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
}

let settings_one_primary_two_fallback = {
  dns_server: [ "dns.google/dns-query" ],
  dns_fallback_server: [ "1.1.1.1", "8.8.8.8" ]
};
// configured_server_count: 1 (primary)
// explicit_fallback_count: 2
// index 0 = primary, index 1 = fallback, index 2 = fallback
assert(runtime_dns.is_explicit_fallback_index(settings_one_primary_two_fallback, 0) == false, "index 0 is primary, not fallback");
assert(runtime_dns.is_explicit_fallback_index(settings_one_primary_two_fallback, 1) == true, "index 1 is first explicit fallback");
assert(runtime_dns.is_explicit_fallback_index(settings_one_primary_two_fallback, 2) == true, "index 2 is second explicit fallback");
assert(runtime_dns.is_wan_fallback_index(settings_one_primary_two_fallback, 1) == false, "index 1 is NOT WAN fallback");
assert(runtime_dns.is_wan_fallback_index(settings_one_primary_two_fallback, 2) == false, "index 2 is NOT WAN fallback");

let settings_with_wan = {
  dns_server: [ "dns.google/dns-query" ],
  dns_fallback_server: [ "1.1.1.1" ],
  fallback_wan_main: "1"
};
// index 0 = primary, index 1 = explicit fallback, index 2+ = WAN
assert(runtime_dns.is_explicit_fallback_index(settings_with_wan, 1) == true, "index 1 is explicit fallback even with WAN enabled");
assert(runtime_dns.is_wan_fallback_index(settings_with_wan, 1) == false, "index 1 is NOT WAN (is explicit fallback)");
// WAN starts at index 2 (1 primary + 1 fallback)
assert(runtime_dns.is_wan_fallback_index(settings_with_wan, 2) == true, "index 2 is WAN fallback");

let settings_no_fallback = {
  dns_server: [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
  fallback_wan_main: "1"
};
// index 0,1 = primary, index 2+ = WAN (no explicit fallback)
assert(runtime_dns.is_explicit_fallback_index(settings_no_fallback, 1) == false, "index 1 is primary, no explicit fallback defined");
assert(runtime_dns.is_wan_fallback_index(settings_no_fallback, 2) == true, "index 2 is WAN fallback when no explicit fallback");
'

# ─── Test 6: server_list includes dns_fallback_server entries ─────────────────
ucode -L "$TACHYON_LIB" -e '
let runtime_dns = require("singbox.dns");

function assert(value, message) {
  if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
}

let settings = {
  dns_server: [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
  dns_fallback_server: [ "1.1.1.1", "8.8.8.8" ]
};

let servers = runtime_dns.server_list(settings, "dns_server", "77.88.8.8");
assert(length(servers) == 4, "server_list must include 2 primary + 2 fallback = 4 total");
assert(servers[0] == "dns.google/dns-query", "first server is primary[0]");
assert(servers[1] == "cloudflare-dns.com/dns-query", "second server is primary[1]");
assert(servers[2] == "1.1.1.1", "third server is fallback[0]");
assert(servers[3] == "8.8.8.8", "fourth server is fallback[1]");

// Bootstrap list must NOT include dns_fallback_server entries
let bootstrap = runtime_dns.server_list(settings, "bootstrap_dns_server", "77.88.8.8");
assert(length(bootstrap) == 1, "bootstrap list must not include dns_fallback_server entries");
assert(bootstrap[0] == "77.88.8.8", "bootstrap falls back to default");
'

printf 'DNS fallback server checks passed\n'
