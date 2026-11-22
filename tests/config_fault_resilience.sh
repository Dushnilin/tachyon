#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"

export TACHYON_VALIDATOR_QUARANTINED_FILE="$WORK_DIR/val-quarantined.json"
export TACHYON_SECTION_ERRORS_FILE="$WORK_DIR/section-errors.json"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/core-version"
printf '0.5.7\n' >"$TACHYON_CORE_VERSION_FILE"

cat >"$WORK_DIR/val_bad_settings.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "bittorrent_policy": "broken_policy"
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ]
    }
  ]
}
JSON

# 1. Quarantine mode must isolate _settings error and keep healthy good_sec active.
rm -f "$TACHYON_VALIDATOR_QUARANTINED_FILE" "$TACHYON_SECTION_ERRORS_FILE"
val_out="$(ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_bad_settings.json")"
grep -Fq '"_settings":' "$TACHYON_SECTION_ERRORS_FILE" ||
  fail "validator quarantine mode must record _settings error in section-errors.json, got: $val_out"
if grep -Fq '"good_sec":' "$TACHYON_SECTION_ERRORS_FILE"; then
  fail "healthy section good_sec must not be quarantined when _settings fails"
fi

# Strict validation mode without quarantine must still fail loudly.
if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val_bad_settings.json" >/dev/null 2>&1; then
  fail "strict validate-runtime-fixture must fail on broken bittorrent_policy"
fi

# 2. Quarantine mode must isolate _dns error cleanly without aborting.
cat >"$WORK_DIR/val_bad_dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "broken_proto",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ]
    }
  ]
}
JSON

rm -f "$TACHYON_VALIDATOR_QUARANTINED_FILE" "$TACHYON_SECTION_ERRORS_FILE"
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_bad_dns.json" >/dev/null
grep -Fq '"_dns":' "$TACHYON_SECTION_ERRORS_FILE" ||
  fail "validator quarantine mode must record _dns error in section-errors.json"
if grep -Fq '"good_sec":' "$TACHYON_SECTION_ERRORS_FILE"; then
  fail "healthy section good_sec must not be quarantined when _dns fails"
fi

# 3. Safe minimal config fixture must provide working DNS, inbounds, outbounds, and Clash API.
ucode -L "$TACHYON_LIB" "$RUNTIME_UC" safe-minimal-config-fixture "127.0.0.1" >"$WORK_DIR/safe-minimal.json"
ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$WORK_DIR"'/safe-minimal.json"));
function assert(cond, msg) {
  if (!cond) {
    warn("Assertion failed: " + msg + "\n");
    exit(1);
  }
}
assert(type(cfg) == "object", "minimal config must be JSON object");
assert(cfg.dns["final"] == "dns-resilient", "dns final must be dns-resilient");
assert(cfg.route["final"] == "direct-out", "route final must be direct-out");
assert(cfg.route.default_domain_resolver == "bootstrap-dns-server", "default_domain_resolver must be bootstrap-dns-server");
let srvTags = map(cfg.dns.servers || [], (s) => s.tag);
assert(index(srvTags, "bootstrap-dns-server") >= 0, "must have bootstrap-dns-server");
assert(index(srvTags, "dns-resilient") >= 0, "must have dns-resilient group");
let boot = filter(cfg.dns.servers || [], (s) => s.tag == "bootstrap-dns-server")[0];
assert(boot.type == "udp" && boot.server == "77.88.8.8" && boot.server_port == 53, "bootstrap must be plain UDP 77.88.8.8:53");
let inbTags = map(cfg.inbounds || [], (i) => i.tag);
assert(index(inbTags, "dns-in") >= 0, "must include dns-in");
assert(index(inbTags, "tproxy-in") >= 0, "must include tproxy-in");
assert(cfg.experimental && cfg.experimental.clash_api && cfg.experimental.clash_api.external_controller == "127.0.0.1:9090", "must expose clash_api");
'

# 4. Generator with TACHYON_SAFE_DNS_FALLBACK=1 must ignore broken DoH/detour DNS settings and keep healthy sections.
cat >"$WORK_DIR/gen_safe_dns_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "not a valid doh url !!!" ],
    "bootstrap_dns_server": [ "bad host" ],
    "dns_detour_enabled": "1",
    "dns_detour_section": "missing_sec"
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" \
TACHYON_SAFE_DNS_FALLBACK="1" \
TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-failover.json" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/gen_safe_dns_fixture.json" "$WORK_DIR/gen-safe-dns.json" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$WORK_DIR"'/gen-safe-dns.json"));
function assert(cond, msg) {
  if (!cond) {
    warn("Assertion failed: " + msg + "\n");
    exit(1);
  }
}
assert(type(cfg) == "object", "generated safe-dns config must be JSON object");
assert(cfg.dns["final"] == "dns-resilient", "safe-dns final must be dns-resilient");
assert(cfg.route.default_domain_resolver == "bootstrap-dns-server", "safe-dns default_domain_resolver must be bootstrap-dns-server");
let nonSafeRemote = filter(cfg.dns.servers || [], (s) => s.type == "https" || s.type == "tls" || s.type == "quic" || s.type == "h3");
assert(length(nonSafeRemote) == 0, "TACHYON_SAFE_DNS_FALLBACK=1 must not emit broken DoH/DoT/DoQ servers");
let safeUdpBoot = filter(cfg.dns.servers || [], (s) => s.tag == "bootstrap-dns-server" && s.type == "udp" && s.server == "77.88.8.8");
assert(length(safeUdpBoot) == 1, "TACHYON_SAFE_DNS_FALLBACK=1 must emit safe UDP bootstrap-dns-server");
let safeUdpMain = filter(cfg.dns.servers || [], (s) => s.tag == "dns-server" && s.type == "udp" && s.server == "1.1.1.1");
assert(length(safeUdpMain) == 1, "TACHYON_SAFE_DNS_FALLBACK=1 must emit safe UDP dns-server");
let obs = map(cfg.outbounds || [], (o) => o.tag);
assert(index(obs, "good_sec-1-out") >= 0, "healthy good_sec outbound must remain intact under TACHYON_SAFE_DNS_FALLBACK=1");
'

printf 'config_fault_resilience: OK\n'
