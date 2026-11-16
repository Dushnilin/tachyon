#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/etc_tachyon"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
export TACHYON_IPV6_STATE_CACHE="$WORK_DIR/run/ipv6-state.json"
export TACHYON_CORE_CONFIG="$WORK_DIR/run/tachyon-core.json"

IP_LOG="$WORK_DIR/ip.log"
NFT_LOG="$WORK_DIR/nft.log"
UBUS_LOG="$WORK_DIR/ubus.log"
ODHCPD_LOG="$WORK_DIR/odhcpd.log"
SYSCTL_LOG="$WORK_DIR/sysctl.log"
INIT_LOG="$WORK_DIR/init.log"
export IP_LOG NFT_LOG UBUS_LOG ODHCPD_LOG SYSCTL_LOG INIT_LOG

cat >"$WORK_DIR/bin/ip" <<'EOF_IP'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'ip'
  for a in "$@"; do
    printf '\t%s' "$a"
  done
  printf '\n'
} >> "${IP_LOG:?}"

joined=" $* "
if [[ "$joined" == *" -6 "* && "$joined" == *" addr show "* ]]; then
  if [ -n "${MOCK_LAN_V6_ADDRS:-}" ]; then
    printf '%s\n' "$MOCK_LAN_V6_ADDRS"
  fi
  exit 0
fi
if [[ "$joined" == *" -6 "* && "$joined" == *" route show default"* ]]; then
  [ -n "${MOCK_IP6_DEFAULT_ROUTE:-}" ] && printf '%s\n' "$MOCK_IP6_DEFAULT_ROUTE"
  exit 0
fi
if [[ "$joined" == *" -6 "* && "$joined" == *" route list "* ]]; then
  [ "${IP_ROUTE6_LIST_FAIL:-0}" = "1" ] && exit 1
  [ -n "${IP_ROUTE6_OUTPUT:-}" ] && printf '%s\n' "$IP_ROUTE6_OUTPUT"
  exit 0
fi
if [[ "$joined" == *" -6 "* && "$joined" == *" rule list"* ]]; then
  [ -n "${IP_RULE6_OUTPUT:-}" ] && printf '%s\n' "$IP_RULE6_OUTPUT"
  exit 0
fi
if [[ "$joined" == *" route list "* ]]; then
  [ "${IP_ROUTE_LIST_FAIL:-0}" = "1" ] && exit 1
  [ -n "${IP_ROUTE_OUTPUT:-}" ] && printf '%s\n' "$IP_ROUTE_OUTPUT"
  exit 0
fi
if [[ "$joined" == *" rule list"* ]]; then
  [ -n "${IP_RULE_OUTPUT:-}" ] && printf '%s\n' "$IP_RULE_OUTPUT"
  exit 0
fi
exit 0
EOF_IP
chmod 0755 "$WORK_DIR/bin/ip"

cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for a in "$@"; do
    printf '\t%s' "$a"
  done
  printf '\n'
} >> "${NFT_LOG:?}"
exit 0
EOF_NFT
chmod 0755 "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/ubus" <<'EOF_UBUS'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'ubus'
  for a in "$@"; do
    printf '\t%s' "$a"
  done
  printf '\n'
} >> "${UBUS_LOG:?}"
if [[ "$*" == *"network.interface dump"* ]]; then
  printf '%s\n' "${MOCK_UBUS_IFACES:-{\"interface\":[]}}"
fi
exit 0
EOF_UBUS
chmod 0755 "$WORK_DIR/bin/ubus"

cat >"$WORK_DIR/bin/odhcpd-init" <<'EOF_ODHCPD'
#!/usr/bin/env bash
set -eo pipefail
printf 'odhcpd\t%s\n' "${*:-}" >> "${ODHCPD_LOG:?}"
exit 0
EOF_ODHCPD
chmod 0755 "$WORK_DIR/bin/odhcpd-init"
export ODHCPD_INIT="$WORK_DIR/bin/odhcpd-init"

cat >"$WORK_DIR/bin/sysctl" <<'EOF_SYSCTL'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'sysctl'
  for a in "$@"; do
    printf '\t%s' "$a"
  done
  printf '\n'
} >> "${SYSCTL_LOG:?}"
if [ "$#" -eq 2 ] && [ "$1" = "-n" ] && [ "$2" = "net.bridge.bridge-nf-call-iptables" ]; then
  printf '%s\n' "${SYSCTL_BRIDGE_NF_CALL_IPTABLES:-0}"
elif [ "$#" -eq 2 ] && [ "$1" = "-n" ] && [ "$2" = "net.bridge.bridge-nf-call-ip6tables" ]; then
  printf '%s\n' "${SYSCTL_BRIDGE_NF_CALL_IP6TABLES:-0}"
