#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$TACHYON_LIB/subscription/cache.uc"
PARSER_UC="$TACHYON_LIB/subscription/parser.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
target=""
headers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -V) exit 1 ;;
    -o) target="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -x|-H|--connect-timeout|--max-time|--speed-time|--speed-limit|--max-redirs|-b|--max-filesize|--write-out|--doh-url|--dns-servers)
      shift 2 ;;
    -fL|-s|-k|--http1.1)
      shift ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 99
cat >"$target" <<'SUB'
vless://00000000-0000-4000-8000-000000000001@node1.example:443?security=tls&type=tcp#Alpha
vless://00000000-0000-4000-8000-000000000002@node2.example:443?security=tls&type=tcp#Beta
SUB
[ -z "$headers" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
printf '200'
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

# ─── Test A: Pool & disabled/non-connection section subscription updates ─────
export TACHYON_UCI_STATE_FILE="$WORK_DIR/pool-uci.state"
export TMP_TACHYON_CORE_FOLDER="$WORK_DIR/core"
export TMP_RULESET_FOLDER="$WORK_DIR/core/rulesets"
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/core/subscriptions"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/runtime/subscription-update"
export TACHYON_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/runtime/subscription-metadata"
export TACHYON_OUTBOUND_METADATA_DIR="$WORK_DIR/runtime/outbound-metadata"
export TACHYON_SECTION_CACHE_DIR="$WORK_DIR/runtime/section-cache"
export TACHYON_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/runtime/cache-format"
export TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent"
export TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/cache-format"
export TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/runtime/subscription-update.lock"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/core-version"
export TACHYON_CORE_BIN="/nonexistent"

printf '0.5.9\n' >"$TACHYON_CORE_VERSION_FILE"

cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.dns_server=1.1.1.1
tachyon.settings.bootstrap_dns_server=77.88.8.8
tachyon.src_standalone=outbound_source
tachyon.src_standalone.enabled=1
tachyon.src_standalone.source_type=subscription
tachyon.src_standalone.url=https://sub.example/standalone
tachyon.src_disabled=outbound_source
tachyon.src_disabled.enabled=1
tachyon.src_disabled.source_type=subscription
tachyon.src_disabled.url=https://sub.example/disabled
tachyon.src_awg=outbound_source
tachyon.src_awg.enabled=1
tachyon.src_awg.source_type=subscription
tachyon.src_awg.url=https://sub.example/awg
tachyon.sec_off=section
tachyon.sec_off.enabled=0
tachyon.sec_off.action=connection
tachyon.sec_off.outbound_source_refs=src_disabled
tachyon.sec_awg=section
tachyon.sec_awg.enabled=1
tachyon.sec_awg.action=awg
tachyon.sec_awg.outbound_source_refs=src_awg
STATE

# Default Tachyon/tachyon-core UA profile must be supported case-insensitively.
ucode -L "$TACHYON_LIB" "$CACHE_UC" user-agent-supported "Tachyon/1.8.1" "tachyon-core/0.5.9" ||
  fail "Tachyon UA must be accepted"

single_summary="$(ucode -L "$TACHYON_LIB" "$CACHE_UC" update-request 1 src_standalone "")"
assert_eq $'1\t0\t0\t0\t1' "$single_summary" "single standalone outbound_source pool update summary"

for cache_file in \
  "$TMP_SUBSCRIPTION_FOLDER/Pool_src_standalone-subscription-1.json" \
  "$TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR/Pool_src_standalone-subscription-1.json"; do
  [ -s "$cache_file" ] || fail "missing cached pool json: $cache_file"
  assert_eq "2" "$(ucode -L "$TACHYON_LIB" "$CACHE_UC" usable-outbound-count "$cache_file")" "standalone pool usable count"
done

all_summary="$(ucode -L "$TACHYON_LIB" "$CACHE_UC" update-request 1 "" "")"
assert_eq $'2\t0\t1\t0\t2' "$all_summary" "update-request all updates pool sources blocked only by disabled/awg sections"

for sid in src_standalone src_disabled src_awg; do
  [ -s "$TMP_SUBSCRIPTION_FOLDER/Pool_${sid}-subscription-1.json" ] ||
    fail "expected runtime pool cache for $sid"
  [ -s "$TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR/Pool_${sid}-subscription-1.json" ] ||
    fail "expected persistent pool cache for $sid"
done

update_sec_rc=0
ucode -L "$TACHYON_LIB" "$CACHE_UC" update-section Pool_src_standalone 1 >/dev/null 2>&1 || update_sec_rc=$?
# 0 = updated, 2 = unchanged (since pool cache was already imported above)
[ "$update_sec_rc" -eq 0 ] || [ "$update_sec_rc" -eq 2 ] ||
  fail "update-section on Pool_src_standalone failed with exit code $update_sec_rc"

# ─── Test B: Xray freedom fragment & finalmask inheritance ──────────────────
cat >"$WORK_DIR/xray-freedom.json" <<'JSON'
[
  {
    "remarks": "Frag1",
    "inbounds": [],
    "outbounds": [
      {
        "tag": "vless-frag1",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "frag1.example.com",
              "port": 443,
              "users": [{ "id": "00000000-0000-4000-8000-000000000011", "encryption": "none" }]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "tls",
          "tlsSettings": { "serverName": "frag1.example.com" },
          "sockopt": { "dialerProxy": "fragment" }
        }
      },
      {
        "tag": "fragment",
        "protocol": "freedom",
        "settings": {
          "fragment": {
            "packets": "tlshello",
            "length": "10-30",
            "interval": "1-3"
          }
        }
      }
    ]
  },
  {
    "remarks": "Frag2",
    "inbounds": [],
    "outbounds": [
      {
        "tag": "vless-frag2",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "frag2.example.com",
              "port": 443,
              "users": [{ "id": "00000000-0000-4000-8000-000000000012", "encryption": "none" }]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "tls",
          "tlsSettings": { "serverName": "frag2.example.com" },
          "sockopt": { "dialerProxy": "frag-fm" }
        }
      },
      {
        "tag": "frag-fm",
        "protocol": "freedom",
        "streamSettings": {
          "finalmask": {
            "tcp": [
              {
                "type": "fragment",
                "settings": { "packets": "1-1", "length": "25-50", "delay": "2-5ms" }
              }
            ]
          }
        }
      }
    ]
  },
  {
    "remarks": "Plain",
    "inbounds": [],
    "outbounds": [
      {
        "tag": "vless-plain",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "plain.example.com",
              "port": 443,
              "users": [{ "id": "00000000-0000-4000-8000-000000000013", "encryption": "none" }]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "tls",
          "tlsSettings": { "serverName": "plain.example.com" }
        }
      }
    ]
  }
]
JSON

ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content "$WORK_DIR/xray-freedom.json" "$WORK_DIR/xray-freedom-norm.json"

