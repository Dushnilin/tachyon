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

# 1. Reject .invalid and exact "invalid" dummy domains in URI and Xray JSON subscriptions
cat >"$WORK_DIR/invalid-domains.txt" <<'TXT'
vless://11111111-1111-4111-8111-111111111111@super-auto.invalid:4659?security=tls&sni=super-auto.invalid#Auto-Dummy
vless://11111111-1111-4111-8111-111111111111@invalid:443?security=tls&sni=invalid#Bare-Invalid
vless://11111111-1111-4111-8111-111111111111@valid.example.org:443?security=tls&sni=valid.example.org#DE-Valid
TXT

invalid_uri_norm="$WORK_DIR/invalid-domains-norm.json"
normalize_subscription "$WORK_DIR/invalid-domains.txt" "$invalid_uri_norm"

ucode -e '
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
let obs = data.outbounds || [];
if (length(obs) != 1 || obs[0].server != "valid.example.org")
    die("expected only valid.example.org after rejecting .invalid hosts, got: " + sprintf("%J", obs) + "\n");
' "$invalid_uri_norm" || fail ".invalid URI domain rejection"

cat >"$WORK_DIR/invalid-xray.json" <<'JSON'
{
  "remarks": "Invalid Check",
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "bad-dot",
      "settings": { "vnext": [{ "address": "auto.invalid", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
      "streamSettings": { "security": "tls" }
    },
    {
      "protocol": "vless",
      "tag": "bad-exact",
      "settings": { "vnext": [{ "address": "INVALID", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
      "streamSettings": { "security": "tls" }
    },
    {
      "protocol": "vless",
      "tag": "good-node",
      "settings": { "vnext": [{ "address": "ok.example.org", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
      "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "ok.example.org" } }
    }
  ]
}
JSON

invalid_xray_norm="$WORK_DIR/invalid-xray-norm.json"
normalize_subscription "$WORK_DIR/invalid-xray.json" "$invalid_xray_norm"
ucode -e '
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
let obs = data.outbounds || [];
if (length(obs) != 1 || obs[0].server != "ok.example.org")
    die("expected only ok.example.org after rejecting .invalid Xray outbounds, got: " + sprintf("%J", obs) + "\n");
' "$invalid_xray_norm" || fail ".invalid Xray JSON domain rejection"

cat >"$WORK_DIR/only-invalid-xray.json" <<'JSON'
{
  "remarks": "Only Invalid",
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "bad-only",
      "settings": { "vnext": [{ "address": "auto.invalid", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
      "streamSettings": { "security": "tls" }
    }
  ]
}
JSON

if normalize_subscription "$WORK_DIR/only-invalid-xray.json" "$WORK_DIR/only-invalid-xray-norm.json" >/dev/null 2>&1; then
  fail "all-.invalid Xray subscription should fail normalization"
fi

# 2. cMaxLifetimeMs / c_max_lifetime_ms in xhttp xmux (Xray JSON + VLESS URI + share_link round-trip)
cat >"$WORK_DIR/xhttp-xmux.json" <<'JSON'
[
  {
    "remarks": "XHTTP-XMUX",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": {
          "vnext": [
            {
              "address": "xh.example.org",
              "port": 443,
              "users": [ { "id": "11111111-1111-4111-8111-111111111111", "encryption": "none" } ]
            }
          ]
        },
        "streamSettings": {
          "network": "xhttp",
          "security": "tls",
          "tlsSettings": { "serverName": "xh.example.org" },
          "xhttpSettings": {
            "mode": "packet-up",
            "path": "/stream",
            "host": "cdn.example.org",
            "extra": {
              "xmux": {
                "maxConcurrency": "0",
                "maxConnections": "0",
                "cMaxReuseTimes": "64-128",
                "cMaxLifetimeMs": 60000,
                "hKeepAlivePeriod": 30
              }
            }
          }
        }
      }
    ]
  }
]
JSON

xmux_norm="$WORK_DIR/xhttp-xmux-norm.json"
normalize_subscription "$WORK_DIR/xhttp-xmux.json" "$xmux_norm"

cat >"$WORK_DIR/xhttp-xmux-uri.txt" <<'TXT'
vless://11111111-1111-4111-8111-111111111111@xh2.example.org:443?security=tls&sni=xh2.example.org&type=xhttp&mode=stream-one&path=%2Fv2&extra=%7B%22xmux%22%3A%7B%22c_max_lifetime_ms%22%3A%2230000-60000%22%2C%22cMaxReuseTimes%22%3A%2216-32%22%7D%7D#URI-XMUX
TXT

xmux_uri_norm="$WORK_DIR/xhttp-xmux-uri-norm.json"
normalize_subscription "$WORK_DIR/xhttp-xmux-uri.txt" "$xmux_uri_norm"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let share_link = require("subscription.share_link");
let d1 = json(fs.readfile(ARGV[0]));
let d2 = json(fs.readfile(ARGV[1]));
let ob1 = (d1.outbounds || [])[0];
let ob2 = (d2.outbounds || [])[0];
if (!ob1 || !ob1.transport || !ob1.transport.xmux)
    die("missing xmux in normalized Xray xhttp outbound\n");
if (ob1.transport.xmux.c_max_lifetime_ms != "60000")
    die("expected c_max_lifetime_ms=60000 from Xray JSON, got: " + sprintf("%J", ob1.transport.xmux) + "\n");
if (ob1.transport.xmux.c_max_reuse_times != "64-128" || ob1.transport.xmux.h_keep_alive_period != 30)
    die("unexpected sibling xmux fields in Xray JSON\n");
if (!ob2 || !ob2.transport || !ob2.transport.xmux || ob2.transport.xmux.c_max_lifetime_ms != "30000-60000")
    die("expected c_max_lifetime_ms=30000-60000 from VLESS URI extra, got: " + sprintf("%J", ob2) + "\n");
let link = share_link.serialize_outbound_link(ob1);
if (index(link, "cMaxLifetimeMs") < 0)
    die("expected serialized share link to preserve cMaxLifetimeMs: " + link + "\n");
' "$xmux_norm" "$xmux_uri_norm" || fail "cMaxLifetimeMs normalization in xhttp xmux"

# 3. Multi-balancer display_name naming + multi-config balancer retention (ON, OFF, and outbound_source default)
cat >"$WORK_DIR/multi-balancer-sub.json" <<'JSON'
[
  {
    "remarks": "🇩🇪 Германия (WS)",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": { "vnext": [{ "address": "de-shared.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111", "encryption": "none" }] }] },
        "streamSettings": { "network": "ws", "security": "tls", "tlsSettings": { "serverName": "de-shared.example" }, "wsSettings": { "path": "/ws" } }
      }
    ]
  },
  {
    "remarks": "🇪🇺 🌍 Автовыбор",
    "routing": {
      "balancers": [
        { "tag": "BAL_PRIMARY", "selector": [ "proxy", "xhttp-de", "se-only" ] },
        { "tag": "RESERVE_BAL", "selector": [ "reserve-" ] },
        { "tag": "", "selector": [ "fallback-node" ] }
      ]
    },
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": { "vnext": [{ "address": "de-shared.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111", "encryption": "none" }] }] },
        "streamSettings": { "network": "ws", "security": "tls", "tlsSettings": { "serverName": "de-shared.example" }, "wsSettings": { "path": "/ws" } }
      },
      {
        "protocol": "vless",
        "tag": "xhttp-de",
        "settings": { "vnext": [{ "address": "de-shared.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111", "encryption": "none" }] }] },
        "streamSettings": { "network": "xhttp", "security": "tls", "tlsSettings": { "serverName": "de-shared.example" }, "xhttpSettings": { "path": "/xhttp" } }
      },
      {
        "protocol": "vless",
        "tag": "se-only",
        "settings": { "vnext": [{ "address": "se-only.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111112", "encryption": "none" }] }] },
        "streamSettings": { "network": "xhttp", "security": "tls", "tlsSettings": { "serverName": "se-only.example" }, "xhttpSettings": { "path": "/se" } }
      },
      {
        "protocol": "vless",
        "tag": "reserve-1",
        "settings": { "vnext": [{ "address": "res-1.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111113", "encryption": "none" }] }] },
        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "res-1.example" } }
      },
      {
        "protocol": "vless",
        "tag": "fallback-node",
        "settings": { "vnext": [{ "address": "fb-1.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111114", "encryption": "none" }] }] },
        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "fb-1.example" } }
      }
    ]
  },
  {
    "remarks": "🇸🇪 Швеция",
    "routing": {
      "balancers": [
        { "tag": "BAL_SE", "selector": [ "se-srv" ] }
      ]
    },
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "se-srv",
        "settings": { "vnext": [{ "address": "se-only.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111112", "encryption": "none" }] }] },
        "streamSettings": { "network": "xhttp", "security": "tls", "tlsSettings": { "serverName": "se-only.example" }, "xhttpSettings": { "path": "/se" } }
      }
    ]
  }
]
JSON