fi
exit 0
EOF_SYSCTL
chmod 0755 "$WORK_DIR/bin/sysctl"

cat >"$WORK_DIR/bin/lsmod" <<'EOF_LSMOD'
#!/usr/bin/env bash
printf '%s\n' "${LSMOD_OUTPUT:-}"
EOF_LSMOD
chmod 0755 "$WORK_DIR/bin/lsmod"

cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/usr/bin/env bash
exit 0
EOF_LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/bin/tachyon-init" <<'EOF_INIT'
#!/usr/bin/env bash
set -eo pipefail
if [ "${1:-}" = "status" ]; then
  exit 0
fi
printf 'init\t%s\n' "${*:-}" >> "${INIT_LOG:?}"
exit 0
EOF_INIT
chmod 0755 "$WORK_DIR/bin/tachyon-init"
export TACHYON_SERVICE_INIT="$WORK_DIR/bin/tachyon-init"

cat >"$WORK_DIR/bin/uci" <<'EOF_UCI'
#!/usr/bin/env bash
exit 0
EOF_UCI
chmod 0755 "$WORK_DIR/bin/uci"

export PATH="$WORK_DIR/bin:$PATH"

assert_file_contains() {
  local path="$1" needle="$2" label="$3"
  if ! grep -Fq -- "$needle" "$path"; then
    printf 'FAIL: %s (missing: %s)\n' "$label" "$needle" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local path="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$path"; then
    printf 'FAIL: %s (unexpected: %s)\n' "$label" "$needle" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_line_before() {
  local path="$1" first="$2" second="$3" label="$4"
  local l1 l2
  l1="$(grep -F -n -- "$first" "$path" | head -n1 | cut -d: -f1 || true)"
  l2="$(grep -F -n -- "$second" "$path" | head -n1 | cut -d: -f1 || true)"
  if [ -z "$l1" ] || [ -z "$l2" ] || [ "$l1" -ge "$l2" ]; then
    printf 'FAIL: %s (l1=%s l2=%s)\n' "$label" "${l1:-none}" "${l2:-none}" >&2
    cat "$path" >&2
    exit 1
  fi
}

# 1. core/common: canonical modes, aliases, effective resolution, runtime state cache in tmpfs only
TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" -e '
  let common = require("core.common");
  let assert = function(cond, msg) { if (!cond) { warn("ASSERT FAIL: " + msg + "\n"); exit(1); } };

  assert(common.normalize_ipv6_mode("off") == "off", "canonical off");
  assert(common.normalize_ipv6_mode("ipv4_only") == "off", "alias ipv4_only -> off");
  assert(common.normalize_ipv6_mode("ipv4") == "off", "alias ipv4 -> off");
  assert(common.normalize_ipv6_mode("auto") == "auto", "canonical auto");
  assert(common.normalize_ipv6_mode("dual_stack") == "dual_stack", "canonical dual_stack");
  assert(common.normalize_ipv6_mode("ipv4_ipv6") == "dual_stack", "alias ipv4_ipv6 -> dual_stack");
  assert(common.normalize_ipv6_mode("on") == "dual_stack", "alias on -> dual_stack");
  assert(common.normalize_ipv6_mode("full") == "dual_stack", "alias full -> dual_stack");
  assert(common.normalize_ipv6_mode("tunnel_over_v4") == "tunnel_over_v4", "canonical tunnel_over_v4");
  assert(common.normalize_ipv6_mode("v6_over_v4") == "tunnel_over_v4", "alias v6_over_v4 -> tunnel_over_v4");

  let no_wan6 = { available: false, wan6_iface: "", pd_prefixes: [], gua_addresses: [], default_route6: false };
  let with_pd = { available: true, wan6_iface: "wan6", pd_prefixes: [ "2001:db8:cafe::/56" ], gua_addresses: [ "2001:db8:1::2/64" ], default_route6: true };

  let e_off_lg = common.resolve_effective_ipv6_state({ ipv6_mode: "off", ipv6_leak_guard: "1", dns_strategy: "prefer_ipv6" }, with_pd);
  assert(e_off_lg.effective == "leak_guard" && !e_off_lg.ipv6_active && e_off_lg.runtime_dns_strategy == "ipv4_only", "off+leak_guard=1 -> leak_guard + ipv4_only");

  let e_off_nolg = common.resolve_effective_ipv6_state({ ipv6_mode: "ipv4_only", ipv6_leak_guard: "0", dns_strategy: "ipv6_only" }, with_pd);
  assert(e_off_nolg.ipv6_mode == "off" && e_off_nolg.effective == "disabled" && !e_off_nolg.ipv6_active && e_off_nolg.runtime_dns_strategy == "ipv4_only", "off+leak_guard=0 -> disabled + ipv4_only");

  let e_auto_no = common.resolve_effective_ipv6_state({ ipv6_mode: "auto", ipv6_leak_guard: "1", dns_strategy: "prefer_ipv6" }, no_wan6);
  assert(e_auto_no.effective == "leak_guard" && !e_auto_no.ipv6_active && e_auto_no.runtime_dns_strategy == "ipv4_only", "auto without WAN6 -> leak_guard + ipv4_only");

  let e_auto_yes = common.resolve_effective_ipv6_state({ ipv6_mode: "auto", ipv6_leak_guard: "1", dns_strategy: "prefer_ipv6" }, with_pd);
  assert(e_auto_yes.effective == "full" && e_auto_yes.ipv6_active && e_auto_yes.runtime_dns_strategy == "prefer_ipv6", "auto with WAN6 -> full + prefer_ipv6");

  let e_dual = common.resolve_effective_ipv6_state({ ipv6_mode: "on", ipv6_leak_guard: "1", dns_strategy: "prefer_ipv4" }, no_wan6);
  assert(e_dual.effective == "full" && e_dual.ipv6_active && e_dual.runtime_dns_strategy == "prefer_ipv4", "dual_stack alias without WAN6 -> full");

  let e_tun = common.resolve_effective_ipv6_state({ ipv6_mode: "v6_over_v4", fakeip_enabled: "1", dns_strategy: "ipv6_only" }, no_wan6);
  assert(e_tun.effective == "tunnel_over_v4" && e_tun.ipv6_active && e_tun.fakeip_enabled && e_tun.runtime_dns_strategy == "ipv6_only", "tunnel_over_v4 alias -> tunnel_over_v4 + fakeip_enabled");

  assert(!common.is_tmpfs_runtime_path("/etc/tachyon/ipv6-state.json"), "/etc is never allowed as runtime state path");
  assert(common.is_tmpfs_runtime_path(getenv("TACHYON_IPV6_STATE_CACHE")), "test cache path is valid runtime path");
  assert(common.cache_ipv6_runtime_state(e_auto_yes), "cache_ipv6_runtime_state succeeds");
  let cached = common.read_cached_ipv6_state();
  assert(type(cached) == "object" && cached.effective == "full", "cached state readable");

  let net_mod = require("diagnostics.network");
  let netstat_v4 = "tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN\ntcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN\n";
  let netstat_v6 = "tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN\ntcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN\ntcp 0 0 :::1602 :::* LISTEN\n";
  assert(net_mod.tachyon_core_standard_ports_listening(netstat_v4) == true, "tachyon_core_standard_ports_listening succeeds with v4-only ports when ipv6 is inactive");
  assert(net_mod.tachyon_core_standard_ports_listening(netstat_v6) == true, "tachyon_core_standard_ports_listening succeeds with dual-stack ports");
'

# 2. Validator + Migration + UI prefs
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_version"

write_validator_fixture() {
  local out="$1"
  local settings_extra="$2"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "service_listen_address": "127.0.0.1",
    ${settings_extra}
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "vless://00000000-0000-0000-0000-000000000001@[2001:db8::10]:443?encryption=none#v6" ],
      "domain_suffix": [ "example.com" ]
    }
  ]
}
JSON
}

