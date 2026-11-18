#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

printf '0.5.9\n' >"$WORK_DIR/core-version"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/core-version"

cat >"$WORK_DIR/resolv.conf.auto" <<'RESOLV'
# auto-generated WAN resolv
nameserver 127.0.0.1
nameserver ::1
nameserver fe80::1 # link-local should stay after IPv4 when v6 is active
nameserver 2001:4860:4860::8888
nameserver 213.234.193.1 # ISP primary DNS
nameserver 85.21.2.1
RESOLV

: >"$WORK_DIR/empty.resolv"

make_fixture() {
  local out="$1"
  local use_wan="$2"
  local ipv6_mode="$3"
  local disable_fakeip="$4"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "77.88.8.8",
    "dns_strategy": "prefer_ipv4",
    "ipv6_mode": "$ipv6_mode",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "FNS",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "doh",
      "dns_use_wan": "$use_wan",
      "disable_fakeip": "$disable_fakeip",
      "domain_suffix": [ "nalog.ru" ]
    }
  ]
}
JSON
}

make_fixture "$WORK_DIR/valid-v4off.json" "1" "off" "0"
make_fixture "$WORK_DIR/valid-v6on.json" "1" "dual_stack" "0"
make_fixture "$WORK_DIR/valid-nofakeip.json" "1" "off" "1"
make_fixture "$WORK_DIR/invalid-empty.json" "0" "off" "0"

# 1. Validator accepts empty dns_server when dns_use_wan=1, rejects when dns_use_wan=0
ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/valid-v4off.json" >/dev/null ||
  fail "validator must accept action=dns with empty dns_server when dns_use_wan=1"
if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/invalid-empty.json" >/dev/null 2>&1; then
  fail "validator must reject action=dns with empty dns_server when dns_use_wan=0"
fi

# 2. IPv6 off: filters out IPv6 WAN DNS and 127.0.0.1/::1, forces UDP even when dns_type=doh
mkdir -p "$WORK_DIR/out-v4off.json.section-cache" "$WORK_DIR/out-v4off.json.rulesets"
TACHYON_WAN_RESOLV_FILE="$WORK_DIR/resolv.conf.auto" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/valid-v4off.json" "$WORK_DIR/out-v4off.json" "127.0.0.1" "0" "1"

node - "$WORK_DIR/out-v4off.json" <<'NODE'
const fs = require("fs");
const assert = require("assert").strict;
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const dnsCfg = cfg.dns || {};
const servers = (dnsCfg.servers || []).filter((s) => String(s.tag || "").startsWith("FNS-dns-server"));

assert.equal(servers.length, 2, `expected 2 IPv4 WAN DNS servers, got ${JSON.stringify(servers)}`);
assert.deepEqual(
  servers.map((s) => [s.server, s.type]),
  [
    ["213.234.193.1", "udp"],
    ["85.21.2.1", "udp"],
  ],
);
assert(!servers.some((s) => String(s.server).includes(":") || s.server === "127.0.0.1"));

const nalogRule = (dnsCfg.rules || []).find(
  (r) => Array.isArray(r.domain_suffix) && r.domain_suffix.includes("nalog.ru"),
);
assert(nalogRule, "missing DNS rule for nalog.ru");
assert.equal(nalogRule.server, servers[0].tag, "nalog.ru DNS rule must route to primary IPv4 WAN DNS tag");
NODE

# 3. IPv6 active with prefer_ipv4: places IPv4 WAN DNS before IPv6 even if IPv6 comes first in resolv.conf
mkdir -p "$WORK_DIR/out-v6on.json.section-cache" "$WORK_DIR/out-v6on.json.rulesets"
TACHYON_WAN_RESOLV_FILE="$WORK_DIR/resolv.conf.auto" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/valid-v6on.json" "$WORK_DIR/out-v6on.json" "127.0.0.1" "0" "1"

node - "$WORK_DIR/out-v6on.json" <<'NODE'
const fs = require("fs");
const assert = require("assert").strict;
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const dnsCfg = cfg.dns || {};
const servers = (dnsCfg.servers || []).filter((s) => String(s.tag || "").startsWith("FNS-dns-server"));

assert.equal(servers.length, 4, `expected 2 IPv4 + 2 IPv6 WAN DNS servers, got ${servers.length}`);
assert.equal(servers[0].server, "213.234.193.1", "first WAN DNS server must be IPv4 under prefer_ipv4");
assert.equal(servers[1].server, "85.21.2.1");
assert.equal(servers[0].type, "udp");

const nalogRule = (dnsCfg.rules || []).find(
  (r) => Array.isArray(r.domain_suffix) && r.domain_suffix.includes("nalog.ru"),
);
assert(nalogRule, "missing DNS rule for nalog.ru with IPv6 enabled");
assert.equal(nalogRule.server, servers[0].tag, "nalog.ru must pick IPv4 WAN DNS server first");
NODE

# 4. Empty WAN resolv fallback (77.88.8.8) must use UDP, not DoH
mkdir -p "$WORK_DIR/out-empty.json.section-cache" "$WORK_DIR/out-empty.json.rulesets"
TACHYON_WAN_RESOLV_FILE="$WORK_DIR/empty.resolv" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/valid-v4off.json" "$WORK_DIR/out-empty.json" "127.0.0.1" "0" "1"

node - "$WORK_DIR/out-empty.json" <<'NODE'
const fs = require("fs");
const assert = require("assert").strict;
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const dnsCfg = cfg.dns || {};
const srv = (dnsCfg.servers || []).find((s) => String(s.tag || "").startsWith("FNS-dns-server"));
assert(srv, "missing FNS-dns-server fallback");
assert.equal(srv.server, "77.88.8.8");
assert.equal(srv.type, "udp", "77.88.8.8 fallback for empty WAN resolv must force UDP");
NODE

# 5. State signature changes when dns_use_wan or disable_fakeip toggles on action=dns
sig_use_wan="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/valid-v4off.json")"
sig_no_wan="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/invalid-empty.json")"
sig_no_fakeip="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/valid-nofakeip.json")"

[ "$sig_use_wan" != "$sig_no_wan" ] || fail "toggling dns_use_wan on action=dns must change tachyon_core_signature"
[ "$sig_use_wan" != "$sig_no_fakeip" ] || fail "toggling disable_fakeip on action=dns must change tachyon_core_signature"

printf 'dns action WAN empty dns_server tests passed\n'
