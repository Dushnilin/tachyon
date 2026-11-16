#!/usr/bin/env bash
# Regression coverage for Mieru (mierus:// and mieru://) link parsing,
# multi-port/range handling, share-link round-tripping and core CLI override.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
CORE_STUB="$WORK_DIR/bin/tachyon-core"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"

cat >"$CORE_STUB" <<'SH'
#!/usr/bin/env bash
set -eo pipefail

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  printf 'tachyon-core 0.0.0-stub\n'
  exit 0
fi

if [ "${1:-}" = "subscription" ] && [ "${2:-}" = "hwid" ]; then
  printf 'stub-hwid\n'
  exit 0
fi

if [ "${1:-}" = "subscription" ] && [ "${2:-}" = "--help" ]; then
  printf 'subscription parse\n'
  exit 0
fi

if [ "${1:-}" = "subscription" ] && [ "${2:-}" = "parse" ]; then
  out_file=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output)
        out_file="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [ -n "$out_file" ] || exit 2
  cat >"$out_file" <<'JSON'
[
  {
    "type": "mieru",
    "tag": "🇫🇮 Finland | LainDEV",
    "server": "198.51.100.10",
    "server_port": 443,
    "transport": "TCP",
    "username": "testuser",
    "password": "testpass",
    "multiplexing": "MULTIPLEXING_HIGH"
  },
  {
    "type": "mieru",
    "tag": "RangeBug",
    "server": "203.0.113.6",
    "server_port": 443,
    "transport": "UDP",
    "username": "u",
    "password": "p",
    "multiplexing": "MULTIPLEXING_LOW"
  }
]
JSON
  exit 0
fi

exit 0
SH
chmod 0755 "$CORE_STUB"

SAMPLE_URI="mierus://testuser:testpass@198.51.100.10?profile=%F0%9F%87%AB%F0%9F%87%AE+Finland%7CLainDEV&mtu=1400&port=20100&protocol=TCP#%F0%9F%87%AB%F0%9F%87%AE%20Finland%7CLainDEV"
RANGE_URI="mierus://u:p@203.0.113.6?port=2010-2020&protocol=UDP#RangeBug"
MULTI_URI="mierus://u:p@203.0.113.7?port=2010&port=2020-2030&protocol=TCP&traffic-pattern=random#MultiPort"
ENCODED_URI="mierus://user%3Aone:p%3Ass@203.0.113.5?port=20200&protocol=UDP#EncCreds"
IPV6_URI="mierus://u:p@[2001:db8::1]?port=20443&protocol=UDP#V6Node"

cat >"$WORK_DIR/sub.txt" <<EOF
$SAMPLE_URI
$RANGE_URI
EOF

cat >"$WORK_DIR/verify_mieru.uc" <<'UC'
let fs = require("fs");
let parser = require("subscription.parser");
let share = require("subscription.share_link");

let sample_uri = getenv("SAMPLE_URI");
let range_uri = getenv("RANGE_URI");
let multi_uri = getenv("MULTI_URI");
let encoded_uri = getenv("ENCODED_URI");
let ipv6_uri = getenv("IPV6_URI");

let out1 = parser.parse_share_link(sample_uri);
if (!out1 || out1.type != "mieru")
    die("parse_share_link failed for sample mierus:// URI\n");
if (out1.server != "198.51.100.10" || out1.server_port != 20100 || out1.transport != "TCP")
    die(sprintf("unexpected endpoint/port for sample URI: %J\n", out1));
if (out1.username != "testuser" || out1.password != "testpass")
    die(sprintf("unexpected credentials for sample URI: %J\n", out1));
if (out1.tag != "🇫🇮 Finland|LainDEV")
    die(sprintf("unexpected tag for sample URI: %J\n", out1.tag));
if (exists(out1, "mtu"))
    die("mieru outbound must not emit unknown mtu field\n");

let link1 = share.serialize_outbound_link(out1);
if (index(link1, "mierus://testuser:testpass@198.51.100.10?") != 0)
    die("serialized mierus:// link must keep port out of host authority: " + link1 + "\n");
if (index(link1, ":443") >= 0 || index(link1, "port=20100") < 0 || index(link1, "protocol=TCP") < 0)
    die("serialized mierus:// link query mismatch: " + link1 + "\n");
if (index(link1, "profile=") < 0)
    die("serialized mierus:// link should preserve profile parameter: " + link1 + "\n");
let roundtrip1 = parser.parse_share_link(link1);
if (!roundtrip1 || roundtrip1.server_port != 20100 || roundtrip1.tag != "🇫🇮 Finland|LainDEV")
    die(sprintf("round-trip mismatch for sample link: %J\n", roundtrip1));