for alias in off ipv4_only ipv4 auto dual_stack ipv4_ipv6 on full tunnel_over_v4 v6_over_v4; do
  write_validator_fixture "$WORK_DIR/val-$alias.json" "\"ipv6_mode\": \"$alias\", \"dns_strategy\": \"prefer_ipv4\", \"fakeip_enabled\": \"1\""
  TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/val-$alias.json" '{}' >/dev/null ||
    fail "validator must accept ipv6_mode=$alias"
done

write_validator_fixture "$WORK_DIR/val-bad-mode.json" "\"ipv6_mode\": \"invalid_mode\""
if TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/val-bad-mode.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid ipv6_mode"
fi

write_validator_fixture "$WORK_DIR/val-overlap.json" "\"ipv6_mode\": \"dual_stack\", \"fakeip_inet6_range\": \"fc00::/18\", \"tun_inet6\": \"fc00::1/64\""
if TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/val-overlap.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject tun_inet6 overlapping fakeip_inet6_range"
fi

write_validator_fixture "$WORK_DIR/val-bad-cidr.json" "\"fakeip_inet6_range\": \"not-a-cidr\""
if TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/val-bad-cidr.json" '{}' >/dev/null 2>&1; then
  fail "validator must reject invalid IPv6 CIDR"
fi

