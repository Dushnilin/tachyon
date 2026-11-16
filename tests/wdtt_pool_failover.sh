#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
WDTT_RUNTIME_UC="$TACHYON_LIB/providers/wdtt/runtime.uc"

# 1. Mock tachyon-core 0.5.7 state files (no qwdtt binary on disk)
printf '%s\n' "tachyon-core" >"$WORK_DIR/variant"
printf '%s\n' "0.5.7" >"$WORK_DIR/version"
printf '%s\n' "upstream" >"$WORK_DIR/upstream-variant"
printf '%s\n' "1.14.0" >"$WORK_DIR/upstream-version"

export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"
export TACHYON_QWDTT_BIN="$WORK_DIR/nonexistent-qwdtt"
export WDTT_BIN="$WORK_DIR/nonexistent-wdtt"
export TACHYON_PERSISTENT_SELECTOR_STATE_FILE="$WORK_DIR/nonexistent-selector-state.json"

cat >"$WORK_DIR/mock-tachyon-core" <<'SH'
#!/bin/sh
if [ "$1" = "version" ]; then
  echo "tachyon-core version 0.5.7"
  exit 0
fi
exit 0
SH
chmod +x "$WORK_DIR/mock-tachyon-core"

# 2. Main_Route priority_failover (CSQTT Tier 1 -> TrustTunnel Tier 2) + detour propagation + native wdtt + WG/URI overrides
cat >"$WORK_DIR/pool_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "outbound_source": [
    {
      ".name": "src_csqtt",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "CSQTT_Primary",
      "source_type": "csqtt",
      "csqtt_server": "csqtt.example.com",
      "csqtt_password": "csqtt-password",
      "csqtt_mode": "csqtt",
      "csqtt_server_port": "46000",
      "csqtt_workers": "4",
      "csqtt_mtu": "1320"
    },
    {
      ".name": "src_trusttunnel",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "TT_Backup",
      "source_type": "trusttunnel",
      "trusttunnel_server": "tt.example.com",
      "trusttunnel_server_port": "443",
      "trusttunnel_username": "alice",
      "trusttunnel_password": "secret"
    },
    {
      ".name": "src_csqtt_wg",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "CSQTT_WG",
      "source_type": "csqtt",
      "csqtt_server": "wg.example.com",
      "csqtt_password": "wg-password",
      "csqtt_mode": "wg",
      "csqtt_server_port": "56000",
      "csqtt_wg_port": "56001",
      "csqtt_local_port": "56002",
      "csqtt_wg_private_key": "privkey_abc",
      "csqtt_wg_peer_public_key": "pubkey_xyz",
      "csqtt_wg_address": "10.66.66.2/32"
    },
    {
      ".name": "src_csqtt_uri",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "CSQTT_URI_Override",
      "source_type": "csqtt",
      "csqtt_uri": "csqtt://connect?v=2&host=uri.example.com&peer=46000&password=uri-pass&srtp_mode=dtls&vk_token=leak_token",
      "csqtt_workers": "6",
      "csqtt_mtu": "1360",
      "csqtt_device_id": "router-override",
      "csqtt_chunk1": "1",
      "csqtt_raw_port": "46005",
      "csqtt_wg_port": "56111",
      "csqtt_local_port": "56222",
      "csqtt_vk_auth_mode": "vk",
      "csqtt_vk_cookie": "remix=1",
      "csqtt_vk_client_ids": [ "cid1", "cid2" ],
      "csqtt_turn_server": "turn.example.com:3478",
      "csqtt_turn_urls": [ "turn:turn.example.com:3478" ],
      "csqtt_turn_username": "tuser",
      "csqtt_turn_password": "tpass",
      "csqtt_turn_transport": "tcp"
    },
    {
      ".name": "src_wdtt_native",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "WDTT_Native",
      "source_type": "wdtt",
      "warp_flow_uri": "csqtt://connect?v=2&host=native-wdtt.example.com&peer=46000&password=native-pass"
    },
    {
      ".name": "src_wdtt_socks",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "WDTT_External",
      "source_type": "wdtt",
      "wdtt_native": "0",
      "warp_flow_uri": "wdtt://ext.example.com:56000:56001:56002:ext-pass:hash1"
    }
  ],
  "outbound_group": [
    {
      ".name": "grp_tier1_csqtt",
      ".type": "outbound_group",
      "enabled": "1",
      "name": "Tier 1 CSQTT",
      "source_refs": [ "src_csqtt" ],
      "filter_mode": "disabled"
    },
    {
      ".name": "grp_tier2_tt",
      ".type": "outbound_group",
      "enabled": "1",
      "name": "Tier 2 TrustTunnel",
      "source_refs": [ "src_trusttunnel" ],
      "filter_mode": "disabled"
    }
  ],
  "balancer": [
    {
      ".name": "bal_priority",
      ".type": "balancer",
      "enabled": "1",
      "name": "Priority Chain",
      "balancer_type": "priority",
      "outbound_group_levels": [ "grp_tier1_csqtt", "grp_tier2_tt" ],
      "active_check_interval": "5s",
      "check_timeout": "3s",
      "recovery_check_interval": "30s"
    },
    {
      ".name": "bal_grp_prio",
      ".type": "balancer",
      "enabled": "1",
      "name": "Group Priority",
      "balancer_type": "priority",
      "outbound_group_levels": [ "grp_tier1_csqtt", "grp_tier2_tt" ],
      "active_check_interval": "5s",
      "check_timeout": "3s",
      "recovery_check_interval": "30s"
    }
  ],
  "section": [
    {
      ".name": "Hop_Proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "connection_urls": [ "vless://11111111-1111-4111-8111-111111111111@hop.example.com:443?type=tcp#HopNode" ],
      "domain_suffix": [ "hop.example.org" ]
    },
    {
      ".name": "Main_Route",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "section_selection_mode": "priority_failover",
      "outbound_source_refs": [ "src_csqtt", "src_trusttunnel" ],
      "balancer_refs": [ "bal_priority" ],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "Hop_Proxy",
      "domain_suffix": [ "pool-main.example.com" ]
    },
    {
      ".name": "CSQTT_Variants",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_csqtt_wg", "src_csqtt_uri", "src_wdtt_native" ],
      "domain_suffix": [ "variants.example.com" ]
    },
    {
      ".name": "WDTT_Legacy_Pool",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_wdtt_socks" ],
      "domain_suffix": [ "legacy-wdtt.example.com" ]
    },
    {
      ".name": "Member_One",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_csqtt" ],
      "domain_suffix": [ "member-one.example.com" ]
    },
    {
      ".name": "Member_Two",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_trusttunnel" ],
      "domain_suffix": [ "member-two.example.com" ]
    },
    {
      ".name": "Group_Priority_Test",
      ".type": "section",
      "enabled": "1",
      "action": "group",
      "section_selection_mode": "priority_failover",
      "group_members": [ "Member_One", "Member_Two" ],
      "balancer_refs": [ "bal_grp_prio" ],
      "domain_suffix": [ "group-prio.example.com" ]
    }
  ]
}
JSON