multi_norm="$WORK_DIR/multi-balancer-norm.json"
normalize_subscription "$WORK_DIR/multi-balancer-sub.json" "$multi_norm"
prepare_subscription_cache MAIN 1 "https://multi-bal.example/sub" "$multi_norm"

# 3a. Default outbound_source (include_urltest_groups omitted -> defaults to 1, hide_urltest_group_outbounds -> 1)
cat >"$WORK_DIR/multi-default-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "MAIN",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_multi" ],
      "domain_suffix": [ "example.org" ]
    }
  ],
  "outbound_source": [
    {
      ".name": "src_multi",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "subscription",
      "url": "https://multi-bal.example/sub"
    }
  ]
}
JSON

multi_default_cfg="$WORK_DIR/multi-default-cfg.json"
generate_config "$WORK_DIR/multi-default-fixture.json" "$multi_default_cfg"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let selector = null;
let tags = {};
for (let ob in cfg.outbounds || []) {
    if (!ob) continue;
    tags[ob.tag] = ob;
    if (ob.type == "selector" && ob.tag == "MAIN-out")
        selector = ob;
}
if (!selector)
    die("missing MAIN-out selector for multi-balancer default fixture\n");
let sel = {};
for (let m in selector.outbounds || [])
    sel[m] = true;
