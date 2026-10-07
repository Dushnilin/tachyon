#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR="$TACHYON_LIB/singbox/generator.uc"

generate() {
  local fixture="$1"
  local output="$2"
  local state="${3:-$WORK_DIR/missing-state.json}"
  TACHYON_LIB="$TACHYON_LIB" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$state" \
    ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$fixture" "$output" 192.168.1.1 0
}

# ─── Fixture 1: DoH with mTLS enabled ─────────────────────────────────────────
cat >"$WORK_DIR/mtls-doh.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "https://dns.example.net/api/v1/router-doh",
    "bootstrap_dns_server": "77.88.8.8",
    "dns_mtls_enabled": "1",
    "dns_mtls_host": "dns.example.net",
    "dns_mtls_client_certificate": "/etc/tachyon/mtls/client.crt",
    "dns_mtls_client_key": "/etc/tachyon/mtls/client.key",
    "dns_mtls_ca": "/etc/tachyon/mtls/ca.crt"
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

# ─── Fixture 2: DoH with mTLS disabled ────────────────────────────────────────
cat >"$WORK_DIR/mtls-disabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "https://dns.example.net/api/v1/router-doh",
    "bootstrap_dns_server": "77.88.8.8",
    "dns_mtls_enabled": "0",
    "dns_mtls_host": "dns.example.net",
    "dns_mtls_client_certificate": "/etc/tachyon/mtls/client.crt",
    "dns_mtls_client_key": "/etc/tachyon/mtls/client.key"
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

# ─── Fixture 3: DoH with host mismatch ────────────────────────────────────────
cat >"$WORK_DIR/mtls-mismatch.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "https://dns.example.net/api/v1/router-doh",
    "bootstrap_dns_server": "77.88.8.8",
    "dns_mtls_enabled": "1",
    "dns_mtls_host": "other.example.net",
    "dns_mtls_client_certificate": "/etc/tachyon/mtls/client.crt",
    "dns_mtls_client_key": "/etc/tachyon/mtls/client.key"
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
# ─── Fixture 4: DoH failover (two servers, mTLS on first) ───────────────────
cat >"$WORK_DIR/mtls-failover.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "https://dns.example.net/api/v1/router-doh", "https://dns.google/dns-query" ],
    "bootstrap_dns_server": "77.88.8.8",
    "dns_mtls_enabled": "1",
    "dns_mtls_host": "dns.example.net",
    "dns_mtls_client_certificate": "/etc/tachyon/mtls/client.crt",
    "dns_mtls_client_key": "/etc/tachyon/mtls/client.key",
    "dns_mtls_ca": "/etc/tachyon/mtls/ca.crt"
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

generate "$WORK_DIR/mtls-doh.json" "$WORK_DIR/mtls-doh-config.json"
generate "$WORK_DIR/mtls-disabled.json" "$WORK_DIR/mtls-disabled-config.json"
generate "$WORK_DIR/mtls-mismatch.json" "$WORK_DIR/mtls-mismatch-config.json"
generate "$WORK_DIR/mtls-failover.json" "$WORK_DIR/mtls-failover-config.json"

ucode -e '
let fs = require("fs");

function cfg(path) { return json(fs.readfile(path)); }
function assert(value, message) {
  if (!value) { warn("FAIL: ", message, "\n"); exit(1); }
}

let c1 = cfg("'"$WORK_DIR"'/mtls-doh-config.json");
let c2 = cfg("'"$WORK_DIR"'/mtls-disabled-config.json");
let c3 = cfg("'"$WORK_DIR"'/mtls-mismatch-config.json");
let c4 = cfg("'"$WORK_DIR"'/mtls-failover-config.json");

// 1. In c1 (mTLS enabled, matching host):
let main1 = null;
for (let s in c1.dns.servers) {
  if (s.tag == "dns-server") main1 = s;
}
assert(main1 != null, "dns-server exists");
assert(main1.type == "https", "dns-server is https (DoH)");
assert(main1.server == "dns.example.net", "dns-server host matches");
assert(main1.path == "/api/v1/router-doh", "dns-server custom path preserved");
assert(main1.tls != null, "tls object present");
assert(main1.tls.enabled == true, "tls enabled");
assert(main1.tls.client_certificate_path == "/etc/tachyon/mtls/client.crt", "client certificate path matches");
assert(main1.tls.client_key_path == "/etc/tachyon/mtls/client.key", "client key path matches");
assert(main1.tls.certificate_path == "/etc/tachyon/mtls/ca.crt", "ca certificate path matches");

// 2. In c2 (mTLS disabled):
let main2 = null;
for (let s in c2.dns.servers) {
  if (s.tag == "dns-server") main2 = s;
}
assert(main2 != null, "c2 dns-server exists");
assert(main2.tls != null && main2.tls.client_certificate_path == null, "c2 client cert must not be set");
assert(main2.tls != null && main2.tls.client_key_path == null, "c2 client key must not be set");

// 3. In c3 (mTLS enabled, host mismatch):
let main3 = null;
for (let s in c3.dns.servers) {
  if (s.tag == "dns-server") main3 = s;
}
assert(main3 != null, "c3 dns-server exists");
assert(main3.tls != null && main3.tls.client_certificate_path == null, "c3 client cert must not be set on host mismatch");

// 4. In c4 (failover candidate 1 gets mTLS, candidate 2 does not):
let health1 = null;
let health2 = null;
for (let s in c4.dns.servers) {
  if (s.tag == "dns-health-main-1-server") health1 = s;
  if (s.tag == "dns-health-main-2-server") health2 = s;
}
assert(health1 != null, "health1 server exists");
assert(health1.tls != null && health1.tls.client_certificate_path == "/etc/tachyon/mtls/client.crt", "health1 has client cert");
assert(health2 != null, "health2 server exists");
assert(health2.tls != null && health2.tls.client_certificate_path == null, "health2 has no client cert");

print("PASS: DoH mTLS options test passed\n");
'
