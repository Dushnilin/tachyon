#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PARSER_UC="$TACHYON_LIB/subscription/parser.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

normalize_subscription() {
  local input="$1"
  local output="$2"
  ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content "$input" "$output"
}

prepare_subscription_cache() {
  local section="$1"
  local index="$2"
  local url="$3"
  local normalized_json="$4"
  local source="$WORK_DIR/subscriptions/${section}-subscription-${index}"

  mkdir -p "$WORK_DIR/subscriptions"
  cp "$normalized_json" "${source}.json"
  printf '%s\n' "$url" >"${source}.url"
  : >"${source}.user_agent"
}

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1"
}

# 1. Subscription normalization (sing-box/tachyon-core JSON) must sanitize
#    fragment.max_split=0 / "0-0", zero-lower ranges, and packets="tls_hello".
cat >"$WORK_DIR/frag-sub.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "frag-node",
      "server": "frag1.example.org",
      "server_port": 443,
      "uuid": "11111111-1111-4111-8111-111111111111",
      "fragment": {
        "packets": "tls_hello",
        "lengths": "20-40",
        "delays": "5-15",
        "max_split": "0-0"
      }
    },
    {
      "type": "trojan",
      "tag": "tcpfrag-node",
      "server": "frag2.example.org",
      "server_port": 443,
      "password": "secret",
      "tcp_fragment": {
        "maxSplit": 0,
        "length": "0-60"
      }
    },
    {
      "type": "vless",
      "tag": "finalmask-node",
      "server": "frag3.example.org",
      "server_port": 443,
      "uuid": "11111111-1111-4111-8111-111111111112",
      "finalmask": {
        "tcp": [
          {
            "type": "fragment",
            "settings": {
              "max_split": "0",
              "lengths": "10-20"
            }
          }
        ]
      }
    }
  ]
}
JSON

frag_norm="$WORK_DIR/frag-norm.json"
normalize_subscription "$WORK_DIR/frag-sub.json" "$frag_norm"

FRAG_NORM="$frag_norm" ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let common = require("core.common");
let data = json(fs.readfile(getenv("FRAG_NORM")));
let obs = data.outbounds || [];
if (length(obs) != 3)
    die("expected 3 normalized outbounds, got: " + sprintf("%J", obs) + "\n");

let by_tag = {};
for (let ob in obs)
    by_tag[ob.tag] = ob;

let f1 = by_tag["frag-node"].fragment;
if (!f1 || ("max_split" in f1) || ("maxSplit" in f1))
    die("max_split 0-0 must be removed from fragment: " + sprintf("%J", f1) + "\n");
if (f1.packets != "tlshello" || f1.lengths != "20-40" || f1.delays != "5-15")
    die("expected packets=tlshello and preserved lengths/delays: " + sprintf("%J", f1) + "\n");

let f2 = by_tag["tcpfrag-node"].tcp_fragment;
if (!f2 || ("max_split" in f2) || ("maxSplit" in f2) || f2.length != "1-60")
    die("tcp_fragment must strip maxSplit=0 and clamp length 0-60 to 1-60: " + sprintf("%J", f2) + "\n");

let f3 = by_tag["finalmask-node"].finalmask.tcp[0].settings;
if (!f3 || ("max_split" in f3) || f3.lengths != "10-20")
    die("finalmask.tcp fragment must strip max_split=\"0\" and preserve lengths: " + sprintf("%J", f3) + "\n");

// 2. OpenVPN numeric fragment MTU must remain untouched by dialer fragment sanitizer
for (let ty in [ "openvpn", "openvpn-client" ]) {
    let ovpn = common.sanitize_outbound_dialer_fragments({
        type: ty,
        tag: "ovpn-" + ty,
        fragment: 1300
    });
    if (ovpn.fragment != 1300)
        die("numeric fragment on " + ty + " must stay 1300, got: " + sprintf("%J", ovpn) + "\n");
}
' || fail "fragment sanitization in parser and common"

# 3. Pre-existing cached subscription (before parser fix) must also be sanitized at config generation time
cat >"$WORK_DIR/stale-cache.json" <<'JSON'
{
  "version": 1,
  "format": "tachyon-core-json",
  "outbounds": [
    {
      "type": "vless",
      "tag": "stale-node",
      "server": "stale.example.org",
      "server_port": 443,
      "uuid": "11111111-1111-4111-8111-111111111113",
      "fragment": {
        "packets": "tls_hello",
        "lengths": "20-40",
        "delays": "5-15",
        "max_split": "0-0"
      }
    }
  ]
}
JSON

prepare_subscription_cache MAIN 1 "https://frag.example/sub" "$WORK_DIR/stale-cache.json"

cat >"$WORK_DIR/frag-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "MAIN",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_frag" ],
      "domain_suffix": [ "example.org" ]
    }
  ],
  "outbound_source": [
    {
      ".name": "src_frag",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "subscription",
      "url": "https://frag.example/sub"
    }
  ]
}
JSON

frag_cfg="$WORK_DIR/frag-cfg.json"
generate_config "$WORK_DIR/frag-fixture.json" "$frag_cfg"

FRAG_CFG="$frag_cfg" ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(getenv("FRAG_CFG")));
let target = null;
for (let ob in cfg.outbounds || []) {
    if (ob && ob.server == "stale.example.org") {
        target = ob;
        break;
    }
}
if (!target || !target.fragment)
    die("expected stale-node outbound in generated config\n");
if (("max_split" in target.fragment) || ("maxSplit" in target.fragment))
    die("generated config must strip stale max_split 0-0: " + sprintf("%J", target.fragment) + "\n");
if (target.fragment.packets != "tlshello" || target.fragment.lengths != "20-40" || target.fragment.delays != "5-15")
    die("generated config must normalize packets=tlshello and keep ranges: " + sprintf("%J", target.fragment) + "\n");
' || fail "stale cached subscription max_split sanitization in generator.uc"

printf 'Fragment max_split sanitization checks passed\n'
