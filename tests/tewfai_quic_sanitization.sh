#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

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

cat >"$WORK_DIR/tewfai-sub.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "tewfai",
      "tag": "tf-bool-only",
      "server": "tf1.example.org",
      "server_port": 443,
      "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
      "quic": true
    },
    {
      "type": "tewfai",
      "tag": "tf-bool-str",
      "server": "tf2.example.org",
      "server_port": 443,
      "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
      "transport": "tcp",
      "quic": true
    },
    {
      "type": "tewfai",
      "tag": "tf-bool-false",
      "server": "tf3.example.org",
      "server_port": 443,
      "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
      "transport": [ "tcp" ],
      "quic": false
    },
    {
      "type": "tewfai",
      "tag": "tf-obj",
      "server": "tf4.example.org",
      "server_port": 443,
      "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
      "transport": [ "quic", "tcp" ],
      "quic": {
        "obfs": { "type": "salamander", "password": "pw" }
      }
    }
  ]
}
JSON

prepare_subscription_cache MAIN 1 "https://tewfai.example/sub" "$WORK_DIR/tewfai-sub.json"

cat >"$WORK_DIR/tewfai-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "MAIN",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_tf" ],
      "domain_suffix": [ "example.org" ]
    }
  ],
  "outbound_source": [
    {
      ".name": "src_tf",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "subscription",
      "url": "https://tewfai.example/sub"
    }
  ]
}
JSON

tf_cfg="$WORK_DIR/tewfai-cfg.json"
generate_config "$WORK_DIR/tewfai-fixture.json" "$tf_cfg"

TF_CFG="$tf_cfg" ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(getenv("TF_CFG")));
let by_server = {};
for (let ob in cfg.outbounds || []) {
    if (ob && ob.type == "tewfai")
        by_server[ob.server] = ob;
}
function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

let o1 = by_server["tf1.example.org"];
assert(o1 != null, "tf1 missing");
assert(!("quic" in o1), "tf1 must strip bool quic: " + sprintf("%J", o1));
assert(type(o1.transport) == "array" && index(o1.transport, "quic") >= 0 && index(o1.transport, "tcp") >= 0,
    "tf1 must convert quic=true to transport [quic, tcp]: " + sprintf("%J", o1));

let o2 = by_server["tf2.example.org"];
assert(o2 != null, "tf2 missing");
assert(!("quic" in o2), "tf2 must strip bool quic: " + sprintf("%J", o2));
assert(type(o2.transport) == "array" && index(o2.transport, "tcp") >= 0 && index(o2.transport, "quic") >= 0,
    "tf2 must append quic to transport: " + sprintf("%J", o2));

let o3 = by_server["tf3.example.org"];
assert(o3 != null, "tf3 missing");
assert(!("quic" in o3), "tf3 must strip bool quic=false: " + sprintf("%J", o3));
assert(type(o3.transport) == "array" && length(o3.transport) == 1 && o3.transport[0] == "tcp",
    "tf3 must preserve tcp transport: " + sprintf("%J", o3));

let o4 = by_server["tf4.example.org"];
assert(o4 != null, "tf4 missing");
assert(type(o4.quic) == "object" && o4.quic.obfs && o4.quic.obfs.type == "salamander",
    "tf4 must keep object quic intact: " + sprintf("%J", o4));
' || fail "tewfai bool quic sanitization check failed"

printf 'Tewfai bool quic sanitization checks passed\n'
