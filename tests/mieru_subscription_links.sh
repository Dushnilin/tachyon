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