let out_enc = parser.parse_share_link(encoded_uri);
if (!out_enc || out_enc.username != "user:one" || out_enc.password != "p:ss" || out_enc.server_port != 20200 || out_enc.transport != "UDP")
    die(sprintf("percent-encoded colon in credentials broke parsing: %J\n", out_enc));

let out_range = parser.parse_share_link(range_uri);
if (!out_range || out_range.server_port != null || type(out_range.server_ports) != "array" || length(out_range.server_ports) != 1 || out_range.server_ports[0] != "2010-2020")
    die(sprintf("single range port parsing mismatch: %J\n", out_range));
let link_range = share.serialize_outbound_link(out_range);
if (index(link_range, "mierus://u:p@203.0.113.6?") != 0 || index(link_range, "port=2010-2020") < 0)
    die("serialized range mierus:// link mismatch: " + link_range + "\n");

let out_multi = parser.parse_share_link(multi_uri);
if (!out_multi || type(out_multi.server_ports) != "array" || length(out_multi.server_ports) != 2 ||
    out_multi.server_ports[0] != "2010" || out_multi.server_ports[1] != "2020-2030" ||
    out_multi.traffic_pattern != "random")
    die(sprintf("multi-port mierus:// parsing mismatch: %J\n", out_multi));
let link_multi = share.serialize_outbound_link(out_multi);
if (index(link_multi, "port=2010&port=2020-2030") < 0 || index(link_multi, "traffic-pattern=random") < 0)
    die("serialized multi-port mierus:// link mismatch: " + link_multi + "\n");

let out_v6 = parser.parse_share_link(ipv6_uri);
if (!out_v6 || out_v6.server != "2001:db8::1" || out_v6.server_port != 20443)
    die(sprintf("IPv6 mierus:// parsing mismatch: %J\n", out_v6));
let link_v6 = share.serialize_outbound_link(out_v6);
if (index(link_v6, "mierus://u:p@[2001:db8::1]?") != 0 || index(link_v6, "port=20443") < 0)
    die("serialized IPv6 mierus:// link mismatch: " + link_v6 + "\n");

let b64_raw = b64enc(fs.readfile(getenv("WORK_DIR") + "/sub.txt"));
fs.writefile(getenv("WORK_DIR") + "/sub_b64.txt", b64_raw);

let core_out_file = getenv("WORK_DIR") + "/core_normalized.json";
let ok = parser.try_normalize_with_core_cli(getenv("WORK_DIR") + "/sub_b64.txt", core_out_file);
if (!ok)
    die("try_normalize_with_core_cli failed against stub binary\n");
let normalized = json(fs.readfile(core_out_file));
if (!normalized || type(normalized.outbounds) != "array" || length(normalized.outbounds) != 2)
    die(sprintf("unexpected normalized outbounds count: %J\n", normalized));

let fixed_single = normalized.outbounds[0];
if (fixed_single.server_port != 20100 || fixed_single.tag != "🇫🇮 Finland|LainDEV")
    die(sprintf("core CLI override failed for single-port mierus://: %J\n", fixed_single));

let fixed_range = normalized.outbounds[1];
if (fixed_range.server_port != null || type(fixed_range.server_ports) != "array" || fixed_range.server_ports[0] != "2010-2020")
    die(sprintf("core CLI override failed for range mierus://: %J\n", fixed_range));

print("mieru subscription link tests passed\n");
UC

SAMPLE_URI="$SAMPLE_URI" \
RANGE_URI="$RANGE_URI" \
MULTI_URI="$MULTI_URI" \
ENCODED_URI="$ENCODED_URI" \
IPV6_URI="$IPV6_URI" \
WORK_DIR="$WORK_DIR" \
TACHYON_CORE_BIN="$CORE_STUB" \
  ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_mieru.uc"

# Extended checks (198.51.100.47, %3D single-decode, base64/Clash YAML, urltestCandidateTags):
cat >"$WORK_DIR/clash_mieru.yaml" <<'YAML'
proxies:
  - name: "Mieru"
    type: mieru
    server: 198.51.100.47
    port-range: "2012-2022"
    transport: TCP
    username: default
    password: "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ="
    multiplexing: MULTIPLEXING_HIGH
    handshake-mode: HANDSHAKE_NO_WAIT
    traffic-pattern: GgQIARAK
  - name: "Mieru"
    type: mieru
    server: 198.51.100.48
    ports:
      - "2012-2022"
      - "2030"
    transport: TCP
    username: default
    password: "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ="
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: GgQIARAK
YAML

TACHYON_CORE_BIN="" ucode -S -L "$LIB_DIR" "$LIB_DIR/subscription/parser.uc" normalize-clash-yaml "$WORK_DIR/clash_mieru.yaml" "$WORK_DIR/clash_mieru.json"

cat >"$WORK_DIR/verify_mieru_extended.uc" <<'UC'
let fs = require("fs");
let parser = require("subscription.parser");
let share = require("subscription.share_link");
let generator = require("tachyon_core.generator_outbounds");

