#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VAL="$TACHYON_LIB/config/validator.uc"
[ -f "$VAL" ] || fail "config/validator.uc not found"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<EOF
#!/bin/sh
echo "\$@" >> "$WORK_DIR/logger.log"
EOF
chmod +x "$WORK_DIR/bin/logger"
export PATH="$WORK_DIR/bin:$PATH"

export TACHYON_VALIDATOR_QUARANTINED_FILE="$WORK_DIR/val-quarantined.json"
export TACHYON_SECTION_ERRORS_FILE="$WORK_DIR/val-section-errors.json"

cat >"$WORK_DIR/wdtt_fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "csqtt_sec",
      ".type": "section",
      "enabled": "1",
      "action": "csqtt",
      "csqtt_server": "vpn.example.com",
      "csqtt_password": "secret",
      "domain_suffix": [ "example.com" ]
    }
  ],
  "server": [
    {
      ".name": "wdtt_srv",
      ".type": "server",
      "enabled": "1",
      "protocol": "wdtt",
      "listen_port": "46000"
    }
  ]
}
JSON

run_variant_check() {
  local marker="$1"
  local version="$2"
  local state_dir="$WORK_DIR/state"
  mkdir -p "$state_dir"
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker" > "$state_dir/variant"
  else
    rm -f "$state_dir/variant"
  fi
  printf '%s\n' "$version" > "$state_dir/version"
  : > "$WORK_DIR/logger.log"
  local ctx_json
  ctx_json="$(printf '{"sing_box_variant_state_file":"%s","sing_box_version_state_file":"%s"}' "$state_dir/variant" "$state_dir/version")"
  SB_VARIANT_STATE_FILE="$state_dir/variant" SB_VERSION_STATE_FILE="$state_dir/version" \
    ucode -L "$TACHYON_LIB" "$VAL" validate-section-action-variant-support "$WORK_DIR/wdtt_fixture.json" "$ctx_json" "$version"
}

run_quarantine_check() {
  local marker="$1"
  local version="$2"
  local state_dir="$WORK_DIR/state"
  mkdir -p "$state_dir"
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker" > "$state_dir/variant"
  else
    rm -f "$state_dir/variant"
  fi
  printf '%s\n' "$version" > "$state_dir/version"
  : > "$WORK_DIR/logger.log"
  local ctx_json
  ctx_json="$(printf '{"sing_box_variant_state_file":"%s","sing_box_version_state_file":"%s"}' "$state_dir/variant" "$state_dir/version")"
  SB_VARIANT_STATE_FILE="$state_dir/variant" SB_VERSION_STATE_FILE="$state_dir/version" \
    ucode -L "$TACHYON_LIB" "$VAL" validate-runtime-quarantine-fixture "$WORK_DIR/wdtt_fixture.json" "$ctx_json" "$version"
}

# 1. Under tachyon-core 0.5.7, both action='csqtt' and server protocol='wdtt' must pass.
run_variant_check "tachyon-core" "0.5.7" \
  || fail "action='csqtt' and server protocol='wdtt' must pass under tachyon-core 0.5.7, log: $(cat "$WORK_DIR/logger.log")"
if grep -q "Aborted" "$WORK_DIR/logger.log"; then
  fail "tachyon-core 0.5.7 must not abort on csqtt/wdtt, log: $(cat "$WORK_DIR/logger.log")"
fi

q_core="$(run_quarantine_check "tachyon-core" "0.5.7")"
if grep -Eq '"(csqtt_sec|wdtt_srv)":' <<<"$q_core"; then
  fail "tachyon-core 0.5.7 must not quarantine csqtt_sec or wdtt_srv, got: $q_core"
fi

# 2. Under plain sing-box (1.14.0), both action='csqtt' and server protocol='wdtt' must fail / quarantine.
if run_variant_check "" "1.14.0"; then
  fail "action='csqtt' and server protocol='wdtt' must fail under plain sing-box 1.14.0"
fi
grep -q "requires tachyon-core" "$WORK_DIR/logger.log" \
  || fail "plain sing-box failure must mention tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

q_plain="$(run_quarantine_check "" "1.14.0")"
grep -Fq '"csqtt_sec":' <<<"$q_plain" \
  || fail "plain sing-box must quarantine csqtt_sec, got: $q_plain"
grep -Fq '"wdtt_srv":' <<<"$q_plain" \
  || fail "plain sing-box must quarantine wdtt_srv, got: $q_plain"

printf 'wdtt_validator_gate: OK\n'