cat >"$WORK_DIR/mig-legacy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enable_ipv6": "0",
    "fakeip": "0",
    "ui_mode": "basic"
  },
  "section": []
}
JSON
ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/mig-legacy.json" tachyon >"$WORK_DIR/mig-out1.json"
node - "$WORK_DIR/mig-out1.json" "$WORK_DIR/mig-pass2-in.json" <<'NODE'
const fs = require('fs');
const assert = require('assert').strict;
const out1 = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(out1.changed, true);
assert.equal(out1.config.settings.ipv6_mode, 'off');
assert.equal(out1.config.settings.fakeip_enabled, '0');
assert.equal(out1.config.settings.ui_mode, 'simple');
fs.writeFileSync(process.argv[3], JSON.stringify(out1.config));
NODE
ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/mig-pass2-in.json" tachyon >"$WORK_DIR/mig-out2.json"
node - "$WORK_DIR/mig-out2.json" <<'NODE'
const fs = require('fs');
const assert = require('assert').strict;
const out2 = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(out2.changed, false);
assert.equal(out2.config.settings.ipv6_mode, 'off');
NODE

# Also test service.ui get-ui-prefs ui_mode normalization (basic -> simple) and no POSIX ERE failures across exportable modules
UCI_UI="$WORK_DIR/ui.state"
cat >"$UCI_UI" <<'EOF_UI'
tachyon.settings=settings
tachyon.settings.ui_mode=basic
tachyon.settings.ipv6_mode=off
EOF_UI
UI_PREFS_JSON="$(TACHYON_UCI_STATE_FILE="$UCI_UI" TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" get-ui-prefs)"
printf '%s\n' "$UI_PREFS_JSON" | grep -Fq '"ui_mode": "simple"' ||
  fail "service/ui.uc get-ui-prefs must normalize basic -> simple, got: $UI_PREFS_JSON"

UI_CAPS_JSON="$(TACHYON_UCI_STATE_FILE="$UCI_UI" TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" get-ui-capabilities)"
printf '%s\n' "$UI_CAPS_JSON" | grep -Fq '"ipv6_effective_state": "leak_guard"' ||
  fail "service/ui.uc get-ui-capabilities must expose ipv6_effective_state=leak_guard, got: $UI_CAPS_JSON"

TACHYON_UCI_STATE_FILE="$UCI_UI" TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" -e '
  let api = require("service.api");
  let links = require("server.links");
  let net = require("diagnostics.network");
  let sysinfo = require("diagnostics.system_info");
  let doctor = require("diagnostics.doctor");
  let route_exp = require("diagnostics.route_explain");
  let leak_chk = require("diagnostics.leak_check");
  let assert = function(cond, msg) { if (!cond) { warn("ASSERT FAIL: " + msg + "\n"); exit(1); } };

  assert(type(api) == "object" && type(api.get_system_status) == "function", "service.api loads cleanly");

  let uri = links.build({ protocol: "vless", security: "none", listen_port: "443", server_uuid: "00000000-0000-0000-0000-000000000001", label: "v6node" }, "2001:db8::5", null);
  assert(index(uri, "@[2001:db8::5]:443") >= 0, "server.links brackets IPv6 endpoint, got: " + uri);

  let tel = net.get_ipv6_runtime_telemetry();
  assert(tel.ipv6_mode == "off" && tel.runtime_dns_strategy == "ipv4_only", "diagnostics.network telemetry works cleanly");
  assert(type(sysinfo) == "object" && type(doctor) == "object" && type(route_exp) == "object" && type(leak_chk) == "object", "all diagnostic modules load without regex/syntax error");
'

# 3. Core JSON Generator across all modes + IPv6 server + tun + fakeip_exclude + NOERROR
gen_fixture() {
  local name="$1"
  local settings_extra="$2"
  write_validator_fixture "$WORK_DIR/gen-$name.json" "$settings_extra"
  TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" \
    generate-config-fixture "$WORK_DIR/gen-$name.json" "$WORK_DIR/out-$name.json" '127.0.0.1' '0' ||
    fail "generator failed for $name"
}

gen_fixture off '"enabled": "1", "proxy_mode": "tproxy", "ipv6_mode": "off", "ipv6_leak_guard": "0", "dns_strategy": "prefer_ipv6", "fakeip_enabled": "1"'
gen_fixture dual '"enabled": "1", "proxy_mode": "tproxy", "ipv6_mode": "dual_stack", "dns_strategy": "prefer_ipv6", "fakeip_enabled": "1", "fakeip_exclude": [ "internal.lan" ]'
gen_fixture tun '"enabled": "1", "proxy_mode": "tun", "ipv6_mode": "tunnel_over_v4", "fakeip_enabled": "1", "dns_strategy": "prefer_ipv4"'
gen_fixture nofake '"enabled": "1", "proxy_mode": "tproxy", "ipv6_mode": "dual_stack", "fakeip_enabled": "0"'

