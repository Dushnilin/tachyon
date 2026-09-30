#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# TCH-1036 / TCH-1021: on the steer engine the section cache is rebuilt by
# steer/section_cache.uc, which used to skip the dashboard unhide that
# singbox/generator_routes.uc applies in add_proxy_selector(). Nodes picked via
# "Only selected" stayed flagged hidden in the cache and the LuCI dashboard
# filtered them out (empty dashboard / only the unselected nodes left).

mkdir -p "$WORK_DIR/subscriptions"
cat >"$WORK_DIR/subscriptions/proxy-subscription-1.json" <<'JSON'
{
  "outbounds": [
    { "type": "urltest", "tag": "PomidorVPN - Group", "remark": "PomidorVPN - Group", "outbounds": [ "us1", "us2", "de1" ], "__tachyon_allow_group": true },
    { "type": "vless", "tag": "us1", "remark": "🇺🇸США", "server": "1.1.1.1", "server_port": 443, "uuid": "00000000-0000-4000-8000-000000000001" },
    { "type": "vless", "tag": "us2", "remark": "🇺🇸США 2", "server": "1.1.1.2", "server_port": 443, "uuid": "00000000-0000-4000-8000-000000000002" },
    { "type": "vless", "tag": "de1", "remark": "🇩🇪Германия", "server": "1.1.1.3", "server_port": 443, "uuid": "00000000-0000-4000-8000-000000000003" }
  ]
}
JSON
printf '%s\n' 'https://pomidor.example/sub' >"$WORK_DIR/subscriptions/proxy-subscription-1.url"
: >"$WORK_DIR/subscriptions/proxy-subscription-1.user_agent"

CACHE_DIR="$WORK_DIR/section-cache"
mkdir -p "$CACHE_DIR"

out="$(TACHYON_CONFIG_NAME="tachyon" TACHYON_SECTION_CACHE_DIR="$CACHE_DIR" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let sc = require("steer.section_cache");
let built = sc.build_section_cache({
    ".name": "proxy",
    "subscription_urls": [ "https://pomidor.example/sub" ],
    "dashboard_filter_mode": "include",
    "dashboard_include_outbounds": [ "🇺🇸США", "🇺🇸США 2" ]
});
let cache = json(fs.readfile(getenv("TACHYON_SECTION_CACHE_DIR") + "/proxy.json"));
print("built=" + (built == true) + "\n");
print("us1_hidden=" + (cache.hiddenOutboundTags["us1"] == true) + "\n");
print("us2_hidden=" + (cache.hiddenOutboundTags["us2"] == true) + "\n");
print("de1_hidden=" + (cache.hiddenOutboundTags["de1"] == true) + "\n");
' 2>&1)" || fail "steer section cache build failed: $out"

printf '%s\n' "$out" | grep -Fq 'built=true' || fail "section cache was not built: $out"
printf '%s\n' "$out" | grep -Fq 'us1_hidden=false' || fail "selected node us1 must be unhidden in the steer cache: $out"
printf '%s\n' "$out" | grep -Fq 'us2_hidden=false' || fail "selected node us2 must be unhidden in the steer cache: $out"
printf '%s\n' "$out" | grep -Fq 'de1_hidden=true' || fail "unselected node de1 must stay hidden in the steer cache: $out"

printf 'steer section cache dashboard unhide checks passed\n'