node - "$WORK_DIR/xray-freedom-norm.json" <<'NODE'
const fs = require("fs");
const assert = require("assert").strict;
const norm = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const byServer = new Map((norm.outbounds || []).map((o) => [o.server, o]));

const f1 = byServer.get("frag1.example.com");
assert(f1, "missing vless-frag1");
assert.equal(f1.detour, undefined, "freedom dialerProxy must not emit dangling detour");
assert.deepEqual(f1.tcp_fragment, {
  enabled: true,
  packets: "tlshello",
  length: "10-30",
  delay: "1-3ms",
});

const f2 = byServer.get("frag2.example.com");
assert(f2, "missing vless-frag2");
assert.equal(f2.detour, undefined, "finalmask freedom dialerProxy must not emit dangling detour");
assert.deepEqual(f2.tcp_fragment, {
  enabled: true,
  packets: "tlshello",
  length: "25-50",
  delay: "2-5ms",
});

const plain = byServer.get("plain.example.com");
assert(plain, "missing vless-plain");
assert.equal(plain.tcp_fragment, undefined, "control vless-plain must not gain tcp_fragment");
NODE

# ─── Test C: Per-source fragmentation, uTLS override, validator & state ──────
mkdir -p "$WORK_DIR/gen-subs" "$WORK_DIR/gen-out.json.section-cache" "$WORK_DIR/gen-out.json.rulesets"
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/gen-subs"

cat >"$WORK_DIR/sub_tcp_raw.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "sub-vless",
      "server": "sub-vless.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000021",
      "tls": { "enabled": true, "server_name": "sub-vless.example.com" }
    },
    {
      "type": "hysteria2",
      "tag": "sub-hy2",
      "server": "sub-hy2.example.com",
      "server_port": 443,
      "password": "secret",
      "tls": { "enabled": true, "server_name": "sub-hy2.example.com" }
    }
  ]
}
JSON
ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-content-validated "$WORK_DIR/sub_tcp_raw.json" "$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-1.json"
printf 'https://sub.example/frag-source' >"$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-1.url"
printf 'Happ' >"$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-1.user_agent"

cat >"$WORK_DIR/frag-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "77.88.8.8",
    "service_listen_address": "127.0.0.1"
  },
  "outbound_source": [
    {
      ".name": "sub_tcp",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "subscription",
      "url": "https://sub.example/frag-source",
      "tls_fingerprint": "chrome",
      "tls_fragment_mode": "tcp_fragment",
      "tcp_fragment_length": "15-45",
      "tcp_fragment_delay": "1-4ms"
    },
    {
      ".name": "links_tls",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "proxy_links",
      "proxy_links": [
        "vless://00000000-0000-4000-8000-000000000022@link-tls.example.com:443?security=tls&sni=link-tls.example.com#LinkTLS",
        "hysteria2://secret@link-hy2.example.com:443?sni=link-hy2.example.com#LinkHy2"
      ],
      "tls_fingerprint": "firefox",
      "tls_fragment_mode": "tls_fragment"
    },
    {
      ".name": "links_rec",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "proxy_links",
      "proxy_links": [
        "vless://00000000-0000-4000-8000-000000000023@link-rec.example.com:443?security=tls&sni=link-rec.example.com#LinkRec"
      ],
      "tls_fragment_mode": "tls_record"
    }
  ],
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "sub_tcp", "links_tls", "links_rec" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/frag-fixture.json" >/dev/null
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/frag-fixture.json" "$WORK_DIR/gen-out.json" "127.0.0.1" "0" "1"