mkdir -p "$WORK_DIR/gen.json.section-cache"
TACHYON_CORE_BIN="$WORK_DIR/mock-tachyon-core" ucode -L "$TACHYON_LIB" "$GENERATOR_UC" \
  generate-config-fixture "$WORK_DIR/pool_fixture.json" "$WORK_DIR/gen.json" "127.0.0.1" ||
  fail "generator failed on wdtt/csqtt pool fixture"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$WORK_DIR/gen.json"'"));
let cache = json(fs.readfile("'"$WORK_DIR/gen.json.section-cache/Main_Route.json"'"));

function find_out(tag_name) {
    for (let o in cfg.outbounds || [])
        if (o && o.tag == tag_name) return o;
    return null;
}

let csqtt_out = find_out("CSQTT_Primary");
let tt_out = find_out("TT_Backup");
if (!csqtt_out || csqtt_out.type != "wdtt")
    die("Expected CSQTT_Primary outbound with type=wdtt: " + sprintf("%J\n", csqtt_out));
if (!tt_out || tt_out.type != "trusttunnel")
    die("Expected TT_Backup outbound with type=trusttunnel: " + sprintf("%J\n", tt_out));
if (csqtt_out.detour != "Hop_Proxy-out")
    die("Expected section detour propagated to pool CSQTT outbound, got: " + sprintf("%J\n", csqtt_out.detour));
