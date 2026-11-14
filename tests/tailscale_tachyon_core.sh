#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
NFT_UC="$TACHYON_LIB/nft/apply.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"
SERVER_UC="$TACHYON_LIB/server/service.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq "$expected" "$file" || fail "$label: missing '$expected' in $file"
}

assert_not_contains() {
  local file="$1"
  local forbidden="$2"
  local label="$3"

  if grep -Fq "$forbidden" "$file"; then
    fail "$label: unexpected '$forbidden' in $file"
  fi
}

assert_line_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="$4"
  local first_line
  local second_line

  first_line="$(awk -v pat="$first" 'index($0, pat) { print NR; exit }' "$file")"
  second_line="$(awk -v pat="$second" 'index($0, pat) { print NR; exit }' "$file")"
  [ -n "$first_line" ] || fail "$label: missing first line '$first'"
  [ -n "$second_line" ] || fail "$label: missing second line '$second'"
  [ "$first_line" -lt "$second_line" ] || fail "$label: expected '$first' (line $first_line) before '$second' (line $second_line)"
}

uci_get_from_state() {
  local state_file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, length($1) + 2); found = 1 } END { exit found ? 0 : 1 }' "$state_file"
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> "${TACHYON_TEST_LOGGER_LOG:-/dev/null}"
exit 0
SH
chmod 0755 "$WORK_DIR/bin/logger"

printf 'tachyon-core\n' >"$WORK_DIR/core-variant"
printf '0.4.5\n' >"$WORK_DIR/core-version"
: >"$WORK_DIR/empty.uci.state"

export SB_VARIANT_STATE_FILE="$WORK_DIR/core-variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/core-version"
export SB_VERSION_OVERRIDE="0.4.5"

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  PATH="$WORK_DIR/bin:$PATH" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/empty.uci.state" \
    ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1"
}

# ---------------------------------------------------------------------------
# (a) Embedded Tailscale server on tachyon-core
# ---------------------------------------------------------------------------
cat >"$WORK_DIR/server_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": [ "8.8.8.8" ],
    "bootstrap_dns_server": [ "1.1.1.1" ],
    "service_listen_address": "127.0.0.1"
  },
  "server": [
    {
      ".name": "ts_ephem",
      ".type": "server",
      "enabled": "1",
      "protocol": "tailscale",
      "tailscale_mode": "singbox",
      "tailscale_ephemeral": "1",
      "tailscale_auth_key": "",
      "tailscale_control_url": "https://headscale.example.test",
      "tailscale_hostname": "router-ephem",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1",
      "tailscale_accept_default_resolvers": "0",
      "tailscale_exit_node": "100.64.0.99",
      "tailscale_exit_node_allow_lan_access": "1",
      "tailscale_advertise_routes": [ "192.168.10.0/24" ],
      "tailscale_advertise_exit_node": "1",
      "tailscale_relay_server_port": "41641",
      "tailscale_relay_server_static_endpoints": [ "198.51.100.10:41641" ],
      "tailscale_system_interface": "1",
      "tailscale_system_interface_name": "ts-srv0",
      "tailscale_system_interface_mtu": "1380",
      "tailscale_udp_timeout": "5m",
      "routing_mode": "direct"
    },
    {
      ".name": "ts_persist",
      ".type": "server",
      "enabled": "1",
      "protocol": "tailscale",
      "tailscale_mode": "embedded",
      "tailscale_ephemeral": "0",
      "tailscale_auth_key": "tskey-auth-srv-secret",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1",
      "tailscale_accept_default_resolvers": "1",
      "tailscale_advertise_exit_node": "0",
      "routing_mode": "direct"
    }
  ],
  "section": []
}
JSON

generate_config "$WORK_DIR/server_fixture.json" "$WORK_DIR/server_out.json"

node - "$WORK_DIR/server_out.json" <<'NODE'
const fs = require("fs");
const assert = require("assert");
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

const endpoints = cfg.endpoints || [];
const inbounds = cfg.inbounds || [];
const outbounds = cfg.outbounds || [];

assert.strictEqual(inbounds.some((x) => x && x.type === "tailscale"), false, "tailscale server must not be emitted in inbounds");
assert.strictEqual(outbounds.some((x) => x && x.type === "tailscale"), false, "tailscale server must not be emitted in outbounds");

const ephem = endpoints.find((x) => x && x.tag === "server-ts_ephem-in");
assert(ephem, "missing server-ts_ephem-in in config.endpoints");
assert.strictEqual(ephem.type, "tailscale");
assert.strictEqual(Object.prototype.hasOwnProperty.call(ephem, "auth_key"), false, "empty auth_key must be omitted");
assert.strictEqual(ephem.ephemeral, true);
assert.strictEqual(ephem.state_directory, "/var/run/tachyon/tailscale/ts_ephem");
assert.strictEqual(ephem.control_url, "https://headscale.example.test");
assert.strictEqual(ephem.hostname, "router-ephem");
assert.strictEqual(ephem.accept_routes, true);
assert.strictEqual(ephem.exit_node, "100.64.0.99");
assert.strictEqual(ephem.exit_node_allow_lan_access, true);
assert.deepStrictEqual(ephem.advertise_routes, [ "192.168.10.0/24" ]);
assert.strictEqual(ephem.advertise_exit_node, true);
assert.strictEqual(ephem.relay_server_port, 41641);
assert.deepStrictEqual(ephem.relay_server_static_endpoints, [ "198.51.100.10:41641" ]);
assert.strictEqual(ephem.system_interface, true);
assert.strictEqual(ephem.system_interface_name, "ts-srv0");
assert.strictEqual(ephem.system_interface_mtu, 1380);
assert.strictEqual(ephem.udp_timeout, "5m");