TACHYON_WORK_DIR="$WORK_DIR" ucode -S -e '
  import * as fs from "fs";
  let wd = getenv("TACHYON_WORK_DIR");
  let read_json = function(p) { return json(fs.readfile(p)); };
  let find_fakeip = function(c) { return filter(c.dns.servers || [], s => s.type == "fakeip"); };
  let assert = function(cond, msg) { if (!cond) { warn("ASSERT FAIL: " + msg + "\n"); exit(1); } };

  // off (with leak_guard=0): strict ipv4_only + predefined NOERROR AAAA (never reject!) + no tproxy6-in
  let c_off = read_json(wd + "/out-off.json");
  assert(c_off.dns.strategy == "ipv4_only", "off clamps dns.strategy to ipv4_only");
  let aaaa_predef = filter(c_off.dns.rules, r => r.action == "predefined" && type(r.query_type) == "array" && index(r.query_type, "AAAA") >= 0);
  assert(length(aaaa_predef) >= 1 && aaaa_predef[0].rcode == "NOERROR", "off suppresses AAAA with predefined NOERROR");
  assert(length(filter(c_off.dns.rules, r => r.action == "reject" && type(r.query_type) == "array" && index(r.query_type, "AAAA") >= 0)) == 0, "off never rejects AAAA");
  assert(length(filter(c_off.inbounds, x => x.tag == "tproxy6-in")) == 0, "off omits tproxy6-in");
  let fk_off = find_fakeip(c_off);
  assert(length(fk_off) == 1 && fk_off[0].inet4_range == "198.18.0.0/15" && fk_off[0].inet6_range == null, "off omits fakeip inet6_range while keeping inet4_range");

  // dual_stack: fakeip inet6_range fc00::/18, tproxy6-in [::], [ipv6]:port outbound server, fakeip_exclude bypass
  let c_dual = read_json(wd + "/out-dual.json");
  assert(c_dual.dns.strategy == "prefer_ipv6", "dual_stack preserves dns_strategy");
  let fk_dual = find_fakeip(c_dual);
  assert(length(fk_dual) == 1 && fk_dual[0].inet6_range == "fc00::/18", "dual_stack enables fakeip fc00::/18");
  let tp6 = filter(c_dual.inbounds, x => x.tag == "tproxy6-in");
  assert(length(tp6) == 1 && tp6[0].listen == "::1", "dual_stack has tproxy6-in listening on ::1");
  let v6_out = filter(c_dual.outbounds, x => x.type == "vless");
  assert(length(v6_out) == 1 && v6_out[0].server == "2001:db8::10" && v6_out[0].server_port == 443, "IPv6 server parsed without brackets into server/server_port");
  assert(length(filter(c_dual.dns.rules, r => type(r.domain_suffix) == "array" && index(r.domain_suffix, "internal.lan") >= 0)) >= 1, "fakeip_exclude rule emitted");

  // tunnel_over_v4: active fakeip fc00::/18 + tun dual-stack fdfe:dcba:9876::1/126
  let c_tun = read_json(wd + "/out-tun.json");
  let fk_tun = find_fakeip(c_tun);
  assert(length(fk_tun) == 1 && fk_tun[0].inet6_range == "fc00::/18", "tunnel_over_v4 enables fakeip fc00::/18");
  let tun_in = filter(c_tun.inbounds, x => x.type == "tun");
  assert(length(tun_in) == 1 && index(tun_in[0].address, "fdfe:dcba:9876::1/126") >= 0, "tun mode auto-populates fdfe:dcba:9876::1/126");

  // fakeip_enabled=0 in dual_stack omits fakeip server
  let c_nofake = read_json(wd + "/out-nofake.json");
  assert(length(find_fakeip(c_nofake)) == 0 && c_nofake.dns.fakeip == null, "fakeip_enabled=0 disables fakeip server");
'

# 4. odhcpd + LAN global/ULA flush + ra_default=2 + ubus renew + zero churn idempotency
UCI_DHCP="$WORK_DIR/dhcp_ipv6.state"
cat >"$UCI_DHCP" <<'EOF_DHCP'
tachyon.settings=settings
tachyon.settings.ipv6_mode=off
tachyon.settings.ipv6_leak_guard=0
tachyon.settings.source_network_interfaces=br-lan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=server
dhcp.lan.dhcpv6=server
dhcp.lan.ndp=relay
dhcp.lan.ra_dns=1
dhcp.lan.ra_default=1
dhcp.lan.dns=2001:4860:4860::8888
EOF_DHCP

: > "$IP_LOG"
: > "$ODHCPD_LOG"
MOCK_LAN_V6_ADDRS="2: br-lan    inet6 fd00:1234::1/64 scope global" \
  TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure

assert_file_contains "$UCI_DHCP" "dhcp.lan.ra=disabled" "off+leak_guard=0 disables ra"
assert_file_contains "$UCI_DHCP" "dhcp.lan.dhcpv6=disabled" "off+leak_guard=0 disables dhcpv6"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ndp=disabled" "off+leak_guard=0 disables ndp"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_dns=0" "off sets ra_dns=0"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_default=0" "off sets ra_default=0"
assert_file_not_contains "$UCI_DHCP" "dhcp.lan.dns=" "off deletes dhcp.lan.dns"
assert_file_contains "$UCI_DHCP" "dhcp.lan.tachyon_lan_ra=server" "backup saves ra"
assert_file_contains "$UCI_DHCP" "dhcp.lan.tachyon_lan_dhcpv6=server" "backup saves dhcpv6"
assert_file_contains "$UCI_DHCP" "dhcp.lan.tachyon_lan_ndp=relay" "backup saves ndp"
assert_file_contains "$UCI_DHCP" "dhcp.lan.tachyon_lan_dns=2001:4860:4860::8888" "backup saves dns"
assert_file_contains "$IP_LOG" $'ip\t-6\taddr\tflush\tdev\tbr-lan\tscope\tglobal' "off flushes br-lan global/ULA addresses"
assert_file_contains "$ODHCPD_LOG" "odhcpd" "off reloads odhcpd on change"

# Idempotency check in off mode (no UCI change and no global IPv6 on br-lan -> 0 odhcpd reloads)
: > "$ODHCPD_LOG"
: > "$IP_LOG"
MOCK_LAN_V6_ADDRS="" \
  TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure
[ ! -s "$ODHCPD_LOG" ] || fail "steady-state off must not reload odhcpd or write flash"
if grep -Fq "flush" "$IP_LOG"; then
  fail "steady-state off with no global v6 should not flush again"
fi

# auto mode WITHOUT WAN6 PD also keeps ra/dhcpv6/ndp disabled so LAN clients receive no ULA/GUA
sed -i 's/tachyon.settings.ipv6_mode=off/tachyon.settings.ipv6_mode=auto/' "$UCI_DHCP"
: > "$ODHCPD_LOG"
TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra=disabled" "auto without WAN6 keeps ra disabled"
assert_file_contains "$UCI_DHCP" "dhcp.lan.dhcpv6=disabled" "auto without WAN6 keeps dhcpv6 disabled"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ndp=disabled" "auto without WAN6 keeps ndp disabled"
[ ! -s "$ODHCPD_LOG" ] || fail "auto without WAN6 after off avoids redundant odhcpd reload"

# tunnel_over_v4 restores ra='server', dhcpv6, ndp, ra_dns='1', sets ra_default='2'
sed -i 's/tachyon.settings.ipv6_mode=auto/tachyon.settings.ipv6_mode=tunnel_over_v4/' "$UCI_DHCP"
: > "$ODHCPD_LOG"
TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra=server" "tunnel_over_v4 restores ra=server"
assert_file_contains "$UCI_DHCP" "dhcp.lan.dhcpv6=server" "tunnel_over_v4 restores dhcpv6"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ndp=relay" "tunnel_over_v4 restores ndp"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_dns=1" "tunnel_over_v4 sets ra_dns=1"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_default=2" "tunnel_over_v4 sets ra_default=2"

# Back to off -> then dual_stack triggers soft ubus call network.interface.lan renew when br-lan lacks global/ULA v6
sed -i 's/tachyon.settings.ipv6_mode=tunnel_over_v4/tachyon.settings.ipv6_mode=off/' "$UCI_DHCP"
TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure
sed -i 's/tachyon.settings.ipv6_mode=off/tachyon.settings.ipv6_mode=dual_stack/' "$UCI_DHCP"
: > "$UBUS_LOG"
MOCK_LAN_V6_ADDRS="" \
  TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-configure
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra=server" "dual_stack restores ra=server"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_default=1" "dual_stack restores ra_default=1"
assert_file_contains "$UBUS_LOG" $'ubus\tcall\tnetwork.interface.lan\trenew' "dual_stack after off triggers lan renew"

# odhcpd-restore completely restores all original options and deletes tachyon_lan_* backups
TACHYON_UCI_STATE_FILE="$UCI_DHCP" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/dns/apply.uc" odhcpd-restore
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra=server" "restore restores ra"
assert_file_contains "$UCI_DHCP" "dhcp.lan.dhcpv6=server" "restore restores dhcpv6"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ndp=relay" "restore restores ndp"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_dns=1" "restore restores ra_dns"
assert_file_contains "$UCI_DHCP" "dhcp.lan.ra_default=1" "restore restores ra_default"
assert_file_contains "$UCI_DHCP" "dhcp.lan.dns=2001:4860:4860::8888" "restore restores dns"
assert_file_not_contains "$UCI_DHCP" "tachyon_lan_" "restore clears tachyon_lan_* backups"