if (tt_out.detour != "Hop_Proxy-out")
    die("Expected section detour propagated to pool TrustTunnel outbound, got: " + sprintf("%J\n", tt_out.detour));

let main_sel = find_out("Main_Route-out");
let main_prio = find_out("Main_Route-priority-bal_priority-out");
if (!main_sel || !main_prio)
    die("Missing Main_Route selector or priority outbound\n");
if (main_sel.default != "Main_Route-priority-bal_priority-out")
    die("Expected Main_Route selector default to priority balancer, got: " + sprintf("%J\n", main_sel.default));
if ((main_prio.outbounds || [])[0] != "CSQTT_Primary" || (main_prio.outbounds || [])[1] != "TT_Backup")
    die("Expected Tier 1 CSQTT_Primary -> Tier 2 TT_Backup ordering, got: " + sprintf("%J\n", main_prio.outbounds));

let wg_out = find_out("CSQTT_WG");
if (!wg_out || wg_out.wg_port != 56001 || wg_out.local_port != 56002 ||
    wg_out.wg_private_key != "privkey_abc" || wg_out.wg_peer_public_key != "pubkey_xyz" ||
    wg_out.wg_address != "10.66.66.2/32")
    die("Missing WG fields on synthesized CSQTT outbound: " + sprintf("%J\n", wg_out));

let uri_out = find_out("CSQTT_URI_Override");
if (!uri_out || uri_out.server != "uri.example.com" || uri_out.password != "uri-pass" ||
    uri_out.workers != 6 || uri_out.mtu != 1360 || uri_out.device_id != "router-override" ||
    uri_out.chunk1 !== true || uri_out.raw_port != 46005 || uri_out.wg_port != 56111 ||
    uri_out.local_port != 56222 || uri_out.vk_auth_mode != "vk" ||
    uri_out.vk_cookie != "remix=1" || length(uri_out.vk_client_ids || []) != 2 ||
    uri_out.turn_server != "turn.example.com:3478" || uri_out.turn_transport != "tcp")
    die("URI src overrides mismatch: " + sprintf("%J\n", uri_out));
if (exists(uri_out, "srtp_mode") || exists(uri_out, "vk_token"))
    die("Expected sanitize_wdtt_outbound to strip srtp_mode and vk_token on 0.5.7: " + sprintf("%J\n", uri_out));

let native_wdtt = find_out("WDTT_Native");
if (!native_wdtt || native_wdtt.type != "wdtt" || native_wdtt.server != "native-wdtt.example.com")
    die("Expected native wdtt source to emit type=wdtt instead of socks: " + sprintf("%J\n", native_wdtt));

let ext_wdtt = find_out("WDTT_Legacy_Pool-wdtt-src_wdtt_socks-out");
if (!ext_wdtt || ext_wdtt.type != "socks" || ext_wdtt.server != "127.0.0.1")
    die("Expected wdtt_native=0 source to keep 127.0.0.1 socks outbound: " + sprintf("%J\n", ext_wdtt));

let grp_sel = find_out("Group_Priority_Test-out");
let grp_prio = find_out("Group_Priority_Test-priority-bal_grp_prio-out");
if (!grp_sel || !grp_prio)
    die("Missing Group_Priority_Test selector or priority outbound\n");
if (grp_sel.default != "Group_Priority_Test-priority-bal_grp_prio-out")
    die("Expected Group_Priority_Test selector default to priority outbound, got: " + sprintf("%J\n", grp_sel.default));
' || fail "pool failover / native wdtt / sanitize assertions failed"

# 3. Verify providers/wdtt/runtime.uc warp_flow_* fallback options
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/hashes"
cat >"$WORK_DIR/bin/uci" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_UCI_LOG:?}"
exit 0
SH
chmod +x "$WORK_DIR/bin/uci"

