#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$TACHYON_LIB/subscription/cache.uc"

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
req_url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -V) exit 1 ;;
    -o) target="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -A|--user-agent|-x|-H|--connect-timeout|--max-time|--speed-time|--speed-limit|--max-redirs|-b|--max-filesize|--write-out|--doh-url|--dns-servers)
      shift 2 ;;
    http://*|https://*)
      req_url="$1"; shift ;;
    -*)
      shift ;;
    *)
      if [ -z "$req_url" ]; then
        req_url="$1"
      fi
      shift ;;
  esac
done
[ -n "$target" ] || exit 99
[ -z "${CURL_LOG:-}" ] || printf '%s\n' "$req_url" >>"$CURL_LOG"

suffix="${SUB_NODE_SUFFIX:-v1}"
case "$req_url" in
  *sub.example/one*)
    printf 'vless://00000000-0000-4000-8000-000000000001@one.example:443?security=tls&type=tcp#Alpha-%s\n' "$suffix" >"$target"
    sub_title="Sub One"
    ;;
  *sub.example/two*)
    printf 'vless://00000000-0000-4000-8000-000000000002@two.example:443?security=tls&type=tcp#Beta-%s\n' "$suffix" >"$target"
    sub_title="Sub Two"
    ;;
  *)
    exit 22
    ;;
esac

[ -z "$headers" ] || printf 'HTTP/1.1 200 OK\r\nProfile-Title: %s\r\n\r\n' "$sub_title" >"$headers"
printf '200'
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

export TACHYON_UCI_STATE_FILE="$WORK_DIR/sub-uci.state"
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
export CURL_LOG="$WORK_DIR/curl-requests.log"

printf '0.5.9\n' >"$TACHYON_CORE_VERSION_FILE"

cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.dns_server=1.1.1.1
tachyon.settings.bootstrap_dns_server=77.88.8.8
tachyon.sub1=outbound_source
tachyon.sub1.enabled=1
tachyon.sub1.source_type=subscription
tachyon.sub1.url=https://sub.example/one
tachyon.sub2=outbound_source
tachyon.sub2.enabled=1
tachyon.sub2.source_type=subscription
tachyon.sub2.url=https://sub.example/two
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=connection
tachyon.Main.outbound_source_refs=sub1 sub2
STATE

# Seed both subscriptions initially.
SUB_NODE_SUFFIX="v1"
export SUB_NODE_SUFFIX
: >"$CURL_LOG"
seed_summary="$(ucode -L "$TACHYON_LIB" "$CACHE_UC" update-request 1 Main "")"
assert_eq $'1\t0\t0\t0\t0' "$seed_summary" "initial Main section update should succeed"
[ -s "$TMP_SUBSCRIPTION_FOLDER/Main-subscription-1.json" ] || fail "missing seeded source 1 cache"
[ -s "$TMP_SUBSCRIPTION_FOLDER/Main-subscription-2.json" ] || fail "missing seeded source 2 cache"

# Pin source 1 and 2 timestamps back to 1700000000 and remove section-wide Main.timestamp.
rm -f "$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main.timestamp"
printf '1700000000\n' >"$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main-subscription-1.timestamp"
printf '1700000000\n' >"$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main-subscription-2.timestamp"

node - \
  "$TACHYON_SECTION_CACHE_DIR/Main.json" \
  "$TMP_SUBSCRIPTION_FOLDER" \
  "$TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');

const [secCachePath, tmpSubDir, persDir] = process.argv.slice(2);
const oldTs = 1700000000;

const secCache = JSON.parse(fs.readFileSync(secCachePath, 'utf8'));
for (const item of secCache.subscriptionMetadata || []) {
  item.updatedAt = oldTs;
}
fs.writeFileSync(secCachePath, JSON.stringify(secCache, null, 2) + '\n');

for (const dir of [tmpSubDir, persDir]) {
  for (const name of fs.readdirSync(dir)) {
    if (!name.startsWith('Main-subscription-1')) continue;
    const p = path.join(dir, name);
    if (name.endsWith('.metadata.json')) {
      const m = JSON.parse(fs.readFileSync(p, 'utf8'));
      m.updatedAt = oldTs;
      fs.writeFileSync(p, JSON.stringify(m, null, 2) + '\n');
    }
    fs.utimesSync(p, oldTs, oldTs);
  }
}
NODE

