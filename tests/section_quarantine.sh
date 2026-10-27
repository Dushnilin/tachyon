#!/usr/bin/env bash
# Section quarantine: a config that sing-box refuses to load must not take the
# whole proxy down. The runtime isolates the offending section, regenerates
# without it and records the error per section in /var/run/tachyon/section-errors.json
# (overridable via TACHYON_SECTION_ERRORS_FILE) so the UI can mark the section.
#
# Covers the three mechanical pieces that make the loop work:
#   1. the generator drops a quarantined section from the whole config
#      (outbounds, routes, failover) and drops detours pointing at it;
#   2. the generator names the failing section in a tachyon-section-error marker
#      when generation itself dies inside a section;
#   3. the runtime maps a sing-box check failure back to the owning section
#      by tag prefix (outbounds[N], rule_set[N], missing outbound tag).
# The full init-config loop needs a live sing-box binary and UCI; its wiring is
# asserted by grep at the end of this file.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"

export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"
printf 'tachyon-core' >"$SB_VARIANT_STATE_FILE"
printf '0.0.9' >"$SB_VERSION_STATE_FILE"

# section_exists() consults UCI; the attribution fixture needs a section that
# really exists there.
UCI_STATE="$WORK_DIR/uci_state"
export TACHYON_UCI_STATE_FILE="$UCI_STATE"
printf 'tachyon.proxy_sec=section\ntachyon.listy=section\ntachyon.awg_sec=section\n' >"$UCI_STATE"

fixture() {
  cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"A\",\"server\":\"a.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}" ]
    },
    {
      ".name": "awg_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "proxy_sec",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#B" ]
    }
  ]
}
JSON
}

generate() {
  local quarantined="$1" output="$2"
  mkdir -p "${output}.section-cache"
  # args: fixture, output, address, mwan3, supports_xhttp, deferred, quarantined
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "" "" "$quarantined"
}

# -- 1. quarantined section is dropped, the rest survives ---------------------
fixture
generate "proxy_sec" "$WORK_DIR/quarantined.out"

grep -Fq '"tag": "awg_sec-1-out"' "$WORK_DIR/quarantined.out" ||
  fail "section without quarantine must survive"
if grep -Fq 'proxy_sec' "$WORK_DIR/quarantined.out"; then
  fail "quarantined section proxy_sec must not appear in the generated config"
fi
grep -Fq '"detour": "proxy_sec-out"' "$WORK_DIR/quarantined.out" &&
  fail "detour pointing at a quarantined section must be dropped, not left dangling"

# Un-quarantined run: both sections present, detour wired.
generate "" "$WORK_DIR/full.out"
grep -Fq '"tag": "proxy_sec-out"' "$WORK_DIR/full.out" ||
  fail "without quarantine both sections must be generated"
grep -Fq '"detour": "proxy_sec-out"' "$WORK_DIR/full.out" ||
  fail "detour to a live section must be kept"

# -- 2. generation failure names the section ----------------------------------
# An unsupported manual link scheme dies inside the section loop; the runtime
# quarantines by the marker the generator prints on the way out.
cat >"$WORK_DIR/broken.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links_text": "foo://example.com:8080"
    }
  ]
}
JSON
mkdir -p "$WORK_DIR/broken.out.section-cache"
if marker_output="$(ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/broken.json" "$WORK_DIR/broken.out" "127.0.0.1" "0" 2>&1)"; then
  fail "generation with an unsupported link scheme must fail"
fi
grep -Fq 'tachyon-section-error:proxy_sec:' <<<"$marker_output" ||
  fail "generator must name the failing section in a tachyon-section-error marker, got: $marker_output"

MARKER="$(ucode -L "$TACHYON_LIB" "$RUNTIME_UC" quarantine-marker-fixture /dev/stdin <<<'FATAL[0000] tachyon-section-error:proxy_sec:manual proxy link scheme is not supported
some other line')"
[ "$MARKER" = "proxy_sec" ] ||
  fail "marker fixture must extract the section name, got '$MARKER'"