PATH="$WORK_DIR/bin:$PATH" \
MOCK_UCI_LOG="$WORK_DIR/uci.log" \
TACHYON_QWDTT_CONFIG="$WORK_DIR/qwdtt-config.json" \
TACHYON_WDTT_HASHES_DIR="$WORK_DIR/hashes" \
ucode -L "$TACHYON_LIB" -e '
let rt = require("providers.wdtt.runtime");
let sec = {
    ".name": "src_wdtt_fallback",
    ".type": "outbound_source",
    "warp_flow_uri": "qwdtt://config?ip=fallback.example.com&dtls=56000&pass=fbpass&hashes=hashA,hashB",
    "warp_flow_device_id": "fb-dev-id",
    "warp_flow_workers": "12",
    "warp_flow_mtu": "1340",
    "warp_flow_qwdtt_mode": "socks",
    "warp_flow_subscription_links": [ "qwdtt://config?ip=fallback.example.com&dtls=56000&pass=fbpass&hashes=hashA,hashB" ]
};
if (!rt.write_qwdtt_json_config(sec, "src_wdtt_fallback"))
    die("write_qwdtt_json_config failed\n");
if (!rt.write_wdtt_uci_config(sec))
    die("write_wdtt_uci_config failed\n");
' || fail "providers.wdtt.runtime warp_flow_* fallback invocation failed"

ucode -e '
let fs = require("fs");
let q = json(fs.readfile("'"$WORK_DIR/qwdtt-config.json"'"));
if (q.peer != "fallback.example.com" || q.password != "fbpass" ||
    q.device_id != "fb-dev-id" || q.workers != 12 || q.mode != "socks" ||
    length(q.hashes || []) != 2)
    die("qwdtt config warp_flow_* fallback mismatch: " + sprintf("%J\n", q));
let uci_log = fs.readfile("'"$WORK_DIR/uci.log"'") || "";
if (index(uci_log, "set wdtt.settings.mtu=1340") < 0 ||
    index(uci_log, "set wdtt.settings.workers=12") < 0 ||
    index(uci_log, "set wdtt.settings.device_id=fb-dev-id") < 0 ||
    index(uci_log, "set wdtt.settings.peer=fallback.example.com") < 0 ||
    index(uci_log, "set wdtt.settings.password=fbpass") < 0)
    die("wdtt uci config warp_flow_* fallback mismatch: " + uci_log + "\n");
' || fail "providers.wdtt.runtime warp_flow_* assertions failed"

# 4. Verify validator.uc gating for pool CSQTT/WDTT on upstream sing-box vs tachyon-core + invalid outbound_source
cat >"$WORK_DIR/validator_pool_ok.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "outbound_source": [
    {
      ".name": "src_csqtt",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "csqtt",
      "csqtt_server": "csqtt.example.com",
      "csqtt_password": "secret"
    }
  ],
  "section": [
    {
      ".name": "Pool_CSQTT",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_csqtt" ],
      "domain_suffix": [ "example.com" ]
    }
  ]
}
JSON

CTX_UPSTREAM="{\"sing_box_variant_state_file\":\"$WORK_DIR/upstream-variant\",\"sing_box_version_state_file\":\"$WORK_DIR/upstream-version\"}"
CTX_TCORE="{\"sing_box_variant_state_file\":\"$WORK_DIR/variant\",\"sing_box_version_state_file\":\"$WORK_DIR/version\"}"

if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-section-action-variant-support \
    "$WORK_DIR/validator_pool_ok.json" "$CTX_UPSTREAM" "1.14.0" >/dev/null 2>&1; then
  fail "connection section with CSQTT source must be rejected on upstream sing-box"
fi

ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-section-action-variant-support \
  "$WORK_DIR/validator_pool_ok.json" "$CTX_TCORE" "0.5.7" ||
  fail "connection section with CSQTT source must pass on tachyon-core 0.5.7"

ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture \
  "$WORK_DIR/validator_pool_ok.json" "$CTX_TCORE" ||
  fail "valid CSQTT outbound_source should pass validate-runtime-fixture"

cat >"$WORK_DIR/validator_bad_source.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "outbound_source": [
    {
      ".name": "src_bad_csqtt",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "csqtt",
      "csqtt_server": "csqtt.example.com"
    }
  ],
  "section": [
    {
      ".name": "Bad_Pool",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_bad_csqtt" ],
      "domain_suffix": [ "example.com" ]
    }
  ]
}
JSON

if ERR_OUT="$(ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/validator_bad_source.json" "$CTX_TCORE" 2>&1)"; then
  fail "CSQTT outbound_source without password must fail validate-runtime-fixture"
fi
printf '%s\n' "$ERR_OUT" | grep -Fq "requires a password" ||
  fail "expected password error for incomplete CSQTT outbound_source, got: $ERR_OUT"