const persist = endpoints.find((x) => x && x.tag === "server-ts_persist-in");
assert(persist, "missing server-ts_persist-in in config.endpoints");
assert.strictEqual(persist.type, "tailscale");
assert.strictEqual(persist.auth_key, "tskey-auth-srv-secret");
assert.strictEqual(persist.state_directory, "/etc/tachyon/tailscale/ts_persist");
assert.notStrictEqual(persist.ephemeral, true);

const dnsServers = (cfg.dns && cfg.dns.servers) || [];
const dnsEphem = dnsServers.find((s) => s && s.tag === "server-ts_ephem-tailscale-dns");
const dnsPersist = dnsServers.find((s) => s && s.tag === "server-ts_persist-tailscale-dns");
assert(dnsEphem && dnsEphem.type === "tailscale" && dnsEphem.endpoint === "server-ts_ephem-in");
assert.strictEqual(dnsEphem.accept_default_resolvers, false);
assert(dnsPersist && dnsPersist.type === "tailscale" && dnsPersist.endpoint === "server-ts_persist-in");
assert.strictEqual(dnsPersist.accept_default_resolvers, true);

const dnsRules = (cfg.dns && cfg.dns.rules) || [];
const hasTsNetDns = dnsRules.some((r) =>
  r && r.action === "route" &&
  (r.server === "server-ts_ephem-tailscale-dns" || r.server === "server-ts_persist-tailscale-dns") &&
  Array.isArray(r.domain_suffix) && r.domain_suffix.includes("ts.net")
);
assert(hasTsNetDns, "expected ts.net DNS rule for tailscale server");
assert(dnsRules.some((r) => r && r.action === "route" && r.server === "server-ts_ephem-tailscale-dns" && r.preferred_by === "server-ts_ephem-in"),
  "expected preferred_by DNS rule for server-ts_ephem-in");
assert(dnsRules.some((r) => r && r.action === "route" && r.server === "server-ts_persist-tailscale-dns" && r.preferred_by === "server-ts_persist-in"),
  "expected preferred_by DNS rule for server-ts_persist-in");

const routeRules = (cfg.route && cfg.route.rules) || [];
for (const tag of [ "server-ts_ephem-in", "server-ts_persist-in" ]) {
  const cidrRule = routeRules.find((r) =>
    r && r.action === "route" && r.outbound === tag &&
    Array.isArray(r.ip_cidr) &&
    r.ip_cidr.includes("100.64.0.0/10") &&
    r.ip_cidr.includes("fd7a:115c:a1e0::/48")
  );
  assert(cidrRule, `expected 100.64.0.0/10 and fd7a:115c:a1e0::/48 route rule for ${tag}`);
  const prefRule = routeRules.find((r) =>
    r && r.action === "route" && r.outbound === tag && r.preferred_by === tag
  );
  assert(prefRule, `expected preferred_by route rule for ${tag}`);
}
NODE