NO_MARKER="$(ucode -L "$TACHYON_LIB" "$RUNTIME_UC" quarantine-marker-fixture /dev/stdin <<<'FATAL[0000] something else entirely')"
[ -z "$NO_MARKER" ] ||
  fail "a log without a marker must extract nothing, got '$NO_MARKER'"

# -- 3. check failure -> section attribution ----------------------------------
cat >"$WORK_DIR/check_cfg.json" <<'JSON'
{
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "vless", "tag": "proxy_sec-1-out" }
  ],
  "route": {
    "rule_set": [ { "type": "local", "tag": "listy-lists-ruleset", "path": "/tmp/x.json" } ]
  }
}
JSON

attrib() {
  ucode -L "$TACHYON_LIB" "$RUNTIME_UC" quarantine-attribution-fixture "$1" "$WORK_DIR/check_cfg.json"
}

got="$(attrib 'start config: outbounds[1]: missing required field "server"')"
[ "$got" = "proxy_sec" ] ||
  fail "outbounds[1] must map to proxy_sec via tag prefix, got '$got'"

got="$(attrib 'rule_set[0]: open /tmp/x.json: no such file')"
[ "$got" = "listy" ] ||
  fail "rule_set[0] must map to listy via tag prefix, got '$got'"

got="$(attrib 'FATAL[0000] route: missing outbound tag: proxy_sec-1-out')"
[ "$got" = "proxy_sec" ] ||
  fail "missing outbound tag must map to proxy_sec, got '$got'"

got="$(attrib 'start config: inbounds[0]: unknown inbound type nonsense')"
[ -z "$got" ] ||
  fail "a section-less failure must not be attributed, got '$got'"

got="$(attrib 'start config: outbounds[0]: unknown outbound type nonsense')"
[ -z "$got" ] ||
  fail "the global direct outbound must not be attributed to a section, got '$got'"

# -- 4. wiring: init_config runs the quarantine loop --------------------------
grep -Fq 'for (let attempt = 0; attempt < 16; attempt++)' "$RUNTIME_UC" ||
  fail "init_config must loop over quarantine attempts"
grep -Fq 'section_from_check_reason(check_result.reason, temp_config)' "$RUNTIME_UC" ||
  fail "a failed check must be attributed to a section"
grep -Fq 'join(",", keys(quarantined))' "$RUNTIME_UC" ||
  fail "the quarantine list must be passed to the generator"
grep -Fq 'write_section_errors(quarantined)' "$RUNTIME_UC" ||
  fail "quarantined sections must be persisted for the UI"
grep -Fq 'ctx.quarantined_sections = parse_name_set(quarantined_sections)' "$GENERATOR_UC" ||
  fail "the generator must consume the quarantine argument"

# -- 5. runtime validator quarantine for broken outbound & inbound sections ---
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
cat >"$WORK_DIR/val_quarantine.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "good_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Good" ]
    },
    {
      ".name": "bad_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "ports": [ "99999" ]
    }
  ],
  "server": [
    {
      ".name": "bad_srv",
      ".type": "server",
      "enabled": "1",
      "protocol": "vless",
      "routing_mode": "section",
      "routing_section": "nonexistent_sec"
    }
  ]
}
JSON

export TACHYON_VALIDATOR_QUARANTINED_FILE="$WORK_DIR/val-quarantined.json"
export TACHYON_SECTION_ERRORS_FILE="$WORK_DIR/val-section-errors.json"
val_out="$(ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-quarantine-fixture "$WORK_DIR/val_quarantine.json")"
grep -Fq '"bad_sec":' <<<"$val_out" ||
  fail "broken outbound section bad_sec must be quarantined by runtime validator, got: $val_out"
grep -Fq '"bad_srv":' <<<"$val_out" ||
  fail "broken inbound server bad_srv must be quarantined by runtime validator, got: $val_out"
grep -Fq 'Причина:' <<<"$val_out" ||
  fail "quarantined section error must include expanded human-readable explanation, got: $val_out"
if grep -Fq '"good_sec":' <<<"$val_out"; then
  fail "valid section good_sec must not be quarantined"
fi

printf 'section_quarantine: OK\n'
