#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  if ! grep -Fq "$expected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: expected to find $expected"
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local label="$3"

  if grep -Fq "$unexpected" "$file"; then
    printf 'Output for %s:\n' "$label" >&2
    cat "$file" >&2
    fail "$label: did not expect to find $unexpected"
  fi
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_testing_url": "https://www.gstatic.com/generate_204",
      "urltest_filter_mode": "disabled",
      "detect_server_country": "flag_emoji",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
      ]
    }
  ]
}
JSON

output="$WORK_DIR/config.json"
mkdir -p "$output.section-cache"
ucode -L "$PODKOP_LIB" "$PODKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1"

urltest_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "urltest" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
[ "$urltest_count" = "1" ] ||
  fail "expected exactly one URLTest outbound with interrupt_exist_connections=true, got $urltest_count"

selector_count="$(ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let count = 0;
for (let outbound in cfg.outbounds || [])
    if (outbound && outbound.type == "selector" && outbound.interrupt_exist_connections === true)
        count++;
print(count, "\n");
' "$output")"
[ "$selector_count" = "1" ] ||
  fail "expected exactly one selector outbound with interrupt_exist_connections=true, got $selector_count"

assert_contains "$output" '"tag": "proxy-urltest-out"' "generated config"
assert_contains "$output" '"url": "https://www.gstatic.com/generate_204"' "generated config"
assert_contains "$output" '"interval": "3m"' "generated config"
assert_not_contains "$output" '"idle_timeout":' "generated config"

printf 'URLTest interrupt regression checks passed\n'
