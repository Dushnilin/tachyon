#!/usr/bin/env bash
# #416: "Exclude traffic types" (excluded_protocol) on one section must apply to
# that section's own domains/addresses. It used to emit one catch-all rule
# (tproxy inbound + protocol -> direct) that sent the protocol direct for every
# section's traffic: QUIC excluded on a YouTube section broke QUIC to ChatGPT
# on another section, and took it out of the proxy.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
mkdir -p "$WORK_DIR/out.json.section-cache"
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "youtube", ".type": "section", "enabled": "1", "action": "proxy",
      "domain_suffix": [ "youtube.com" ], "excluded_protocol": [ "quic", "udp" ],
      "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000001@yt.example:443?encryption=none&security=tls&sni=yt.example#YT" ] },
    { ".name": "main", ".type": "section", "enabled": "1", "action": "proxy",
      "domain_suffix": [ "chatgpt.com" ],
      "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000002@main.example:443?encryption=none&security=tls&sni=main.example#Main" ] }
  ]
}
JSON
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/out.json" 127.0.0.1 >/dev/null 2>"$WORK_DIR/err" ||
  fail "generator rejected the fixture: $(tail -3 "$WORK_DIR/err")"

ucode -e '
let rules = (json(require("fs").readfile(ARGV[0])).route || {}).rules || [];
function arr(v) { return type(v) == "array" ? v : (v == null ? [] : [ v ]); }
function has(r, key, v) { return index(arr(r[key]), v) >= 0; }
let yt_excl = -1, yt_main = -1, yt_net = -1;
for (let i = 0; i < length(rules); i++) {
    let r = rules[i];
    let excl = has(r, "protocol", "quic");
    let matchers = filter(keys(r), (k) => index([ "action", "outbound", "inbound", "protocol", "network" ], k) < 0);
    if (excl && length(matchers) == 0)
        die("catch-all excluded-protocol rule (every section affected): " + sprintf("%J", r) + "\n");
    if ((excl || has(r, "network", "udp")) && has(r, "domain_suffix", "chatgpt.com"))
        die("youtube exclusion leaked into the main section: " + sprintf("%J", r) + "\n");
    if (has(r, "domain_suffix", "youtube.com")) {
        if (excl && r.outbound == "direct-out" && yt_excl < 0) yt_excl = i;
        else if (has(r, "network", "udp") && r.outbound == "direct-out" && r.protocol == null && yt_net < 0) yt_net = i;
        else if (!excl && r.network == null && r.action == "route" && r.outbound != "direct-out" && yt_main < 0) yt_main = i;
    }
}
if (yt_excl < 0) die("no QUIC exclusion for the youtube section\n");
if (yt_net < 0) die("no UDP exclusion for the youtube section\n");
if (yt_main < 0) die("the youtube section route is missing\n");
if (!(yt_excl < yt_main && yt_net < yt_main)) die("the youtube exclusions come after its route and never match\n");
' "$WORK_DIR/out.json" || fail "excluded_protocol is not scoped to its section"

printf 'PASS: section_excluded_protocol_scope\n'
