#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions"
mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const dir = process.argv[2];
const section = {'.name':'proxy', '.type':'section', enabled:'1', action:'proxy',
  domain_suffix:['example.org'], subscription_urls:['https://example.test/one','https://example.test/two'],
  subscription_filter_include_keywords:['Berlin']};
fs.writeFileSync(dir+'/fixture.json',JSON.stringify({settings:{dns_server:'1.1.1.1',service_listen_address:'127.0.0.1'},section:[section]}));
for (let i=1;i<=2;i++) {
  fs.writeFileSync(dir+'/raw'+i+'.json',JSON.stringify([{type:'socks',tag:i===1?'Tokyo':'Berlin',server:'198.51.100.'+i,server_port:1080}]));
}
JS
for i in 1 2; do
  cache="$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-$i"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/parser.uc" normalize-content-validated "$WORK_DIR/raw$i.json" "$cache.json"
  [ "$i" -eq 1 ] && source_url=one || source_url=two
  printf 'https://example.test/%s' "$source_url" >"$cache.url"
  printf Happ >"$cache.user_agent"
done
generate() {
  mkdir -p "$WORK_DIR/$1.json.section-cache"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/$1.json" '127.0.0.1' '0' >"$WORK_DIR/$1.log" 2>&1
}
generate mixed
node - "$WORK_DIR/mixed.json" <<'JS'
const fs=require('fs'), assert=require('assert').strict;
const cfg=JSON.parse(fs.readFileSync(process.argv[2]));
assert((cfg.outbounds||[]).some(o=>o.server==='198.51.100.2'),'matching second source was discarded');
assert(!(cfg.outbounds||[]).some(o=>o.server==='198.51.100.1'),'nonmatching first source was imported');
JS

# Every source filtered: retain the existing section-level error/fail policy.
cp "$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-1.json" "$TMP_SUBSCRIPTION_FOLDER/proxy-subscription-2.json"
generate empty || true
grep -q 'connection section has no usable outbounds' "$WORK_DIR/empty.log" || fail 'all-filtered section did not reach the section-level check'

# Manual nodes remain usable even when every subscription is filtered out.
node - "$WORK_DIR/fixture.json" <<'JS'
const fs=require('fs'), path=process.argv[2], cfg=JSON.parse(fs.readFileSync(path));
cfg.section[0].selector_proxy_links=['socks5://127.0.0.1:1090#manual'];
fs.writeFileSync(path,JSON.stringify(cfg));
JS
generate manual
node - "$WORK_DIR/manual.json" <<'JS'
const fs=require('fs'), assert=require('assert').strict;
const cfg=JSON.parse(fs.readFileSync(process.argv[2]));
assert((cfg.outbounds||[]).some(o=>o.server==='127.0.0.1'&&o.server_port===1090),'filtered subscription discarded the manual node');
JS
printf 'subscription keyword source isolation passed\n'
