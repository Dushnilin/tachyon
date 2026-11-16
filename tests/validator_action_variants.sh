#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
VAL="$LIB_DIR/config/validator.uc"
[ -f "$VAL" ] || fail "config/validator.uc not found"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<EOF
#!/bin/sh
echo "\$@" >> "$WORK_DIR/logger.log"
EOF
chmod +x "$WORK_DIR/bin/logger"
export PATH="$WORK_DIR/bin:$PATH"

run_validator_fixture() {
    local fixture="$1"
    local version_state="$2"

    local state_dir="$WORK_DIR/tachyon_state"
    mkdir -p "$state_dir"
    if [ -n "$version_state" ]; then
        echo "$version_state" > "$state_dir/tachyon-core-version"
    else
        rm -f "$state_dir/tachyon-core-version"
    fi

    : > "$WORK_DIR/logger.log"
    local ctx_json="{\"tachyon_core_version_state_file\":\"$state_dir/tachyon-core-version\"}"
    TACHYON_CORE_VERSION_FILE="$state_dir/tachyon-core-version" \
        ucode -L "$LIB_DIR" "$VAL" validate-section-action-core-support "$fixture" "$ctx_json" "$version_state"
}

make_section_fixture() {
    local action="$1"
    local out="$2"
    cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "sec1",
      ".type": "section",
      "enabled": "1",
      "action": "$action"
    }
  ]
}
JSON
}

make_server_fixture() {
    local protocol="$1"
    local out="$2"
    cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "server": [
    {
      ".name": "srv1",
      ".type": "server",
      "enabled": "1",
      "protocol": "$protocol"
    }
  ]
}
JSON
}

# 1. Action 'mieru' with tachyon-core must pass
make_section_fixture "mieru" "$WORK_DIR/sec_mieru.json"
run_validator_fixture "$WORK_DIR/sec_mieru.json" "0.5.7" \
    || fail "action 'mieru' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"
if grep -q "Aborted" "$WORK_DIR/logger.log"; then
    fail "action 'mieru' should not abort on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"
fi

# 2. Action 'warp' with tachyon-core must pass
make_section_fixture "warp" "$WORK_DIR/sec_warp.json"
run_validator_fixture "$WORK_DIR/sec_warp.json" "0.5.7" \
    || fail "action 'warp' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 3. Action 'openvpn' with tachyon-core must pass
make_section_fixture "openvpn" "$WORK_DIR/sec_openvpn.json"
run_validator_fixture "$WORK_DIR/sec_openvpn.json" "0.5.7" \
    || fail "action 'openvpn' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 4a. Action 'awg' with tachyon-core must pass
make_section_fixture "awg" "$WORK_DIR/sec_awg.json"
run_validator_fixture "$WORK_DIR/sec_awg.json" "0.5.7" \
    || fail "action 'awg' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 4b. awg_j1..j3/itime on tachyon-core must fail
cat >"$WORK_DIR/sec_awg_junk.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "sec1",
      ".type": "section",
      "enabled": "1",
      "action": "awg",
      "awg_j1": "<b 0x0102030405>",
      "awg_itime": "30"
    }
  ]
}
JSON
if run_validator_fixture "$WORK_DIR/sec_awg_junk.json" "0.5.7"; then
    fail "awg_j1/awg_itime must fail on tachyon-core"
fi
grep -q "does not accept" "$WORK_DIR/logger.log" \
    || fail "awg_junk on tachyon-core must report rejection, log: $(cat "$WORK_DIR/logger.log")"

# 5. Server 'mtproto' fails on 0.0.7 and passes on 0.5.7
make_server_fixture "mtproto" "$WORK_DIR/srv_mtproto.json"
if run_validator_fixture "$WORK_DIR/srv_mtproto.json" "v0.0.7-tachyon.0"; then
    fail "server 'mtproto' must fail on tachyon-core 0.0.x"
fi
grep -q "does not support" "$WORK_DIR/logger.log" \
    || fail "server 'mtproto' on tachyon-core 0.0.x must fail, log: $(cat "$WORK_DIR/logger.log")"
run_validator_fixture "$WORK_DIR/srv_mtproto.json" "0.5.7" \
    || fail "server 'mtproto' must pass on tachyon-core 0.5.7, log: $(cat "$WORK_DIR/logger.log")"

# 6. Server 'naive' with tachyon-core must pass
make_server_fixture "naive" "$WORK_DIR/srv_naive.json"
run_validator_fixture "$WORK_DIR/srv_naive.json" "0.5.7" \
    || fail "server 'naive' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 7. Section action 'naive' must pass
make_section_fixture "naive" "$WORK_DIR/sec_naive.json"
run_validator_fixture "$WORK_DIR/sec_naive.json" "0.5.7" \
    || fail "action 'naive' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

printf 'validator action core support tests passed\n'
