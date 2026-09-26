#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULESETS_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/rulesets.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_eq srs \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" file-extension 'https://example.com/path/rule.srs?token=1#x')" \
  "ruleset file extension"
ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-community youtube >/dev/null ||
  fail "youtube should be a community ruleset"
if ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-community unknown_service >/dev/null 2>&1; then
  fail "unknown service should not be a community ruleset"
fi
assert_eq domains \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" kind-from-reference-hint 'https://example.com/geosite-custom.srs')" \
  "domain ruleset hint"
assert_eq subnets \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" kind-from-reference-hint '/tmp/geoip-cidr.json')" \
  "subnet ruleset hint"
assert_eq unknown \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" kind-from-reference-hint '/tmp/custom.srs')" \
  "unknown ruleset hint"
assert_eq source \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.json')" \
  "json remote ruleset format"
assert_eq binary \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.srs')" \
  "srs remote ruleset format"
assert_eq binary \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" remote-format 'https://example.com/rules.unknown')" \
  "unknown remote ruleset format"

ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-plain-list-reference 'https://example.com/list.lst?token=1' ||
  fail "plain .lst URL should be recognized as a plain list"
if ucode -L "$TACHYON_LIB" "$RULESETS_UC" is-plain-list-reference 'https://example.com/rules.json'; then
  fail ".json URL should not be recognized as a plain list"
fi

ucode -L "$TACHYON_LIB" -e 'let rulesets = require("singbox.rulesets"); if (rulesets.kind_from_reference_hint("geoip") != "subnets") exit(1);'
ucode -L "$TACHYON_LIB" -e 'let rulesets = require("singbox.rulesets"); if (type(rulesets.COMMUNITY_SERVICES) != "object" || !rulesets.COMMUNITY_SERVICES.discord) exit(1);'
ucode -L "$TACHYON_LIB" -e 'let rulesets = require("singbox.rulesets"); if (!rulesets.COMMUNITY_SERVICES.twitch) exit(1);'
assert_eq "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let rulesets = require("singbox.rulesets"); print(rulesets.community_url("twitch"));')" \
  "twitch community ruleset url"

assert_eq mixed \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind telegram)" \
  "telegram community kind"
assert_eq mixed \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind discord)" \
  "discord community kind"
assert_eq domains \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind youtube)" \
  "youtube community kind"
assert_eq domains \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind russia_inside)" \
  "russia_inside community kind"
assert_eq domains \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind geosite_ru)" \
  "geosite_ru community kind"
assert_eq subnets \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind geoip_ru)" \
  "geoip_ru community kind"
assert_eq subnets \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind cloudflare)" \
  "cloudflare community kind"
assert_eq subnets \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind cloudfront)" \
  "cloudfront community kind"
assert_eq unknown \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind unknown_service)" \
  "unknown_service community kind"

printf 'singbox rulesets checks passed\n'

