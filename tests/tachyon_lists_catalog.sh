#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RULESETS_UC="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/rulesets.uc"
CONSTANTS_TS="$ROOT_DIR/fe-app-tachyon/src/constants.ts"
SECTION_TS="$ROOT_DIR/fe-app-tachyon/src/views/section.ts"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# 1. Verify every key in DOMAIN_LIST_OPTIONS (constants.ts) is recognized by
#    tachyon_core/rulesets.uc (is_community == true, community_kind != "unknown")
#    and has a non-empty content-based description in DOMAIN_LIST_HINTS (section.ts).
keys="$(node -e '
  const fs = require("fs");
  const constText = fs.readFileSync(process.argv[1], "utf8");
  const secText = fs.readFileSync(process.argv[2], "utf8");
  const mOpt = constText.match(/export const DOMAIN_LIST_OPTIONS = \{([\s\S]*?)\n\};/);
  if (!mOpt) { console.error("Missing DOMAIN_LIST_OPTIONS"); process.exit(1); }
  const mHint = secText.match(/var DOMAIN_LIST_HINTS = \{([\s\S]*?)\n\};/);
  if (!mHint) { console.error("Missing DOMAIN_LIST_HINTS"); process.exit(1); }

  const optKeys = [...mOpt[1].matchAll(/^\s*([a-z0-9_]+):/gm)].map(m => m[1]);
  const hintKeys = new Set([...mHint[1].matchAll(/^\s*([a-z0-9_]+):/gm)].map(m => m[1]));

  if (optKeys.length < 50) {
    console.error("Expected at least 50 Tachyon Lists categories, got " + optKeys.length);
    process.exit(1);
  }
  for (const k of optKeys) {
    if (!hintKeys.has(k)) {
      console.error("Missing DOMAIN_LIST_HINTS description for key: " + k);
      process.exit(1);
    }
  }
  console.log(optKeys.join(" "));
' "$CONSTANTS_TS" "$SECTION_TS")"

for key in $keys; do
  ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-community "$key" >/dev/null ||
    fail "Frontend preset '$key' is not registered in tachyon_core/rulesets.uc COMMUNITY_SERVICES"
  kind="$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind "$key")"
  [ "$kind" = "domains" ] || [ "$kind" = "mixed" ] || [ "$kind" = "subnets" ] ||
    fail "Frontend preset '$key' has invalid community_kind '$kind'"
done

# 2. Verify tachyon_lists_srs_url, community_url, and fallback_community_url for unified categories
assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/sing-box/ru_whitelist.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let r = require("tachyon_core.rulesets"); print(r.community_url("ru_whitelist"));')" \
  "community_url primary for ru_whitelist"

assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/sing-box/ru_whitelist.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let r = require("tachyon_core.rulesets"); print(r.community_url("roscomvpn_whitelist"));')" \
  "community_url alias normalization for roscomvpn_whitelist"

assert_eq "https://example.org/custom-lists/ai_all.srs" \
  "$(TACHYON_LISTS_SRS_URL="https://example.org/custom-lists/" ucode -L "$TACHYON_LIB" -e 'let r = require("tachyon_core.rulesets"); print(r.tachyon_lists_srs_url("ai_all"));')" \
  "tachyon_lists_srs_url override via TACHYON_LISTS_SRS_URL"

assert_eq "https://raw.githubusercontent.com/hydraponique/roscomvpn-geosite/master/release/sing-box/whitelist.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let r = require("tachyon_core.rulesets"); print(r.fallback_community_url("ru_whitelist"));')" \
  "ru_whitelist fallback_community_url"

assert_eq "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let r = require("tachyon_core.rulesets"); print(r.fallback_community_url("ru_blocked"));')" \
  "ru_blocked fallback_community_url"

printf 'tachyon_lists_catalog checks passed\n'