# 5. nft/apply.uc rules: FakeIPv6 order, proxy priority -100, off strict blocking even when leak_guard=0, auto without WAN6, leak_guard
NFT_STATE="$WORK_DIR/nft_ipv6.state"
cat >"$NFT_STATE" <<'EOF_NFT_STATE'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.ipv6_mode=dual_stack
tachyon.settings.ipv6_leak_guard=1
tachyon.settings.fakeip_enabled=1
tachyon.settings.webrtc_leak_protect=1
EOF_NFT_STATE

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$NFT_STATE" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" \
  nft-create-runtime-base-from-uci TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces 0x04000000 0x00200000 198.18.0.0/15 1602

assert_file_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tTachyonTable\tmangle\t{ type filter hook prerouting priority -149; policy accept; }' "mangle priority -149"
assert_file_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tTachyonTable\tproxy\t{ type filter hook prerouting priority -100; policy accept; }' "proxy priority -100 after mangle"
assert_line_before "$NFT_LOG" \
  $'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip6\tdaddr\tfc00::/18' \
  $'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tip6\tdaddr\t@localv6' \
  "FakeIPv6 fc00::/18 rule precedes @localv6 return"
assert_file_contains "$NFT_LOG" $'tproxy\tip6\tto\t[::1]:1602' "dual_stack adds tproxy6 rule"
assert_file_contains "$NFT_LOG" $'webrtc_guard\tmeta\tmark\t&\t0x10000000\t==\t0x10000000\treturn' "webrtc_guard preserves explicit bypass mark 0x10000000"

# Switch to ipv6_mode=off + ipv6_leak_guard=0: strict LAN RS/RA/DHCPv6 block + forward admin-prohibited even with leak_guard=0!
cat >"$NFT_STATE" <<'EOF_NFT_OFF'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.ipv6_mode=off
tachyon.settings.ipv6_leak_guard=0
tachyon.settings.fakeip_enabled=1
EOF_NFT_OFF
: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$NFT_STATE" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" \
  nft-create-runtime-base-from-uci TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces 0x04000000 0x00200000 198.18.0.0/15 1602

assert_file_not_contains "$NFT_LOG" $'tproxy\tip6\tto' "off omits tproxy6 rules"
assert_line_before "$NFT_LOG" \
  $'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\ticmpv6\ttype\tnd-router-solicit' \
  $'mangle\tiifname\t@tachyon_interfaces\ticmpv6\ttype\t{ destination-unreachable' \
  "off drops LAN nd-router-solicit before ESSENTIAL_ICMPV6_TYPES"
assert_line_before "$NFT_LOG" \
  $'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tudp\tsport\t546\tudp\tdport\t547' \
  $'mangle\tiifname\t@tachyon_interfaces\ticmpv6\ttype\t{ destination-unreachable' \
  "off drops LAN DHCPv6 client 546->547 before ESSENTIAL_ICMPV6_TYPES"
assert_file_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tTachyonTable\tlan_v6_guard_out\t{ type filter hook output priority -100; policy accept; }' "off creates filter output guard chain"
assert_file_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\tlan_v6_guard_out\toifname\t@tachyon_interfaces\ticmpv6\ttype\tnd-router-advert\tcounter\tdrop' "off blocks RA out on LAN"
assert_file_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\tlan_v6_guard_out\toifname\t@tachyon_interfaces\tudp\tsport\t547\tudp\tdport\t546\tcounter\tdrop' "off blocks DHCPv6 547->546 out on LAN"
assert_file_contains "$NFT_LOG" $'mangle_forward\tiifname\t@tachyon_interfaces\ticmpv6\ttype\t{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem }\treturn' "mangle_forward narrows allowed ICMPv6 to error types only"
assert_file_contains "$NFT_LOG" $'mangle_forward\tiifname\t@tachyon_interfaces\tmeta\tnfproto\tipv6' "off rejects transit IPv6 from LAN even with leak_guard=0"
assert_file_contains "$NFT_LOG" $'reject\twith\ticmpx\ttype\tadmin-prohibited' "off forward guard uses admin-prohibited reject"