if (!tags["🇪🇺 🌍 Автовыбор"] || tags["🇪🇺 🌍 Автовыбор"].type != "urltest")
    die("expected first balancer to use display_name 🇪🇺 🌍 Автовыбор\n");
if (!tags["🇪🇺 🌍 Автовыбор (RESERVE_BAL)"] || tags["🇪🇺 🌍 Автовыбор (RESERVE_BAL)"].type != "urltest")
    die("expected named second balancer to use display_name (RESERVE_BAL)\n");
if (!tags["🇪🇺 🌍 Автовыбор-3"] || tags["🇪🇺 🌍 Автовыбор-3"].type != "urltest")
    die("expected unnamed third balancer to use display_name-3\n");
if (!tags["🇸🇪 Швеция"] || tags["🇸🇪 Швеция"].type != "urltest")
    die("expected single balancer in Sweden config to use 🇸🇪 Швеция\n");
if (!sel["🇪🇺 🌍 Автовыбор"] || !sel["🇪🇺 🌍 Автовыбор (RESERVE_BAL)"] || !sel["🇸🇪 Швеция"] || !sel["🇩🇪 Германия (WS)"])
    die("expected groups and standalone server in selector when outbound_source defaults to include_urltest_groups=1\n");
if (sel["xhttp-de"] || sel["se-srv"] || sel["reserve-1"])
    die("expected group members to stay hidden by default on outbound_source\n");
' "$multi_default_cfg" || fail "multi-balancer naming and outbound_source default urltest import"

# 3b. include_urltest_groups=0 with hide_urltest_group_outbounds=1 (must retain unique transports and deduplicate preferring country group)
cat >"$WORK_DIR/multi-off-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "MAIN",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_multi" ],
      "domain_suffix": [ "example.org" ]
    }
  ],
  "outbound_source": [
    {
      ".name": "src_multi",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "subscription",
      "url": "https://multi-bal.example/sub",
      "include_urltest_groups": "0",
      "hide_urltest_group_outbounds": "1"
    }
  ]
}
JSON

multi_off_cfg="$WORK_DIR/multi-off-cfg.json"
generate_config "$WORK_DIR/multi-off-fixture.json" "$multi_off_cfg"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let selector = null;
let by_tag = {};
for (let ob in cfg.outbounds || []) {
    if (!ob) continue;
    by_tag[ob.tag] = ob;
    if (ob.type == "selector" && ob.tag == "MAIN-out")
        selector = ob;
    if (ob.type == "urltest")
        die("urltest group must not be emitted when include_urltest_groups=0: " + ob.tag + "\n");
}
if (!selector)
    die("missing MAIN-out selector when include_urltest_groups=0\n");
let sel = {};
let xhttp_de_count = 0;
let se_count = 0;
let ws_de_count = 0;
for (let m in selector.outbounds || []) {
    sel[m] = true;
    if (index(lc(m), "reserve") >= 0)
        die("reserve member must not survive when include_urltest_groups=0: " + m + "\n");
    let ob = by_tag[m];
    if (!ob) continue;
    if (ob.server == "de-shared.example" && ob.transport && ob.transport.path == "/xhttp")
        xhttp_de_count++;
    if (ob.server == "de-shared.example" && ob.transport && ob.transport.path == "/ws")
        ws_de_count++;
    if (ob.server == "se-only.example")
        se_count++;
}
if (!sel["🇩🇪 Германия (WS)"])
    die("standalone 🇩🇪 Германия (WS) must survive when include_urltest_groups=0\n");
if (ws_de_count != 1)
    die("expected duplicate WS member on de-shared.example to be dropped, got ws count=" + ws_de_count + "\n");
if (xhttp_de_count != 1)
    die("distinct xhttp transport on shared host:port must not be dropped when include_urltest_groups=0\n");
if (se_count != 1)
    die("expected se-only.example to be deduplicated to 1 entry across groups, got count=" + se_count + "\n");
if (!sel["🇸🇪 Швеция"])
    die("expected deduplicated Sweden server to prefer country-specific group label 🇸🇪 Швеция, got selector=" + sprintf("%J", selector.outbounds) + "\n");
' "$multi_off_cfg" || fail "multi-config balancer retention and country-group dedup when include_urltest_groups=0"

printf 'Subscription balancer and xmux regression checks passed\n'
