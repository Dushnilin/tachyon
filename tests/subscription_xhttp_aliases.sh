#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Issue #81: the subscription parser read only the sing-box spellings of a few
# xHTTP settings, so Remnawave/Xray profiles lost them. A node needing
# `SessionIDPlacement` / `SessionIDKey` / `uplinkHTTPMethod` /
# `scMaxBufferedPosts` was still created, but without its session config, and
# timed out.
#
# Target field names are taken from the extended core option struct
# (shtorm-7/sing-box-extended, option/v2ray_transport.go).
#
# All assertions live in one node script: the fixtures are long
# percent-encoded URIs and shell-quoting them through helper functions is
# where the harness, not the parser, breaks.

PARSER_UC="$TACHYON_LIB/subscription/parser.uc"

trap 'rm -rf "$WORK_DIR"' EXIT

# parse <uri> -> outbound JSON on stdout
parse() {
  ucode -L "$TACHYON_LIB" "$PARSER_UC" share-link-outbound "$1" 2>/dev/null
}

# The base is identical across fixtures; only the xHTTP spellings differ, so a
# failure can only come from the field mapping.
base_uri() {
  printf 'vless://00000000-0000-0000-0000-00000000000%s@example.net:443?encryption=none&security=reality&sni=example.net&fp=chrome&pbk=key&sid=ab&type=xhttp&mode=packet-up&path=%%2F&%s#n%s' "$1" "$2" "$1"
}

XRAY_EXTRA='extra=%7B%22uplinkHTTPMethod%22%3A%22GET%22%2C%22SessionIDPlacement%22%3A%22query%22%2C%22SessionIDKey%22%3A%22auth%22%2C%22sessionIDTable%22%3A%22Base62%22%2C%22sessionIDLength%22%3A%226-8%22%2C%22seqPlacement%22%3A%22query%22%2C%22seqKey%22%3A%22chunk_id%22%2C%22scMaxBufferedPosts%22%3A160%7D'
SB_EXTRA='extra=%7B%22uplinkHttpMethod%22%3A%22GET%22%2C%22sessionPlacement%22%3A%22query%22%2C%22sessionKey%22%3A%22auth%22%2C%22scMaxBufferedPosts%22%3A77%7D'
FLAT='uplinkHTTPMethod=GET&sessionIDPlacement=query&sessionIDKey=auth&scMaxBufferedPosts=99'

parse "$(base_uri 1 "$XRAY_EXTRA")" >"$WORK_DIR/xray.json"
parse "$(base_uri 2 "$SB_EXTRA")"    >"$WORK_DIR/singbox.json"
parse "$(base_uri 3 "$FLAT")"        >"$WORK_DIR/flat.json"
parse "$(base_uri 4 "")"             >"$WORK_DIR/bare.json"

for f in xray singbox flat bare; do
  grep -q '"transport"' "$WORK_DIR/$f.json" ||
    fail "$f fixture did not yield an xhttp outbound: $(cat "$WORK_DIR/$f.json")"
done

node -e '
const fs = require("fs");
const dir = process.argv[1];
const read = (n) => JSON.parse(fs.readFileSync(dir + "/" + n, "utf8")).transport;

const problems = [];
const want = (name, file, expected) => {
  const got = read(file)[name];
  if (JSON.stringify(got) !== JSON.stringify(expected))
    problems.push(`${name} in ${file}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
};

// Xray / Remnawave spellings must map onto the core field names.
want("uplink_http_method", "xray.json", "GET");
want("session_placement", "xray.json", "query");
want("session_key", "xray.json", "auth");
want("seq_placement", "xray.json", "query");
want("seq_key", "xray.json", "chunk_id");
want("sc_max_buffered_posts", "xray.json", 160);

// The sing-box camelCase spellings must keep working exactly as before.
want("uplink_http_method", "singbox.json", "GET");
want("session_placement", "singbox.json", "query");
want("session_key", "singbox.json", "auth");
want("sc_max_buffered_posts", "singbox.json", 77);

// Same behaviour for the flat query form, not just the encoded extra blob.
want("uplink_http_method", "flat.json", "GET");
want("session_placement", "flat.json", "query");
want("session_key", "flat.json", "auth");
want("sc_max_buffered_posts", "flat.json", 99);

// A profile that sets nothing must not gain invented defaults.
for (const key of ["uplink_http_method", "session_placement", "session_key", "sc_max_buffered_posts"])
  want(key, "bare.json", undefined);

if (problems.length) {
  for (const p of problems) console.error("FAIL: " + p);
  process.exit(1);
}
console.log("xHTTP alias mapping verified for Xray, sing-box and flat-query spellings");
' "$WORK_DIR" || fail "xHTTP alias mapping regression"

printf 'subscription xhttp alias checks passed\n'