node - "$WORK_DIR/gen-out.json" <<'NODE'
const fs = require("fs");
const assert = require("assert").strict;
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outbounds = cfg.outbounds || [];
const byServer = new Map(outbounds.filter((o) => o.server).map((o) => [o.server, o]));

const subVless = byServer.get("sub-vless.example.com");
assert(subVless, "missing sub-vless");
assert.deepEqual(subVless.tcp_fragment, {
  enabled: true,
  packets: "tlshello",
  length: "15-45",
  delay: "1-4ms",
});
assert.equal(subVless.tls && subVless.tls.utls && subVless.tls.utls.fingerprint, "chrome", "sub-vless must inherit chrome uTLS override");

const subHy2 = byServer.get("sub-hy2.example.com");
assert(subHy2, "missing sub-hy2");
assert.equal(subHy2.tcp_fragment, undefined, "hysteria2 must not receive tcp_fragment");
assert.equal(subHy2.tls && subHy2.tls.utls, undefined, "hysteria2 must not receive tls.utls");

const linkTls = byServer.get("link-tls.example.com");
assert(linkTls, "missing link-tls");
assert.equal(linkTls.tls && linkTls.tls.fragment, true, "proxy_links tls_fragment must set tls.fragment=true");
assert.equal(linkTls.tls && linkTls.tls.utls && linkTls.tls.utls.fingerprint, "firefox", "proxy_links must apply tls_fingerprint override");

const linkHy2 = byServer.get("link-hy2.example.com");
assert(linkHy2, "missing link-hy2");
assert.equal(linkHy2.tls && linkHy2.tls.fragment, undefined, "hysteria2 proxy_link must not receive tls.fragment");

const linkRec = byServer.get("link-rec.example.com");
assert(linkRec, "missing link-rec");
assert.equal(linkRec.tls && linkRec.tls.record_fragment, true, "tls_record must set tls.record_fragment=true");

for (const group of outbounds.filter((o) => o.type === "urltest" || o.type === "selector")) {
  assert.equal(group.tcp_fragment, undefined, `group outbound ${group.tag} must not receive tcp_fragment`);
}
NODE

# Invalid fragmentation config must be rejected by validator
node - "$WORK_DIR/frag-fixture.json" "$WORK_DIR/bad-mode.json" "$WORK_DIR/bad-range.json" <<'NODE'
const fs = require("fs");
const baseRaw = fs.readFileSync(process.argv[2], "utf8");
const badMode = JSON.parse(baseRaw);
badMode.outbound_source[0].tls_fragment_mode = "invalid_mode";
fs.writeFileSync(process.argv[3], JSON.stringify(badMode, null, 2));
const badRange = JSON.parse(baseRaw);
badRange.outbound_source[0].tcp_fragment_length = "60-20";
fs.writeFileSync(process.argv[4], JSON.stringify(badRange, null, 2));
NODE

if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/bad-mode.json" >/dev/null 2>&1; then
  fail "validator must reject invalid tls_fragment_mode"
fi
if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/bad-range.json" >/dev/null 2>&1; then
  fail "validator must reject inverted tcp_fragment_length range"
fi

# Changing fragmentation options must change tachyon-core signature for both subscription and proxy_links
export TACHYON_UCI_STATE_FILE="$WORK_DIR/sig.uci.state"
write_sig_state() {
  cat >"$TACHYON_UCI_STATE_FILE" <<EOF_SIG
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.proxy=section
tachyon.proxy.enabled=1
tachyon.proxy.action=connection
tachyon.proxy.outbound_source_refs=s_sub s_links
tachyon.s_sub=outbound_source
tachyon.s_sub.enabled=1
tachyon.s_sub.source_type=subscription
tachyon.s_sub.url=https://sub.example/sig
tachyon.s_sub.tls_fragment_mode=$1
tachyon.s_links=outbound_source
tachyon.s_links.enabled=1
tachyon.s_links.source_type=proxy_links
tachyon.s_links.proxy_links=vless://00000000-0000-4000-8000-000000000031@sig.example.com:443?security=tls#Sig
tachyon.s_links.tls_fragment_mode=$2
EOF_SIG
}

write_sig_state "" ""
sig_base="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature)"
write_sig_state "tcp_fragment" ""
sig_sub_changed="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature)"
write_sig_state "" "tls_record"
sig_links_changed="$(ucode -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature)"

[ "$sig_base" != "$sig_sub_changed" ] || fail "subscription tls_fragment_mode must change tachyon_core_signature"
[ "$sig_base" != "$sig_links_changed" ] || fail "proxy_links tls_fragment_mode must change tachyon_core_signature"

printf 'subscription pool and fragmentation tests passed\n'