# Switch to auto WITHOUT WAN6 PD + leak_guard=0: LAN RA/RS/DHCPv6 guard STILL active so LAN clients never get ULA/RA
sed -i 's/tachyon.settings.ipv6_mode=off/tachyon.settings.ipv6_mode=auto/' "$NFT_STATE"
: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$NFT_STATE" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  ucode -S -L "$TACHYON_LIB" "$TACHYON_LIB/nft/apply.uc" \
  nft-create-runtime-base-from-uci TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces 0x04000000 0x00200000 198.18.0.0/15 1602
assert_file_contains "$NFT_LOG" $'lan_v6_guard_out\toifname\t@tachyon_interfaces\ticmpv6\ttype\tnd-router-advert\tcounter\tdrop' "auto without WAN6 blocks RA out to LAN"
assert_file_contains "$NFT_LOG" $'mangle\tiifname\t@tachyon_interfaces\tudp\tsport\t546\tudp\tdport\t547\tcounter\tdrop' "auto without WAN6 blocks DHCPv6 546->547 on LAN"

# 6. Hotplug 99-tachyon-wan-monitor syntax and reload-on-state-change
sh -n "$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
HOTPLUG_UCI="$WORK_DIR/hotplug.state"
cat >"$HOTPLUG_UCI" <<'EOF_HP'
tachyon.settings=settings
tachyon.settings.ipv6_mode=auto
tachyon.settings.ipv6_leak_guard=1
EOF_HP
rm -f "$WORK_DIR/run/ipv6-state.json" "$WORK_DIR/run/wan6_hotplug_state"
: > "$INIT_LOG"
ACTION=ifup INTERFACE=wan6 TACHYON_UCI_STATE_FILE="$HOTPLUG_UCI" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  TACHYON_WAN6_HOTPLUG_SYNC=1 TACHYON_WAN6_HOTPLUG_DELAY=0 \
  sh "$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
[ "$(wc -l < "$INIT_LOG")" -eq 1 ] || fail "initial wan6 up triggers exactly 1 reload"

: > "$INIT_LOG"
ACTION=ifupdate INTERFACE=wan6 TACHYON_UCI_STATE_FILE="$HOTPLUG_UCI" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  TACHYON_WAN6_HOTPLUG_SYNC=1 TACHYON_WAN6_HOTPLUG_DELAY=0 \
  sh "$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
[ ! -s "$INIT_LOG" ] || fail "unchanged wan6 state must not reload tachyon"

: > "$INIT_LOG"
ACTION=ifupdate INTERFACE=wan6 TACHYON_UCI_STATE_FILE="$HOTPLUG_UCI" TACHYON_FORCE_IPV6_SUPPORTED=1 \
  TACHYON_MOCK_WAN6_PD="2001:db8:cafe::/56" TACHYON_WAN6_HOTPLUG_SYNC=1 TACHYON_WAN6_HOTPLUG_DELAY=0 \
  sh "$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
assert_file_contains "$INIT_LOG" "reload ipv6_state_change" "PD arrival triggers ipv6_state_change reload"

# 7. Doctor dry-run readonly check on IPv6 modes
UCI_DOC="$WORK_DIR/doctor_ipv6.state"
cat >"$UCI_DOC" <<'EOF_DOC'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.ipv6_mode=dual_stack
tachyon.settings.dns_strategy=prefer_ipv6
tachyon.settings.fakeip_enabled=1
tachyon.settings.source_network_interfaces=br-lan
EOF_DOC
BEFORE_DOC="$(cat "$UCI_DOC")"
DOC_CREATED_PID=0
if [ ! -e /var/run/tachyon_watchdog.pid ] && [ -w /var/run ]; then
  printf '%s\n' "$$" > /var/run/tachyon_watchdog.pid
  DOC_CREATED_PID=1
fi
TACHYON_UCI_STATE_FILE="$UCI_DOC" TACHYON_FORCE_IPV6_SUPPORTED=1 ucode -S -L "$TACHYON_LIB" -e '
  let doc = require("diagnostics.doctor");
  let common = require("core.common");
  let res = doc.run_doctor_checks_impl(false);
  if (type(res) != "object" || type(res.checks) != "array" || length(res.checks) == 0) {
    warn("doctor checks missing\n");
    exit(1);
  }
  let v6_items = filter(res.checks, c => index(lc(common.as_string(c.name || "") + " " + common.as_string(c.detail || "")), "ipv6") >= 0);
  if (length(v6_items) == 0) {
    warn("expected IPv6 diagnostic entry in doctor output\n");
    exit(1);
  }
'
if [ "$DOC_CREATED_PID" = "1" ]; then
  rm -f /var/run/tachyon_watchdog.pid
fi
AFTER_DOC="$(cat "$UCI_DOC")"
[ "$BEFORE_DOC" = "$AFTER_DOC" ] || fail "doctor dry-run modified UCI state"

printf 'ALL TESTS PASSED for ipv6_modes\n'