function die_ext(msg) {
    warn(msg);
    exit(1);
}

let work_dir = getenv("WORK_DIR");
let uri_pct3d = "mierus://default:dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ%3D@198.51.100.47?profile=default&port=2012-2022&protocol=TCP&multiplexing=MULTIPLEXING_HIGH&handshake-mode=HANDSHAKE_NO_WAIT&traffic-pattern=GgQIARAK#Mieru";
let uri_plus = "mierus://user%2Bx:pass%2Bword%3D@198.51.100.47?port=2012-2022&protocol=TCP&traffic-pattern=GgQIARAK#Mieru";
let uri_hostport = "mierus://default:dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ%3D@198.51.100.48:2015?profile=default&protocol=TCP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=GgQIARAK#Mieru";

let parsed_3d = parser.parse_share_link(uri_pct3d);
if (!parsed_3d || parsed_3d.type != "mieru")
    die_ext(sprintf("failed to parse mierus URI without port: %J\n", parsed_3d));
if (parsed_3d.server != "198.51.100.47" || parsed_3d.server_port != null)
    die_ext(sprintf("expected range-only mieru server_port null: %J\n", parsed_3d));
if (type(parsed_3d.server_ports) != "array" || parsed_3d.server_ports[0] != "2012-2022")
    die_ext(sprintf("unexpected server_ports for range mierus URI: %J\n", parsed_3d));
if (parsed_3d.password != "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ=")
    die_ext(sprintf("%%3D must decode once in password: %J\n", parsed_3d));
if (parsed_3d.traffic_pattern != "GgQIARAK" || parsed_3d.handshake_mode != "HANDSHAKE_NO_WAIT")
    die_ext(sprintf("lost traffic_pattern or handshake_mode on mierus URI: %J\n", parsed_3d));

let parsed_plus = parser.parse_share_link("mierus://user+x:pass+word%3D@198.51.100.47?port=2012-2022&protocol=TCP&traffic-pattern=GgQIARAK#Mieru");
if (!parsed_plus || parsed_plus.username != "user+x" || parsed_plus.password != "pass+word=")
    die_ext(sprintf("literal + in credentials must be preserved: %J\n", parsed_plus));

let round_link = share.serialize_outbound_link(parsed_3d);
if (!round_link || index(round_link, "traffic-pattern=GgQIARAK") < 0 || index(round_link, "handshake-mode=HANDSHAKE_NO_WAIT") < 0)
    die_ext(sprintf("share link serializer omitted mieru traffic/handshake params: %J\n", round_link));
let round_parsed = parser.parse_share_link(round_link);
if (!round_parsed || round_parsed.password != parsed_3d.password || round_parsed.traffic_pattern != "GgQIARAK" || round_parsed.handshake_mode != "HANDSHAKE_NO_WAIT")
    die_ext(sprintf("round-trip parsed mismatch: %J\n", round_parsed));

// Raw + base64 subscription with duplicate #Mieru tags
let sub_text = uri_pct3d + "\n" + uri_hostport + "\n";
fs.writefile(work_dir + "/mieru_raw.txt", sub_text);
fs.writefile(work_dir + "/mieru_b64.txt", b64enc(sub_text));
fs.writefile(work_dir + "/empty_headers.txt", "");

if (!parser.normalize_content_validated(work_dir + "/mieru_raw.txt", work_dir + "/mieru_raw.json", work_dir + "/empty_headers.txt", "tachyon-core"))
    die_ext(sprintf("normalize_content_validated failed for raw mieru list: %s\n", parser.get_last_normalize_error()));
if (!parser.normalize_content_validated(work_dir + "/mieru_b64.txt", work_dir + "/mieru_b64.json", work_dir + "/empty_headers.txt", "tachyon-core"))
    die_ext(sprintf("normalize_content_validated failed for base64 mieru list: %s\n", parser.get_last_normalize_error()));

for (let path in [ work_dir + "/mieru_raw.json", work_dir + "/mieru_b64.json" ]) {
    let doc = json(fs.readfile(path));
    if (!doc || type(doc.outbounds) != "array" || length(doc.outbounds) != 2)
        die_ext(sprintf("expected 2 outbounds in %s: %J\n", path, doc));
    if (doc.outbounds[0].server_port != null || doc.outbounds[0].server_ports[0] != "2012-2022" || doc.outbounds[0].traffic_pattern != "GgQIARAK")
        die_ext(sprintf("bad first outbound in %s: %J\n", path, doc.outbounds[0]));
    if (doc.outbounds[1].server_port != 2015 || doc.outbounds[1].password != "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ=")
        die_ext(sprintf("bad second outbound in %s: %J\n", path, doc.outbounds[1]));
}