# ---------------------------------------------------------------------------
# (b) Embedded client section, modular source, imported JSON, connections.interfaces()
# ---------------------------------------------------------------------------
cat >"$WORK_DIR/client_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": [ "8.8.8.8" ],
    "bootstrap_dns_server": [ "1.1.1.1" ],
    "service_listen_address": "127.0.0.1"
  },
  "outbound_source": [
    {
      ".name": "mod_no_exit",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "Mesh No Exit",
      "source_type": "tailscale",
      "tailscale_mode": "embedded",
      "tailscale_ephemeral": "1",
      "tailscale_auth_key": "",
      "tailscale_control_url": "https://controlplane.tailscale.com",
      "tailscale_hostname": "mod-no-exit",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1"
    },
    {
      ".name": "mod_with_exit",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "Mesh With Exit",
      "source_type": "tailscale",
      "tailscale_mode": "embedded",
      "tailscale_ephemeral": "0",
      "tailscale_auth_key": "tskey-mod-secret",
      "tailscale_exit_node": "100.64.0.44",
      "tailscale_exit_node_allow_lan_access": "1",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1"
    }
  ],
  "section": [
    {
      ".name": "sec_no_exit",
      ".type": "section",
      "enabled": "1",
      "action": "tailscale",
      "tailscale_ephemeral": "1",
      "tailscale_auth_key": "",
      "tailscale_control_url": "https://controlplane.tailscale.com",
      "tailscale_hostname": "cli-no-exit",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1",
      "tailscale_accept_default_resolvers": "0",
      "tailscale_relay_server_port": "41645",
      "tailscale_relay_server_static_endpoints": [ "203.0.113.20:41645" ],
      "tailscale_system_interface": "1",
      "tailscale_system_interface_name": "ts-cli0",
      "tailscale_system_interface_mtu": "1360",
      "tailscale_udp_timeout": "3m",
      "domain_suffix": [ "noexit.example" ]
    },
    {
      ".name": "sec_with_exit",
      ".type": "section",
      "enabled": "1",
      "action": "tailscale",
      "tailscale_ephemeral": "0",
      "tailscale_auth_key": "tskey-cli-exit",
      "tailscale_exit_node": "100.64.0.55",
      "tailscale_exit_node_allow_lan_access": "1",
      "tailscale_accept_routes": "1",
      "tailscale_accept_dns": "1",
      "domain_suffix": [ "withexit.example" ]
    },
    {
      ".name": "sec_modular",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "mod_no_exit", "mod_with_exit" ],
      "domain_suffix": [ "mod.example" ]
    },
    {
      ".name": "sec_imported",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"tailscale\",\"tag\":\"imp-no-exit\",\"control_url\":\"https://controlplane.tailscale.com\",\"auth_key\":\"\",\"ephemeral\":true,\"accept_routes\":true}",
        "{\"type\":\"tailscale\",\"tag\":\"imp-with-exit\",\"control_url\":\"https://controlplane.tailscale.com\",\"auth_key\":\"tskey-imp-exit\",\"ephemeral\":false,\"accept_routes\":true,\"exit_node\":\"100.64.0.88\"}"
      ],
      "domain_suffix": [ "imp.example" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/client_fixture.json" "$WORK_DIR/client_out.json"

node - "$WORK_DIR/client_out.json" <<'NODE'
const fs = require("fs");
const assert = require("assert");
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

const endpoints = cfg.endpoints || [];
const outbounds = cfg.outbounds || [];
const dnsServers = (cfg.dns && cfg.dns.servers) || [];
const dnsRules = (cfg.dns && cfg.dns.rules) || [];
const routeRules = (cfg.route && cfg.route.rules) || [];

assert.strictEqual(outbounds.some((o) => o && o.type === "tailscale"), false, "tailscale client/imported endpoints must never appear in config.outbounds");

const secNoExit = endpoints.find((e) => e && e.tag === "sec_no_exit-out");
assert(secNoExit, "missing sec_no_exit-out in config.endpoints");
assert.strictEqual(secNoExit.type, "tailscale");
assert.strictEqual(Object.prototype.hasOwnProperty.call(secNoExit, "auth_key"), false, "empty client auth_key must be omitted");
assert.strictEqual(secNoExit.ephemeral, true);
assert.strictEqual(secNoExit.state_directory, "/var/run/tachyon/tailscale/sec_no_exit-out");
assert.strictEqual(secNoExit.relay_server_port, 41645);
assert.deepStrictEqual(secNoExit.relay_server_static_endpoints, [ "203.0.113.20:41645" ]);
assert.strictEqual(secNoExit.system_interface, true);
assert.strictEqual(secNoExit.system_interface_name, "ts-cli0");
assert.strictEqual(secNoExit.system_interface_mtu, 1360);
assert.strictEqual(secNoExit.udp_timeout, "3m");

const secWithExit = endpoints.find((e) => e && e.tag === "sec_with_exit-out");
assert(secWithExit, "missing sec_with_exit-out in config.endpoints");
assert.strictEqual(secWithExit.auth_key, "tskey-cli-exit");
assert.strictEqual(secWithExit.state_directory, "/etc/tachyon/tailscale/sec_with_exit-out");
assert.strictEqual(secWithExit.exit_node, "100.64.0.55");
assert.strictEqual(secWithExit.exit_node_allow_lan_access, true);

const modNoExit = endpoints.find((e) => e && e.tag === "sec_modular-tailscale-mod_no_exit-out");
const modWithExit = endpoints.find((e) => e && e.tag === "sec_modular-tailscale-mod_with_exit-out");
assert(modNoExit && modNoExit.type === "tailscale", "missing modular embedded tailscale endpoint without exit_node");
assert.strictEqual(Object.prototype.hasOwnProperty.call(modNoExit, "auth_key"), false);
assert.strictEqual(modNoExit.state_directory, "/var/run/tachyon/tailscale/sec_modular-tailscale-mod_no_exit-out");
assert(modWithExit && modWithExit.type === "tailscale", "missing modular embedded tailscale endpoint with exit_node");
assert.strictEqual(modWithExit.auth_key, "tskey-mod-secret");
assert.strictEqual(modWithExit.state_directory, "/etc/tachyon/tailscale/sec_modular-tailscale-mod_with_exit-out");
assert.strictEqual(modWithExit.exit_node, "100.64.0.44");

const modSelector = outbounds.find((o) => o && o.tag === "sec_modular-out");
assert(modSelector && Array.isArray(modSelector.outbounds), "expected selector sec_modular-out");
assert(modSelector.outbounds.includes(modNoExit.tag), "selector must reference modular tailscale endpoint tag");
assert(modSelector.outbounds.includes(modWithExit.tag), "selector must reference modular tailscale endpoint tag with exit_node");

const impNoExit = endpoints.find((e) => e && e.type === "tailscale" && e.tag.includes("imp-no-exit"));
const impWithExit = endpoints.find((e) => e && e.type === "tailscale" && e.tag.includes("imp-with-exit"));
assert(impNoExit, "missing imported tailscale endpoint imp-no-exit in config.endpoints");
assert.strictEqual(Object.prototype.hasOwnProperty.call(impNoExit, "auth_key"), false, "empty imported auth_key must be omitted");
assert(impNoExit.state_directory.startsWith("/var/run/tachyon/tailscale/"), `expected ephemeral state_directory, got ${impNoExit.state_directory}`);
assert(impWithExit, "missing imported tailscale endpoint imp-with-exit in config.endpoints");
assert.strictEqual(impWithExit.auth_key, "tskey-imp-exit");
assert(impWithExit.state_directory.startsWith("/etc/tachyon/tailscale/"), `expected persistent state_directory, got ${impWithExit.state_directory}`);

const tsDnsTags = [];
for (const ep of [ secNoExit, secWithExit, modNoExit, modWithExit, impNoExit, impWithExit ]) {
  const safeId = ep.tag.replace(/[^A-Za-z0-9_.-]/g, "_");
  const expectedDnsTag = "dns-" + safeId;
  const srv = dnsServers.find((s) => s && s.type === "tailscale" && s.tag === expectedDnsTag && s.endpoint === ep.tag);
  assert(srv, `missing tailscale DNS server ${expectedDnsTag} for endpoint ${ep.tag}`);
  tsDnsTags.push(expectedDnsTag);
  const prefDns = dnsRules.find((r) => r && r.action === "route" && r.server === expectedDnsTag && r.preferred_by === ep.tag);
  assert(prefDns, `missing preferred_by DNS rule for ${ep.tag}`);
}

const hasTsNetClientDns = dnsRules.some((r) =>
  r && r.action === "route" &&
  tsDnsTags.includes(r.server) &&
  Array.isArray(r.domain_suffix) && r.domain_suffix.includes("ts.net")
);
assert(hasTsNetClientDns, "expected ts.net DNS rule pointing to client tailscale DNS server");

const hasClientCidrRoute = routeRules.some((r) =>
  r && r.action === "route" &&
  Array.isArray(r.ip_cidr) &&
  r.ip_cidr.includes("100.64.0.0/10") &&
  r.ip_cidr.includes("fd7a:115c:a1e0::/48")
);
assert(hasClientCidrRoute, "expected client 100.64.0.0/10 and fd7a:115c:a1e0::/48 route rule");

for (const ep of [ secNoExit, modNoExit, impNoExit ]) {
  assert(
    routeRules.some((r) => r && r.action === "route" && r.preferred_by === ep.tag && r.outbound === ep.tag),
    `expected preferred_by route rule when exit_node is empty for ${ep.tag}`
  );
}
for (const ep of [ secWithExit, modWithExit, impWithExit ]) {
  assert.strictEqual(
    routeRules.some((r) => r && r.preferred_by === ep.tag),
    false,
    `must skip preferred_by route rule when exit_node is set for ${ep.tag}`
  );
}
NODE

# Check connections.interfaces() filters embedded tailscale sources and keeps native ones.
ucode -L "$TACHYON_LIB" -e '
let connections = require("config.connections");
connections.set_item_sections_from_data({
  outbound_source: [
    { ".name": "src_emb", ".type": "outbound_source", enabled: "1", source_type: "tailscale", tailscale_mode: "embedded", interface_name: "tailscale9" },
    { ".name": "src_def", ".type": "outbound_source", enabled: "1", source_type: "tailscale", tailscale_hostname: "peer-a" },
    { ".name": "src_nat", ".type": "outbound_source", enabled: "1", source_type: "tailscale", tailscale_mode: "native", interface_name: "tailscale0" },
    { ".name": "src_wg",  ".type": "outbound_source", enabled: "1", source_type: "interface", interface_name: "wg0" }
  ],
  section: [
    { ".name": "mix", ".type": "section", enabled: "1", action: "connection", outbound_source_refs: [ "src_emb", "src_def", "src_nat", "src_wg" ] }
  ]
});
let sec = { ".name": "mix", ".type": "section", enabled: "1", action: "connection", outbound_source_refs: [ "src_emb", "src_def", "src_nat", "src_wg" ] };
let ifaces = connections.interfaces(sec);
if (length(ifaces) != 2 || ifaces[0] != "tailscale0" || ifaces[1] != "wg0") {
  warn(sprintf("unexpected interfaces() result: %J\n", ifaces));
  exit(1);
}
let emb = connections.embedded_tailscale_sources(sec);
if (length(emb) != 2 || emb[0][".name"] != "src_emb" || emb[1][".name"] != "src_def") {
  warn(sprintf("unexpected embedded_tailscale_sources() result: %J\n", emb));
  exit(1);
}
' || fail "connections.interfaces() / embedded_tailscale_sources() check failed"

# ---------------------------------------------------------------------------
# (c) nft/apply.uc + service/state.uc rules and signature parity
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR/nft-bin"
NFT_LOG="$WORK_DIR/nft.log"
cat >"$WORK_DIR/nft-bin/nft" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"
if [ "$1" = "-f" ] && [ -f "$2" ]; then
  cat "$2" >> "${NFT_LOG:?}"
fi
SH
cat >"$WORK_DIR/nft-bin/ip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$WORK_DIR/nft-bin/sysctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cp "$WORK_DIR/bin/logger" "$WORK_DIR/nft-bin/logger"
chmod 0755 "$WORK_DIR/nft-bin/nft" "$WORK_DIR/nft-bin/ip" "$WORK_DIR/nft-bin/sysctl" "$WORK_DIR/nft-bin/logger"

run_nft_base() {
  local state_file="$1"
  : >"$NFT_LOG"
  NFT_LOG="$NFT_LOG" PATH="$WORK_DIR/nft-bin:$PATH" TACHYON_UCI_STATE_FILE="$state_file" \
    ucode -L "$TACHYON_LIB" "$NFT_UC" nft-create-runtime-base-from-uci \
      TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces \
      0x00100000 0x00200000 198.18.0.0/15 1602 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1
}

# c1: Embedded tailscale server active + native off
cat >"$WORK_DIR/nft_emb_srv.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.ts_srv=server
tachyon.ts_srv.enabled=1
tachyon.ts_srv.protocol=tailscale
tachyon.ts_srv.tailscale_mode=singbox
EOF_STATE

run_nft_base "$WORK_DIR/nft_emb_srv.state"
assert_contains "$NFT_LOG" $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t100.64.0.0/10\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000' "embedded tailscale server mangle v4 tcp rule"
assert_contains "$NFT_LOG" $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t100.64.0.0/10\tmeta\tl4proto\tudp\tmeta\tmark\tset\t0x00100000' "embedded tailscale server mangle v4 udp rule"
assert_contains "$NFT_LOG" $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip6\tdaddr\tfd7a:115c:a1e0::/48\tmeta\tl4proto\ttcp\tmeta\tmark\tset\t0x00100000' "embedded tailscale server mangle v6 tcp rule"
assert_contains "$NFT_LOG" $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip\tdaddr\t100.64.0.0/10\tmeta\tmark\tset\t0x00100000\taccept' "embedded tailscale server mangle_output v4 rule"
assert_contains "$NFT_LOG" $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip6\tdaddr\tfd7a:115c:a1e0::/48\tmeta\tmark\tset\t0x00100000\taccept' "embedded tailscale server mangle_output v6 rule"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t100.64.0.0/10' \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t@localv4\treturn' \
  "mangle 100.64.0.0/10 must run before @localv4 return"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip6\tdaddr\tfd7a:115c:a1e0::/48' \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip6\tdaddr\t@localv6\treturn' \
  "mangle fd7a:115c:a1e0::/48 must run before @localv6 return"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tmark\t0x00200000\tcounter\treturn' \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip\tdaddr\t100.64.0.0/10' \
  "mangle_output outbound_mark return must precede 100.64.0.0/10 rule"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tmark\t0x00002022\tcounter\treturn' \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip\tdaddr\t100.64.0.0/10' \
  "mangle_output 0x00002022 return must precede 100.64.0.0/10 rule"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip\tdaddr\t100.64.0.0/10' \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tip\tdaddr\t@localv4\treturn' \
  "mangle_output 100.64.0.0/10 must run before @localv4 return"

assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip6\tdaddr\tfd7a:115c:a1e0::/48' \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tip6\tdaddr\t@localv6\treturn' \
  "mangle_output fd7a:115c:a1e0::/48 must run before @localv6 return"

# c2: Embedded client section active + native off
cat >"$WORK_DIR/nft_emb_sec.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.ts_sec=section
tachyon.ts_sec.enabled=1
tachyon.ts_sec.action=tailscale
EOF_STATE

run_nft_base "$WORK_DIR/nft_emb_sec.state"
assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t100.64.0.0/10' \
  $'add\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip\tdaddr\t@localv4\treturn' \
  "client section mangle 100.64.0.0/10 before @localv4 return"
assert_line_before "$NFT_LOG" \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tmeta\tl4proto\t{ tcp, udp }\tip\tdaddr\t100.64.0.0/10' \
  $'add\trule\tinet\tTachyonTable\tmangle_output\tip\tdaddr\t@localv4\treturn' \
  "client section mangle_output 100.64.0.0/10 before @localv4 return"

# c3: Disabled tailscale emits zero extra 100.64.0.0/10 or fd7a:115c:a1e0::/48 rules
cat >"$WORK_DIR/nft_disabled.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.ts_srv=server
tachyon.ts_srv.enabled=0
tachyon.ts_srv.protocol=tailscale
tachyon.ts_srv.tailscale_mode=singbox
tachyon.ts_sec=section
tachyon.ts_sec.enabled=0
tachyon.ts_sec.action=tailscale
EOF_STATE

run_nft_base "$WORK_DIR/nft_disabled.state"
assert_not_contains "$NFT_LOG" "100.64.0.0/10" "disabled tailscale must emit zero 100.64.0.0/10 rules"
assert_not_contains "$NFT_LOG" "fd7a:115c:a1e0::/48" "disabled tailscale must emit zero fd7a:115c:a1e0::/48 rules"

# c4: Signature parity between nft/apply.uc and service/state.uc
cat >"$WORK_DIR/sig_active.json" <<'JSON'
{
  "settings": { "source_network_interfaces": "br-lan" },
  "server": [
    { ".name": "ts_srv", "enabled": "1", "protocol": "tailscale", "tailscale_mode": "singbox", "tailscale_ephemeral": "1", "tailscale_relay_server_port": "41641" }
  ],
  "outbound_source": [
    { ".name": "ts_src", "enabled": "1", "source_type": "tailscale", "tailscale_mode": "embedded" }
  ],
  "section": [
    { ".name": "ts_sec", "enabled": "1", "action": "tailscale", "tailscale_hostname": "node-1" },
    { ".name": "conn_sec", "enabled": "1", "action": "connection", "outbound_source_refs": [ "ts_src" ] }
  ]
}
JSON

cat >"$WORK_DIR/sig_disabled.json" <<'JSON'
{
  "settings": { "source_network_interfaces": "br-lan" },
  "server": [
    { ".name": "ts_srv", "enabled": "0", "protocol": "tailscale", "tailscale_mode": "singbox" }
  ],
  "section": [
    { ".name": "ts_sec", "enabled": "0", "action": "tailscale" }
  ]
}
JSON

cat >"$WORK_DIR/sig_baseline.json" <<'JSON'
{
  "settings": { "source_network_interfaces": "br-lan" },
  "server": [],
  "section": []
}
JSON

nft_sig_active="$(ucode -L "$TACHYON_LIB" "$NFT_UC" nft-runtime-signature-fixture "$WORK_DIR/sig_active.json")"
state_sig_active="$(ucode -L "$TACHYON_LIB" "$STATE_UC" nft-signature-fixture "$WORK_DIR/sig_active.json")"
assert_eq "$nft_sig_active" "$state_sig_active" "nft signature parity with active embedded tailscale"

nft_sig_disabled="$(ucode -L "$TACHYON_LIB" "$NFT_UC" nft-runtime-signature-fixture "$WORK_DIR/sig_disabled.json")"
state_sig_disabled="$(ucode -L "$TACHYON_LIB" "$STATE_UC" nft-signature-fixture "$WORK_DIR/sig_disabled.json")"
assert_eq "$nft_sig_disabled" "$state_sig_disabled" "nft signature parity with disabled tailscale"

nft_sig_baseline="$(ucode -L "$TACHYON_LIB" "$NFT_UC" nft-runtime-signature-fixture "$WORK_DIR/sig_baseline.json")"
assert_eq "$nft_sig_baseline" "$nft_sig_disabled" "disabled tailscale must not alter baseline nft signature"
if [ "$nft_sig_active" = "$nft_sig_disabled" ]; then
  fail "active embedded tailscale must alter nft signature"
fi

# sing-box-signature reacts to server and section tailscale_* fields
cat >"$WORK_DIR/sb_sig_a.json" <<'JSON'
{
  "settings": { "dns_server": [ "8.8.8.8" ] },
  "server": [
    { ".name": "ts_srv", "enabled": "1", "protocol": "tailscale", "tailscale_mode": "singbox", "tailscale_ephemeral": "0", "tailscale_relay_server_port": "41641" }
  ],
  "section": [
    { ".name": "ts_sec", "enabled": "1", "action": "tailscale", "tailscale_exit_node": "" }
  ]
}
JSON
cat >"$WORK_DIR/sb_sig_b.json" <<'JSON'
{
  "settings": { "dns_server": [ "8.8.8.8" ] },
  "server": [
    { ".name": "ts_srv", "enabled": "1", "protocol": "tailscale", "tailscale_mode": "singbox", "tailscale_ephemeral": "1", "tailscale_relay_server_port": "41642" }
  ],
  "section": [
    { ".name": "ts_sec", "enabled": "1", "action": "tailscale", "tailscale_exit_node": "100.64.0.10" }
  ]
}
JSON
sb_a="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/sb_sig_a.json")"
sb_b="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/sb_sig_b.json")"
if [ "$sb_a" = "$sb_b" ]; then
  fail "sing-box-signature must reflect changes in tailscale_* options"