# Update ONLY source #2 by 1-based index.
SUB_NODE_SUFFIX="v2"
: >"$CURL_LOG"
single_idx_summary="$(ucode -L "$TACHYON_LIB" "$CACHE_UC" update-request 1 Main 2)"
assert_eq $'1\t0\t0\t0\t0' "$single_idx_summary" "single-source update by index must update only 1 source"

grep -Fxq "https://sub.example/two" "$CURL_LOG" ||
  fail "expected curl to fetch https://sub.example/two"
if grep -Fxq "https://sub.example/one" "$CURL_LOG"; then
  fail "updating subscription #2 must NOT fetch subscription #1"
fi

[ ! -e "$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main.timestamp" ] ||
  fail "updating single source #2 must NOT write section-wide Main.timestamp"

ts1="$(tr -d '[:space:]' <"$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main-subscription-1.timestamp")"
ts2="$(tr -d '[:space:]' <"$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main-subscription-2.timestamp")"
assert_eq "1700000000" "$ts1" "source #1 timestamp must stay unchanged"
[ "$ts2" -gt 1700000000 ] || fail "expected source #2 timestamp > 1700000000, got '$ts2'"

node - "$TACHYON_SECTION_CACHE_DIR/Main.json" <<'NODE'
const fs = require('fs');
const cache = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const meta = cache.subscriptionMetadata || [];
const s1 = meta.find((m) => m.sourceIndex === 1);
const s2 = meta.find((m) => m.sourceIndex === 2);
if (!s1 || !s2) {
  console.error('missing metadata for sources 1 or 2', meta);
  process.exit(1);
}
if (s1.updatedAt !== 1700000000) {
  console.error(`source #1 updatedAt overwritten: expected 1700000000, got ${s1.updatedAt}`);
  process.exit(1);
}
if (!(s2.updatedAt > 1700000000)) {
  console.error(`source #2 updatedAt was not updated: ${s2.updatedAt}`);
  process.exit(1);
}
NODE

# Verify read_source_metadata / merge_source_metadata ignores stale/newer section timestamp when source #1 has own metadata/mtime.
rm -f "$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main-subscription-1.timestamp"
printf '1999999999\n' >"$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main.timestamp"

meta_json="$(ucode -L "$TACHYON_LIB" -e '
let sub = require("tachyon_core.subscription");
let state = sub.new_section_state("Main");
sub.merge_source_metadata(state, "Main", "Main-subscription-1", 1, "https://sub.example/one", "Sub One");
sub.merge_source_metadata(state, "Main", "Main-subscription-2", 2, "https://sub.example/two", "Sub Two");
print(sprintf("%J\n", state.subscriptionMetadata));
')"

JSON_VALUE="$meta_json" node - <<'NODE'
const items = JSON.parse(process.env.JSON_VALUE);
const s1 = items.find((m) => m.sourceIndex === 1);
const s2 = items.find((m) => m.sourceIndex === 2);
if (!s1 || !s2) {
  console.error('merge_source_metadata missing items', items);
  process.exit(1);
}
if (s1.updatedAt !== 1700000000) {
  console.error(`expected s1.updatedAt=1700000000 even with newer Main.timestamp, got ${s1.updatedAt}`);
  process.exit(1);
}
if (!(s2.updatedAt > 1700000000 && s2.updatedAt < 1999999999)) {
  console.error(`expected s2.updatedAt from own source timestamp (< 1999999999), got ${s2.updatedAt}`);
  process.exit(1);
}
NODE

# Update ONLY source #2 by UCI outbound_source id.
rm -f "$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main.timestamp"
: >"$CURL_LOG"
single_id_summary="$(ucode -L "$TACHYON_LIB" "$CACHE_UC" update-request 1 Main sub2)"
assert_eq $'0\t0\t1\t0\t0' "$single_id_summary" "single-source update by outbound_source id must target source #2"

grep -Fxq "https://sub.example/two" "$CURL_LOG" ||
  fail "expected curl to fetch https://sub.example/two for source id sub2"
if grep -Fxq "https://sub.example/one" "$CURL_LOG"; then
  fail "updating sub2 by id must NOT fetch subscription #1"
fi

[ ! -e "$TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR/Main.timestamp" ] ||
  fail "updating sub2 by id must NOT write section-wide Main.timestamp"

printf 'single-source subscription update fault checks passed\n'
