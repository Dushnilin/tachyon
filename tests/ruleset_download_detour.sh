#!/usr/bin/env bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Which download transport a rule-set ends up with depends on the installed
# core: sing-box 1.14.0 deprecated `download_detour` for `http_client`. These
# checks are about WHICH outbound the download rides on, so they accept either
# field; the version matrix itself is covered by
# tests/singbox_ruleset_download_transport.sh.
assert_downloads_via() {
  local output="$1" outbound="$2" label="$3"
  grep -Fq "\"download_detour\": \"$outbound\"" "$output" && return 0
  grep -Fq "\"tag\": \"tachyon-download-$outbound\"," "$output" &&
    grep -Fq "\"detour\": \"$outbound\"" "$output" && return 0
  fail "$label"
}

refuses_download_via() {
  local output="$1" outbound="$2" label="$3"
  if grep -Fq "\"download_detour\": \"$outbound\"" "$output"; then
    fail "$label (download_detour)"
  fi
  if grep -Fq "\"detour\": \"$outbound\"" "$output"; then
    fail "$label (http_clients)"
  fi
}

# 1. Verify remote rule_set downloads through section's proxy outbound
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "myproxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

assert_downloads_via "$output" "myproxy-out" \
  "remote community ruleset must automatically download via the section outbound"

# 2. Verify download_via_proxy fallback selects first enabled proxy section
cat >"$WORK_DIR/fixture-detour-enabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "download_lists_via_proxy": "1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "first_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ]
    },
    {
      ".name": "other_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output2="$WORK_DIR/out2.json"
mkdir -p "$output2.section-cache" "$output2.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-detour-enabled.json" "$output2" "127.0.0.1" "0" "1"

assert_downloads_via "$output2" "first_proxy-out" \
  "global download_lists_via_proxy without explicit section must default to first enabled proxy section"

# 3. Verify http_clients and default_http_client handling:
# Omitted on sing-box < 1.14 (1.12, 1.13, Leadaxe, Extended) to avoid unknown field crash
output_v13="$WORK_DIR/out_v13.json"
mkdir -p "$output_v13.section-cache" "$output_v13.rulesets"
printf 'v1.13.5\n' > "$WORK_DIR/sb_v13"
SB_VERSION_STATE_FILE="$WORK_DIR/sb_v13" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output_v13" "127.0.0.1" "0" "1"

if grep -q '"http_clients"' "$output_v13"; then
  fail "sing-box < 1.14 must not have http_clients (causes fatal unknown field crash)"
fi
if grep -q '"default_http_client"' "$output_v13"; then
  fail "sing-box < 1.14 must not have default_http_client (causes fatal unknown field crash)"
fi

# Included on sing-box 1.14+
output_v14="$WORK_DIR/out_v14.json"
mkdir -p "$output_v14.section-cache" "$output_v14.rulesets"
printf 'v1.14.0\n' > "$WORK_DIR/sb_v14"
SB_VERSION_STATE_FILE="$WORK_DIR/sb_v14" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output_v14" "127.0.0.1" "0" "1"

grep -q '"http_clients"' "$output_v14" || \
  fail "sing-box 1.14+ must include http_clients"
grep -q '"default_http_client": "ruleset-http"' "$output_v14" || \
  fail "sing-box 1.14+ must configure default_http_client"
if grep -q '"dial_detour"' "$output_v14"; then
  fail "sing-box 1.14+ must NEVER contain 'dial_detour' in http_clients (causes fatal unknown field crash)"
fi
if command -v sing-box >/dev/null 2>&1; then
  INSTALLED_SB_VER="$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo '0.0')"
  if [ "$(printf '%s\n1.14\n' "$INSTALLED_SB_VER" | sort -V | head -n1)" = "1.14" ]; then
    sing-box check -c "$output_v14" || fail "sing-box 1.14+ config check failed"
  fi
fi

output_detour_v14="$WORK_DIR/out_detour_v14.json"
mkdir -p "$output_detour_v14.section-cache" "$output_detour_v14.rulesets"
SB_VERSION_STATE_FILE="$WORK_DIR/sb_v14" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-detour-enabled.json" "$output_detour_v14" "127.0.0.1" "0" "1"

if grep -q '"dial_detour"' "$output_detour_v14"; then
  fail "sing-box 1.14+ must NEVER contain 'dial_detour' with proxy enabled"
fi
grep -q '"detour": "first_proxy-out"' "$output_detour_v14" || \
  fail "sing-box 1.14+ http_clients must configure 'detour' field when download_lists_via_proxy is enabled"
if command -v sing-box >/dev/null 2>&1; then
  INSTALLED_SB_VER="$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo '0.0')"
  if [ "$(printf '%s\n1.14\n' "$INSTALLED_SB_VER" | sort -V | head -n1)" = "1.14" ]; then
    sing-box check -c "$output_detour_v14" || fail "sing-box 1.14+ detour config check failed"
  fi
fi

# 4. Verify zapret section with community_lists does NOT use zapret-out as download_detour
cat >"$WORK_DIR/fixture_zapret.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "zapret_sec",
      ".type": "section",
      "enabled": "1",
      "action": "zapret",
      "community_lists": [ "youtube" ]
    }
  ]
}
JSON

output_zapret="$WORK_DIR/out_zapret.json"
mkdir -p "$output_zapret.section-cache" "$output_zapret.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_zapret.json" "$output_zapret" "127.0.0.1" "0" "1"

refuses_download_via "$output_zapret" "zapret_sec-out" \
  "zapret-out must never be selected as download transport due to routing_mark"

# 5. Verify mieru outbound is rejected as download_detour and http_clients detour
cat >"$WORK_DIR/fixture_mieru.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "mieru_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"mieru\",\"server\":\"1.2.3.4\",\"server_port\":443}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output_mieru="$WORK_DIR/out_mieru.json"
mkdir -p "$output_mieru.section-cache" "$output_mieru.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_mieru.json" "$output_mieru" "127.0.0.1" "0" "1"

refuses_download_via "$output_mieru" "mieru_sec-out" \
  "mieru outbound must never be assigned as rule_set download transport (early startup crash)"

output_mieru_v14="$WORK_DIR/out_mieru_v14.json"
mkdir -p "$output_mieru_v14.section-cache" "$output_mieru_v14.rulesets"
SB_VERSION_STATE_FILE="$WORK_DIR/sb_v14" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_mieru.json" "$output_mieru_v14" "127.0.0.1" "0" "1"

if grep -q '"detour": "mieru_sec-out"' "$output_mieru_v14"; then
  fail "mieru outbound must never be assigned as http_clients detour"
fi

printf "ruleset download detour checks passed\n"