fi

# ---------------------------------------------------------------------------
# (d) server/service.uc, config/validator.uc, service/watchdog.uc
# ---------------------------------------------------------------------------

# d1: server/service.uc: tailscale server avoids port 443, avoids WAN probe, gets security=none
mkdir -p "$WORK_DIR/srv-bin" "$WORK_DIR/proc_net"
touch "$WORK_DIR/proc_net/tcp" "$WORK_DIR/proc_net/tcp6" "$WORK_DIR/proc_net/udp" "$WORK_DIR/proc_net/udp6"
cat >"$WORK_DIR/srv-bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_CALL_LOG:?}"
exit 1
SH
cat >"$WORK_DIR/srv-bin/tachyon-core" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cp "$WORK_DIR/bin/logger" "$WORK_DIR/srv-bin/logger"
chmod 0755 "$WORK_DIR/srv-bin/curl" "$WORK_DIR/srv-bin/tachyon-core" "$WORK_DIR/srv-bin/logger"

cat >"$WORK_DIR/srv_defaults.state" <<'EOF_STATE'
tachyon.tailscale=server
tachyon.tailscale.protocol=tailscale
EOF_STATE
: >"$WORK_DIR/srv_defaults.log"
: >"$WORK_DIR/curl.log"

CURL_CALL_LOG="$WORK_DIR/curl.log" \
  PATH="$WORK_DIR/srv-bin:$PATH" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/srv_defaults.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/srv_defaults.log" \
  TACHYON_CONFIG_NAME="tachyon" \
  TACHYON_PROC_NET_DIR="$WORK_DIR/proc_net" \
  ucode -L "$TACHYON_LIB" "$SERVER_UC" prepare-all-defaults