// Clash YAML mieru output check
let clash_doc = json(fs.readfile(work_dir + "/clash_mieru.json"));
if (!clash_doc || type(clash_doc.outbounds) != "array" || length(clash_doc.outbounds) != 2)
    die_ext(sprintf("unexpected clash_mieru.json: %J\n", clash_doc));
let clash0 = clash_doc.outbounds[0];
let clash1 = clash_doc.outbounds[1];
if (clash0.server_port != null || type(clash0.server_ports) != "array" || clash0.server_ports[0] != "2012-2022" || clash0.traffic_pattern != "GgQIARAK" || clash0.handshake_mode != "HANDSHAKE_NO_WAIT")
    die_ext(sprintf("clash YAML mieru port-range/traffic-pattern mismatch: %J\n", clash0));
if (clash1.server_port != null || length(clash1.server_ports) != 2 || clash1.server_ports[0] != "2012-2022" || clash1.server_ports[1] != "2030")
    die_ext(sprintf("clash YAML mieru ports list mismatch: %J\n", clash1));

// generator_outbounds: urltest_leaf_candidate_outbound + add_mieru_outbound + add_connections_outbound urltestCandidateTags
let range_mieru_sb = {
    type: "mieru",
    tag: "m-range-1",
    server: "198.51.100.47",
    server_ports: [ "2012:2022" ],
    transport: "TCP",
    username: "default",
    password: "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ="
};
if (!generator.urltest_leaf_candidate_outbound(range_mieru_sb))
    die_ext("urltest_leaf_candidate_outbound must return true for range-only mieru\n");

let hy2_range_sb = {
    type: "hysteria2",
    tag: "hy2-range-1",
    server: "198.51.100.47",
    server_ports: [ "20000:20500" ],
    password: "test"
};
if (!generator.urltest_leaf_candidate_outbound(hy2_range_sb))
    die_ext("urltest_leaf_candidate_outbound must return true for range-only hysteria2\n");

let direct_cfg = { outbounds: [] };
generator.add_mieru_outbound(direct_cfg, {
    ".name": "mieru_sec",
    ".type": "section",
    mieru_server: "198.51.100.47",
    mieru_server_ports: [ "2012:2022" ],
    mieru_transport: "TCP",
    mieru_username: "default",
    mieru_password: "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ=",
    mieru_handshake_mode: "HANDSHAKE_NO_WAIT",
    mieru_traffic_pattern: "GgQIARAK"
});
if (length(direct_cfg.outbounds) != 1 || direct_cfg.outbounds[0].server_port != null ||
    direct_cfg.outbounds[0].traffic_pattern != "GgQIARAK" ||
    direct_cfg.outbounds[0].handshake_mode != "HANDSHAKE_NO_WAIT" ||
    direct_cfg.outbounds[0].server_ports[0] != "2012-2022")
    die_ext(sprintf("add_mieru_outbound mismatch: %J\n", direct_cfg));

let captured_state = null;
generator.init({
    runtime_settings: function() { return {}; },
    is_sb_1_14_plus: function() { return true; },
    atomic_write_json_file: function(_path, state) { captured_state = state; return true; },
    routes: {
        section_needs_country_is: function() { return false; },
        section_has_direct_priority_level: function() { return false; },
        add_proxy_selector: function() { return null; },
        urltest_outbound_tag: function(n, p) { return p + "-" + n; },
        urltest_idle_timeout: function() { return ""; }
    },
    runtime_generate_unsupported: function(msg) { die_ext("unexpected generator error: " + msg + "\n"); }
});

let conn_cfg = { outbounds: [], endpoints: [] };
generator.add_connections_outbound(conn_cfg, {
    ".name": "MieruSec",
    ".type": "section",
    enabled: "1",
    action: "connection",
    selector_proxy_links: [ uri_pct3d, uri_hostport ]
}, {});
if (!captured_state || type(captured_state.urltestCandidateTags) != "array" || length(captured_state.urltestCandidateTags) != 2)
    die_ext(sprintf("expected 2 urltestCandidateTags for mieru section (including range-only node): %J\n", captured_state));

// Single range-only Mieru node must also stay in urltestCandidateTags (not dropped when alone)
captured_state = null;
let single_cfg = { outbounds: [], endpoints: [] };
generator.add_connections_outbound(single_cfg, {
    ".name": "MieruSingleSec",
    ".type": "section",
    enabled: "1",
    action: "connection",
    selector_proxy_links: [ uri_pct3d ]
}, {});
if (!captured_state || type(captured_state.urltestCandidateTags) != "array" || length(captured_state.urltestCandidateTags) != 1)
    die_ext(sprintf("single range-only mieru node dropped from urltestCandidateTags: %J\n", captured_state));

print("mieru extended subscription and urltest candidate tests passed\n");
UC

WORK_DIR="$WORK_DIR" \
TACHYON_CORE_BIN="" \
  ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_mieru_extended.uc"
