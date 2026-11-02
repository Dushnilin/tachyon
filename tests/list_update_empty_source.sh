#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export TMP_RULESET_FOLDER="$WORK_DIR/runtime"
export TACHYON_PERSISTENT_RULESET_DIR="$WORK_DIR/persistent"
mkdir -p "$TMP_RULESET_FOLDER" "$TACHYON_PERSISTENT_RULESET_DIR" "$WORK_DIR/bin"
export HTTP_LIST="$WORK_DIR/http-list"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
[ ! -e "$HTTP_LIST.fail" ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$HTTP_LIST" "$2"; exit 0; fi
  shift
done
exit 2
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH"
fixture() {
  printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","domain_ip_lists":["%s"]}]}' "$1" >"$WORK_DIR/config.json"
}
rebuild() {
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" \
    rebuild-domain-ip-lists-fixture "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
}
live="$TMP_RULESET_FOLDER/direct-lists-ruleset.json"
persist="$TACHYON_PERSISTENT_RULESET_DIR/direct-lists-ruleset.json"
printf '198.18.0.0/15\n' >"$WORK_DIR/local-list"
fixture "$WORK_DIR/local-list"
rebuild
grep -q '198.18.0.0' "$live" || fail 'initial local list not imported'
hash=$(HASH_INPUT="$WORK_DIR/local-list" ucode -L "$TACHYON_LIB" -e 'print(require("tachyon_core.rulesets").hash12(getenv("HASH_INPUT")));')
inline="inline-custom-$hash-ruleset"
cp "$live" "$TMP_RULESET_FOLDER/$inline.json"
cp "$live" "$TACHYON_PERSISTENT_RULESET_DIR/$inline.json"
: >"$WORK_DIR/local-list"
rebuild
if grep -q '198.18.0.0' "$live" "$persist"; then fail 'empty local list restored old cache'; fi
if [ -e "$TMP_RULESET_FOLDER/$inline.json" ] || [ -e "$TACHYON_PERSISTENT_RULESET_DIR/$inline.json" ]; then
  fail 'domain/IP source left a stale per-reference cache for reload'
fi

fixture https://example.test/direct.lst
printf '198.18.0.0/15\n' >"$HTTP_LIST"
rebuild
grep -q '198.18.0.0' "$live" || fail 'initial HTTP list not imported'
: >"$HTTP_LIST"
rebuild
if grep -q '198.18.0.0' "$live" "$persist"; then fail 'successful zero-byte HTTP list restored old cache'; fi

# HTTP failure must remain distinguishable from a successfully empty body.
printf '198.18.0.0/15\n' >"$HTTP_LIST"
rebuild
touch "$HTTP_LIST.fail"
if rebuild; then fail 'failed HTTP download reported success'; fi
grep -q '198.18.0.0' "$live" || fail 'failed download discarded last good cache'
grep -q '198.18.0.0' "$persist" || fail 'failed download damaged persistent cache'

# Removing the reference must not leave an unreferenced cache for startup.
printf '{"section":[{".name":"direct","enabled":"1","action":"bypass"}]}' >"$WORK_DIR/config.json"
rebuild
if [ -e "$live" ] || [ -e "$persist" ]; then fail 'removed source left an old cache'; fi
for field in rule_set rule_set_with_subnets; do
  printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","%s":["%s/missing.lst"]}]}' \
    "$field" "$WORK_DIR" >"$WORK_DIR/config.json"
  if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" import-list-subnets-fixture \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"; then
    fail "missing local source accepted in $field"
  fi
done

# Successful empty plain rule sets must replace binary and JSON caches too.
rm -f "$HTTP_LIST.fail"
for field in rule_set rule_set_with_subnets; do
  printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","%s":["https://example.test/cache.lst"]}]}' \
    "$field" >"$WORK_DIR/config.json"
  mode=refresh-plain-rulesets-fixture
  [ "$field" != rule_set_with_subnets ] || mode=import-list-subnets-fixture
  printf '198.51.100.0/24\n' >"$HTTP_LIST"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" "$mode" \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
  jsonfile=$(find "$TMP_RULESET_FOLDER" -name 'inline-custom-*.json' -print | head -n 1)
  [ -n "$jsonfile" ] || fail 'plain rule set JSON missing'
  name=$(basename "$jsonfile" .json)
  printf 'SRS\001previous-binary-cache\n' >"$TMP_RULESET_FOLDER/$name.srs"
  cp "$TMP_RULESET_FOLDER/$name.srs" "$TACHYON_PERSISTENT_RULESET_DIR/$name.srs"
  : >"$HTTP_LIST"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" "$mode" \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
  if [ -e "$TMP_RULESET_FOLDER/$name.srs" ] || [ -e "$TACHYON_PERSISTENT_RULESET_DIR/$name.srs" ]; then
    fail 'empty plain rule set retained older binary'
  fi
  if grep -q '198.51.100.0' "$jsonfile" "$TACHYON_PERSISTENT_RULESET_DIR/$name.json"; then
    fail 'empty plain rule set retained older JSON'
  fi
done

printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","rule_set":["%s/supported.trs"]}]}' \
  "$WORK_DIR" >"$WORK_DIR/config.json"
printf 'core-owned TRS\n' >"$WORK_DIR/supported.trs"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" import-list-subnets-fixture \
  "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"

# Ordinary JSON/SRS rules belong to core; their source/domain constraints must
# never be stripped into an unconditional nft destination set.
printf '{"version":3,"rules":[{"ip_cidr":["198.51.100.0/24"],"source_ip_cidr":["192.0.2.1/32"]}]}' >"$WORK_DIR/restricted.json"
printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","rule_set":["%s/restricted.json"]}]}' \
  "$WORK_DIR" >"$WORK_DIR/config.json"
: >"$WORK_DIR/transaction"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" import-list-subnets-fixture \
  "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
[ ! -s "$WORK_DIR/transaction" ] || fail 'ordinary JSON conditions were discarded into nft'

# A remote subnet cache is a fresh union, not an accumulating list. Otherwise
# a subsequent firewall reload would reintroduce removed entries.
printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","remote_subnet_lists":["https://example.test/subnets.lst"]}]}' >"$WORK_DIR/config.json"
refresh_remote() {
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" refresh-remote-subnets-fixture \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
}
printf '198.18.0.0/15\n' >"$HTTP_LIST"
refresh_remote
remote="$TMP_RULESET_FOLDER/direct-remote-subnets-ruleset.json"
remote_persist="$TACHYON_PERSISTENT_RULESET_DIR/direct-remote-subnets-ruleset.json"
grep -q '198.18.0.0' "$remote" || fail 'initial remote subnet cache missing'
printf '198.51.100.0/24\n' >"$HTTP_LIST"
refresh_remote
if grep -q '198.18.0.0' "$remote" "$remote_persist"; then fail 'remote cache retained removed subnet'; fi
: >"$HTTP_LIST"
refresh_remote
if grep -q '198.51.100.0' "$remote" "$remote_persist"; then fail 'empty remote cache restored old subnet'; fi

# Local plain sources have the same cache fallback at the next firewall reload.
for field in rule_set rule_set_with_subnets; do
  printf '198.18.0.0/15\n' >"$WORK_DIR/local-cache.lst"
  printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","%s":["%s/local-cache.lst"]}]}' \
    "$field" "$WORK_DIR" >"$WORK_DIR/config.json"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" import-list-subnets-fixture \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
  : >"$WORK_DIR/local-cache.lst"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" import-list-subnets-fixture \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"
  if grep -q '198.18.0.0' "$TMP_RULESET_FOLDER"/inline-custom-*.json "$TACHYON_PERSISTENT_RULESET_DIR"/inline-custom-*.json; then
    fail 'empty local plain source retained an older cache for reload'
  fi
done

# A nonempty error page is not an authoritative empty plain list.
fixture https://example.test/direct.lst
printf '198.18.0.0/15\n' >"$HTTP_LIST"
rebuild
printf '<html>upstream unavailable</html>\n' >"$HTTP_LIST"
if rebuild; then fail 'malformed plain source was accepted as empty'; fi
grep -q '198.18.0.0' "$live" || fail 'malformed plain source discarded last good cache'
grep -q '198.18.0.0' "$persist" || fail 'malformed plain source damaged persistent cache'
printf '# empty by choice\n// comment\n; comment\n' >"$HTTP_LIST"
rebuild
if grep -q '198.18.0.0' "$live" "$persist"; then fail 'comment-only source was not accepted as empty'; fi

for field in rule_set rule_set_with_subnets; do
  printf '{"section":[{".name":"direct","enabled":"1","action":"bypass","%s":["https://example.test/cache.lst"]}]}' \
    "$field" >"$WORK_DIR/config.json"
  mode=refresh-plain-rulesets-fixture
  [ "$field" != rule_set_with_subnets ] || mode=import-list-subnets-fixture
  printf '<html>upstream unavailable</html>\n' >"$HTTP_LIST"
  if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" "$mode" \
    "$WORK_DIR/config.json" direct "$WORK_DIR/transaction"; then
    fail 'malformed plain rule set was accepted as empty'
  fi
done
printf 'list update empty source tests passed\n'
