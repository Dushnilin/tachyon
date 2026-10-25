#!/usr/bin/env bash
# Tests for GitHub Issue #239:
# Expose interrupt_exist_connections, check_interval, tolerance, testing_url for action 'group' (URLTest).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'BASH'
#!/usr/bin/env bash
exit 0
BASH
chmod +x "$WORK_DIR/bin/logger"

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"

# 1. Check UI declarations in section.js
grep -Fq '"interrupt_exist_connections"' "$SECTION_JS" ||
  fail "section.js must declare interrupt_exist_connections"
grep -Fq '"check_interval"' "$SECTION_JS" ||
  fail "section.js must declare check_interval"
grep -Fq '"tolerance"' "$SECTION_JS" ||
  fail "section.js must declare tolerance"
grep -Fq '"testing_url"' "$SECTION_JS" ||
  fail "section.js must declare testing_url"

LINK_A="vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#nodeA"
LINK_B="vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#nodeB"

# 2. Config generation with custom URLTest options (interrupt_exist_connections=0)
cat >"$WORK_DIR/custom-group-fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "sec_a",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "$LINK_A" ]
    },
    {
      ".name": "sec_b",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "$LINK_B" ]
    },
    {
      ".name": "my_group",
      ".type": "section",
      "enabled": "1",
      "action": "group",
      "group_members": [ "sec_a", "sec_b" ],
      "interrupt_exist_connections": "0",
      "check_interval": "1m",
      "tolerance": "75",
      "testing_url": "https://custom.example.org/generate_204",
      "idle_timeout": "15m"
    }
  ]
}
JSON

output="$WORK_DIR/custom-group-config.json"
mkdir -p "${output}.section-cache"

TACHYON_LIB="$TACHYON_LIB" PATH="$WORK_DIR/bin:$PATH" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/custom-group-fixture.json" "$output" "127.0.0.1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

let group_urltest = null;
let group_selector = null;

for (let outbound in cfg.outbounds || []) {
    if (outbound.tag == "my_group-urltest-out")
        group_urltest = outbound;
    if (outbound.tag == "my_group-out")
        group_selector = outbound;
}

if (!group_urltest)
    die("my_group-urltest-out missing\n");
if (group_urltest.type != "urltest")
    die("my_group-urltest-out must have type urltest\n");
if (group_urltest.interrupt_exist_connections !== false)
    die("my_group-urltest-out must have interrupt_exist_connections === false, got " + group_urltest.interrupt_exist_connections + "\n");
if (group_urltest.interval != "1m")
    die("my_group-urltest-out interval must be 1m, got " + group_urltest.interval + "\n");
if (group_urltest.tolerance !== 75)
    die("my_group-urltest-out tolerance must be 75, got " + group_urltest.tolerance + "\n");
if (group_urltest.url != "https://custom.example.org/generate_204")
    die("my_group-urltest-out url mismatch: " + group_urltest.url + "\n");
if (group_urltest.idle_timeout != "15m")
    die("my_group-urltest-out idle_timeout must be 15m, got " + group_urltest.idle_timeout + "\n");

if (!group_selector)
    die("my_group-out selector missing\n");
if (group_selector.type != "selector")
    die("my_group-out must have type selector\n");
if (group_selector.interrupt_exist_connections !== false)
    die("my_group-out selector must inherit interrupt_exist_connections === false\n");

print("PASS: custom group urltest options applied\n");
' "$output"

# 3. Default group options (without explicit overrides)
cat >"$WORK_DIR/default-group-fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "sec_a",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "$LINK_A" ]
    },
    {
      ".name": "def_group",
      ".type": "section",
      "enabled": "1",
      "action": "group",
      "group_members": [ "sec_a" ]
    }
  ]
}
JSON

def_output="$WORK_DIR/default-group-config.json"
mkdir -p "${def_output}.section-cache"

TACHYON_LIB="$TACHYON_LIB" PATH="$WORK_DIR/bin:$PATH" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/default-group-fixture.json" "$def_output" "127.0.0.1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

let group_urltest = null;
let group_selector = null;

for (let outbound in cfg.outbounds || []) {
    if (outbound.tag == "def_group-urltest-out")
        group_urltest = outbound;
    if (outbound.tag == "def_group-out")
        group_selector = outbound;
}

if (!group_urltest)
    die("def_group-urltest-out missing\n");
if (group_urltest.interrupt_exist_connections !== true)
    die("def_group-urltest-out must default to interrupt_exist_connections === true\n");
if (group_urltest.interval != "3m")
    die("def_group-urltest-out interval must default to 3m\n");
if (group_urltest.tolerance !== 50)
    die("def_group-urltest-out tolerance must default to 50\n");

if (!group_selector)
    die("def_group-out missing\n");
if (group_selector.interrupt_exist_connections !== true)
    die("def_group-out selector must default to interrupt_exist_connections === true\n");

print("PASS: default group urltest options verified\n");
' "$def_output"

echo "section_group_urltest_options.sh: ALL PASS"
