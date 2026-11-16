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
  local version="$1"
  local state_dir="$WORK_DIR/state"
  mkdir -p "$state_dir"
  printf '%s\n' "$version" > "$state_dir/version"
  : > "$WORK_DIR/logger.log"
  local ctx_json
  ctx_json="$(printf '{"tachyon_core_version_state_file":"%s"}' "$state_dir/version")"
  TACHYON_CORE_VERSION_FILE="$state_dir/version" \
    ucode -L "$TACHYON_LIB" "$VAL" validate-section-action-core-support "$WORK_DIR/wdtt_fixture.json" "$ctx_json" "$version"
}

run_quarantine_check() {
  local version="$1"
  local state_dir="$WORK_DIR/state"
  mkdir -p "$state_dir"
  printf '%s\n' "$version" > "$state_dir/version"
  : > "$WORK_DIR/logger.log"
  local ctx_json
  ctx_json="$(printf '{"tachyon_core_version_state_file":"%s"}' "$state_dir/version")"
  TACHYON_CORE_VERSION_FILE="$state_dir/version" \
    ucode -L "$TACHYON_LIB" "$VAL" validate-runtime-quarantine-fixture "$WORK_DIR/wdtt_fixture.json" "$ctx_json" "$version"
}

# 1. Under tachyon-core 0.5.7, both action='csqtt' and server protocol='wdtt' must pass.
run_variant_check "0.5.7" \
  || fail "action='csqtt' and server protocol='wdtt' must pass under tachyon-core 0.5.7, log: $(cat "$WORK_DIR/logger.log")"
if grep -q "Aborted" "$WORK_DIR/logger.log"; then
  fail "tachyon-core 0.5.7 must not abort on csqtt/wdtt, log: $(cat "$WORK_DIR/logger.log")"
fi

q_core="$(run_quarantine_check "0.5.7")"
if grep -Eq '"(csqtt_sec|wdtt_srv)":' <<<"$q_core"; then
  fail "tachyon-core 0.5.7 must not quarantine csqtt_sec or wdtt_srv, got: $q_core"
fi

# 2. Verify csqtt outbound and wdtt server validate cleanly without aborts on tachyon-core 0.5.7.
grep -Fq 'wdtt' "$TACHYON_LIB/tachyon_core/core_profile.uc" ||
  fail "core_profile.uc must list wdtt in CORE_PROTOCOLS and CORE_INBOUNDS"

printf 'wdtt_validator_gate: OK\n'
