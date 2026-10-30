#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RULESETS_UC="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/rulesets.uc"

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

ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); if (rulesets.kind_from_reference_hint("geoip") != "subnets") exit(1);'
ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); if (type(rulesets.COMMUNITY_SERVICES) != "object" || !rulesets.COMMUNITY_SERVICES.discord) exit(1);'
ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); if (!rulesets.COMMUNITY_SERVICES.twitch) exit(1);'
assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/sing-box/twitch.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); print(rulesets.community_url("twitch"));')" \
  "twitch community ruleset url"
assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/tachyon/twitch.trs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); print(rulesets.community_trs_url("twitch"));')" \
  "twitch community trs ruleset url"
assert_eq "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs" \
  "$(ucode -L "$TACHYON_LIB" -e 'let rulesets = require("tachyon_core.rulesets"); print(rulesets.fallback_community_url("twitch"));')" \
  "twitch fallback community ruleset url"

assert_eq mixed \
  "$(ucode -L "$TACHYON_LIB" "$RULESETS_UC" community-kind telegram)" \
  "telegram community kind"
# Discord is infrastructure, like cloudflare: its voice endpoints sit on
# Cloudflare anycast, so it is routed purely by destination IP. Issuing a
# FakeIP for a Discord IP makes sing-box dial TCP for UDP QUIC voice sessions
# and time out, which surfaced as "no route" on voice channels.
assert_eq subnets \
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

# Verify supports_trs() and is_referenceable_trs_file() return false on sing-box variants
# (even when /usr/bin/tachyon-core exists as a symlink or binary) and true on tachyon-core.
TRS_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TRS_TEST_DIR"' EXIT
printf 'TSRS\x01\x00\x00\x00\x01\x00\x00\x00faceit.com' > "$TRS_TEST_DIR/sample.trs"

printf 'extended\n' > "$TRS_TEST_DIR/variant"
printf '1.14.1-extended-2.7.2\n' > "$TRS_TEST_DIR/version"
TRS_SAMPLE="$TRS_TEST_DIR/sample.trs" SB_VARIANT_STATE_FILE="$TRS_TEST_DIR/variant" SB_VERSION_STATE_FILE="$TRS_TEST_DIR/version" \
  ucode -L "$TACHYON_LIB" -e '
    let rulesets = require("tachyon_core.rulesets");
    if (rulesets.supports_trs()) exit(1);
    if (rulesets.is_referenceable_trs_file(getenv("TRS_SAMPLE"))) exit(1);
  ' || fail "sing-box-extended must not support or reference .trs files"

printf 'tachyon-core\n' > "$TRS_TEST_DIR/variant"
printf '0.2.0\n' > "$TRS_TEST_DIR/version"
TRS_SAMPLE="$TRS_TEST_DIR/sample.trs" SB_VARIANT_STATE_FILE="$TRS_TEST_DIR/variant" SB_VERSION_STATE_FILE="$TRS_TEST_DIR/version" \
  ucode -L "$TACHYON_LIB" -e '
    let rulesets = require("tachyon_core.rulesets");
    if (!rulesets.supports_trs()) exit(1);
    if (!rulesets.is_referenceable_trs_file(getenv("TRS_SAMPLE"))) exit(1);
  ' || fail "tachyon-core must support and reference valid .trs files"

printf 'singbox rulesets checks passed\n'