[ ! -s "$WORK_DIR/curl.log" ] || fail "prepare-all-defaults for tailscale server must not invoke external curl probe"
assert_eq "none" "$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.security")" "tailscale server security"
assert_eq "https://controlplane.tailscale.com" "$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.tailscale_control_url")" "tailscale server control_url"
assert_eq "tachyon-tailscale" "$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.tailscale_hostname")" "tailscale server hostname"
assert_eq "1" "$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.tailscale_advertise_exit_node")" "tailscale server advertise_exit_node"
assert_eq "1" "$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.tailscale_auto_firewall")" "tailscale server auto_firewall"

if port_val="$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.listen_port" 2>/dev/null)" && [ -n "$port_val" ]; then
  fail "tailscale server must not be assigned listen_port (got '$port_val')"
fi
if fw_val="$(uci_get_from_state "$WORK_DIR/srv_defaults.state" "tachyon.tailscale.open_firewall_port" 2>/dev/null)" && [ "$fw_val" = "1" ]; then
  fail "tailscale server must not set open_firewall_port=1"
fi

# d2: config/validator.uc: valid embedded sections pass (even without tailscaled); invalid relay port & MTU rejected
mkdir -p "$WORK_DIR/val-bin"
cp "$WORK_DIR/bin/logger" "$WORK_DIR/val-bin/logger"
chmod 0755 "$WORK_DIR/val-bin/logger"
VAL_LOG="$WORK_DIR/val_logger.log"
VAL_CTX="$(printf '{"sing_box_variant_state_file":"%s"}' "$WORK_DIR/core-variant")"

