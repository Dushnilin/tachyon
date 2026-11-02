#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

node "$ROOT_DIR/tests/lib/happ_vectors.cjs" "$TACHYON_LIB/subscription/happ-keys.json" "$WORK_DIR/vectors.json"

cat >"$WORK_DIR/decrypt.uc" <<'UCODE'
let fs = require("fs");
let h = require("subscription.happ");
let parser = require("subscription.parser");
let v = json(fs.readfile(ARGV[0]));
for (let test in v.valid) {
    if (!parser.parse_subscription_source_entry(test.link).valid)
        die("source parser rejected " + test.name + "\n");
    if (h.decrypt(test.link) != test.expected)
        die("decrypt failed: " + test.name + "\n");
}
for (let link in v.invalid)
    if (h.decrypt(link) != null)
        die("invalid or unauthenticated link was accepted\n");
fs.writefile(ARGV[1], filter(v.valid, t => t.name == "crypt5-legacy")[0].link);
fs.writefile(ARGV[2], filter(v.valid, t => t.name == "inline")[0].link);
print("RSA and authenticated crypt5 vectors passed\n");
UCODE
ucode -L "$TACHYON_LIB" "$WORK_DIR/decrypt.uc" "$WORK_DIR/vectors.json" "$WORK_DIR/http.link" "$WORK_DIR/inline.link"

# A wrapped URL must be fetched with the original profile, not treated as the
# subscription content. Mock only the transport; cryptography remains real.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HAPP_CURL_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    shift
    printf '%s\n' 'vless://00000000-0000-4000-8000-000000000001@example.com:443#Synthetic' >"$1"
  fi
  shift
done
printf '200'
SH
chmod +x "$WORK_DIR/bin/curl"
export HAPP_CURL_ARGS="$WORK_DIR/curl-args"
PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/cache.uc" \
  download-subscription "$(cat "$WORK_DIR/http.link")" "$WORK_DIR/download" "" "" 'Happ-test' 'test-hwid'
grep -Fqx 'https://subscription.example/test?token=synthetic' "$HAPP_CURL_ARGS" || fail 'wrapped HTTP URL was not fetched'
grep -Fqx 'User-Agent: Happ-test' "$HAPP_CURL_ARGS" || fail 'User-Agent was lost'
grep -Fqx 'X-HWID: test-hwid' "$HAPP_CURL_ARGS" || fail 'HWID was lost'
grep -Fq 'vless://' "$WORK_DIR/download" || fail 'downloaded the URL instead of the body'
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/cache.uc" \
  download-subscription "$(cat "$WORK_DIR/inline.link")" "$WORK_DIR/inline" "" "" 'Happ-test' 'test-hwid'
grep -Fq '#Synthetic' "$WORK_DIR/inline" || fail 'encrypted inline subscription was lost'

printf 'previous working content' >"$WORK_DIR/last-working"
if PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/cache.uc" \
  download-subscription 'happ://crypt5/broken' "$WORK_DIR/last-working" "" "" 'Happ-test' 'test-hwid'; then
  fail 'broken crypt5 download succeeded'
fi
[ "$(cat "$WORK_DIR/last-working")" = 'previous working content' ] || fail 'broken link replaced the working body'

# The reported outage: one uncached/broken Happ source must not remove the
# manual server and HTTP subscription already used by the same section.
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [{ ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": ["socks5://127.0.0.1:1081#Working"],
    "outbound_source_refs": ["bad_happ", "future_happ"] }],
  "outbound_source": [
    { ".name": "bad_happ", ".type": "outbound_source", "enabled": "1", "source_type": "subscription", "url": "happ://crypt5/broken" },
    { ".name": "future_happ", ".type": "outbound_source", "enabled": "1", "source_type": "subscription", "url": "happ://crypt6/broken" }
  ]
}
JSON
mkdir -p "$WORK_DIR/config.json.section-cache" "$WORK_DIR/subscriptions"
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" \
  generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" '127.0.0.1'
ucode -e 'let c=json(require("fs").readfile(ARGV[0])); if (!length(filter(c.outbounds, o => o.tag == "proxy-out"))) die("working proxy section was dropped\n");' "$WORK_DIR/config.json"
printf 'Happ download and broken-source isolation checks passed\n'