cat >"$WORK_DIR/val_ok.json" <<'JSON'
{
  "settings": {
    "dns_type": "udp",
    "dns_server": [ "8.8.8.8" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "server": [
    {
      ".name": "ts_srv",
      "enabled": "1",
      "protocol": "tailscale",
      "tailscale_mode": "singbox",
      "tailscale_auth_key": "",
      "tailscale_relay_server_port": "41641",
      "tailscale_system_interface": "1",
      "tailscale_system_interface_mtu": "1380"
    }
  ],
  "outbound_source": [
    {
      ".name": "ts_src",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "tailscale",
      "tailscale_mode": "embedded",
      "tailscale_auth_key": "",
      "tailscale_relay_server_port": "41642",
      "tailscale_system_interface_mtu": "1280"
    }
  ],
  "section": [
    {
      ".name": "ts_cli",
      "enabled": "1",
      "action": "tailscale",
      "tailscale_auth_key": "",
      "tailscale_relay_server_port": "41643",
      "tailscale_system_interface_mtu": "1400",
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "ts_conn",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "ts_src" ],
      "domain_suffix": [ "example.net" ]
    }
  ]
}
JSON

: >"$VAL_LOG"
TACHYON_TEST_LOGGER_LOG="$VAL_LOG" PATH="$WORK_DIR/val-bin:$PATH" \
  ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val_ok.json" "$VAL_CTX" ||
  fail "validator must accept valid embedded tailscale sections without tailscaled"

cat >"$WORK_DIR/val_bad_port_srv.json" <<'JSON'
{
  "settings": { "dns_type": "udp", "dns_server": [ "8.8.8.8" ], "bootstrap_dns_server": [ "1.1.1.1" ] },
  "server": [
    { ".name": "ts_srv", "enabled": "1", "protocol": "tailscale", "tailscale_mode": "singbox", "tailscale_relay_server_port": "70000" }
  ],
  "section": []
}
JSON
if TACHYON_TEST_LOGGER_LOG="$VAL_LOG" PATH="$WORK_DIR/val-bin:$PATH" \
    ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val_bad_port_srv.json" "$VAL_CTX" >/dev/null 2>&1; then
  fail "validator must reject server with tailscale_relay_server_port=70000"
fi

cat >"$WORK_DIR/val_bad_port_sec.json" <<'JSON'
{
  "settings": { "dns_type": "udp", "dns_server": [ "8.8.8.8" ], "bootstrap_dns_server": [ "1.1.1.1" ] },
  "server": [],
  "section": [
    { ".name": "ts_cli", "enabled": "1", "action": "tailscale", "tailscale_relay_server_port": "0", "domain_suffix": [ "example.org" ] }
  ]
}
JSON
if TACHYON_TEST_LOGGER_LOG="$VAL_LOG" PATH="$WORK_DIR/val-bin:$PATH" \
    ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val_bad_port_sec.json" "$VAL_CTX" >/dev/null 2>&1; then
  fail "validator must reject section with tailscale_relay_server_port=0"
fi

cat >"$WORK_DIR/val_bad_mtu.json" <<'JSON'
{
  "settings": { "dns_type": "udp", "dns_server": [ "8.8.8.8" ], "bootstrap_dns_server": [ "1.1.1.1" ] },
  "server": [],
  "section": [
    { ".name": "ts_cli", "enabled": "1", "action": "tailscale", "tailscale_system_interface": "1", "tailscale_system_interface_mtu": "100", "domain_suffix": [ "example.org" ] }
  ]
}
JSON
if TACHYON_TEST_LOGGER_LOG="$VAL_LOG" PATH="$WORK_DIR/val-bin:$PATH" \
    ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/val_bad_mtu.json" "$VAL_CTX" >/dev/null 2>&1; then
  fail "validator must reject section with tailscale_system_interface_mtu=100"
fi

# Validator must treat modular embedded tailscale source as an outbound section.
awk '/^let mode = /{exit} NR > 1 {print}' "$VALIDATOR_UC" >"$WORK_DIR/validator_probe.uc"
cat >>"$WORK_DIR/validator_probe.uc" <<'UC'
use_fixture_cursor(ARGV[0]);
let ctx = context_from_json("{}", {});
if (!has_outbound_section(ctx)) {
    warn("expected has_outbound_section() == true for modular embedded tailscale source\n");
    exit(1);
}
UC
cat >"$WORK_DIR/val_mod_only.json" <<'JSON'
{
  "settings": { "dns_type": "udp", "dns_server": [ "8.8.8.8" ] },
  "outbound_source": [
    { ".name": "ts_src", ".type": "outbound_source", "enabled": "1", "source_type": "tailscale", "tailscale_mode": "embedded" }
  ],
  "section": [
    { ".name": "ts_conn", "enabled": "1", "action": "connection", "outbound_source_refs": [ "ts_src" ], "domain_suffix": [ "example.net" ] }
  ]
}
JSON
ucode -L "$TACHYON_LIB" "$WORK_DIR/validator_probe.uc" "$WORK_DIR/val_mod_only.json" ||
  fail "has_outbound_section must return true for modular embedded tailscale source"

# d3: service/watchdog.uc: check_tailscale_worker skips get_tailscale_status without enabled native server
grep -Fq 'safe_call(check_tailscale_worker, "check_tailscale_worker");' "$WATCHDOG_UC" ||
  fail "watchdog perform_slow_checks must schedule check_tailscale_worker"
awk '/^function worker\(\)/{exit} NR > 1 {print}' "$WATCHDOG_UC" >"$WORK_DIR/watchdog_probe.uc"
awk '/^function check_tailscale_worker\(\)/{in_fn=1} in_fn{print} in_fn && /^}$/{exit}' "$WATCHDOG_UC" >>"$WORK_DIR/watchdog_probe.uc"
cat >>"$WORK_DIR/watchdog_probe.uc" <<'UC'
let status_calls = 0;
command_output_from_args = function(args) {
    if (type(args) == "array" && length(args) >= 2 && args[1] == "get_tailscale_status") {
        status_calls++;
        return "{\"configured\":true,\"ready\":true}";
    }
    return "";
};
command_status = function(cmd) { return 0; };
log_message = function(msg, lvl) {};
check_tailscale_worker();
print(status_calls, "\n");
UC

cat >"$WORK_DIR/wd_none.state" <<'EOF_STATE'
tachyon.settings=settings
EOF_STATE
assert_eq "0" "$(TACHYON_UCI_STATE_FILE="$WORK_DIR/wd_none.state" ucode -L "$TACHYON_LIB" "$WORK_DIR/watchdog_probe.uc")" \
  "watchdog must skip get_tailscale_status when no tailscale server exists"

cat >"$WORK_DIR/wd_emb.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.ts_srv=server
tachyon.ts_srv.enabled=1
tachyon.ts_srv.protocol=tailscale
tachyon.ts_srv.tailscale_mode=singbox
EOF_STATE
assert_eq "0" "$(TACHYON_UCI_STATE_FILE="$WORK_DIR/wd_emb.state" ucode -L "$TACHYON_LIB" "$WORK_DIR/watchdog_probe.uc")" \
  "watchdog must skip get_tailscale_status for embedded tailscale server"

cat >"$WORK_DIR/wd_native.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.ts_srv=server
tachyon.ts_srv.enabled=1
tachyon.ts_srv.protocol=tailscale
tachyon.ts_srv.tailscale_mode=native
EOF_STATE
assert_eq "1" "$(TACHYON_UCI_STATE_FILE="$WORK_DIR/wd_native.state" ucode -L "$TACHYON_LIB" "$WORK_DIR/watchdog_probe.uc")" \
  "watchdog must invoke get_tailscale_status when native tailscale server is enabled"

cat >"$WORK_DIR/wd_native_disabled.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.ts_srv=server
tachyon.ts_srv.enabled=0
tachyon.ts_srv.protocol=tailscale
tachyon.ts_srv.tailscale_mode=native
EOF_STATE
assert_eq "0" "$(TACHYON_UCI_STATE_FILE="$WORK_DIR/wd_native_disabled.state" ucode -L "$TACHYON_LIB" "$WORK_DIR/watchdog_probe.uc")" \
  "watchdog must skip get_tailscale_status when native tailscale server is disabled"

printf 'embedded tailscale tachyon-core checks passed\n'
