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
    local variant_marker="$2"
    local version_state="$3"

    local state_dir="$WORK_DIR/tachyon_state"
    mkdir -p "$state_dir"
    if [ -n "$variant_marker" ]; then
        echo "$variant_marker" > "$state_dir/sing-box-variant"
    else
        rm -f "$state_dir/sing-box-variant"
    fi
    if [ -n "$version_state" ]; then
        echo "$version_state" > "$state_dir/sing-box-version"
    else
        rm -f "$state_dir/sing-box-version"
    fi

    : > "$WORK_DIR/logger.log"
    local ctx_json="{\"sing_box_variant_state_file\":\"$state_dir/sing-box-variant\",\"sing_box_version_state_file\":\"$state_dir/sing-box-version\"}"
    ucode -L "$LIB_DIR" "$VAL" validate-section-action-variant-support "$fixture" "$ctx_json" "$version_state"
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

# 1. Action 'mieru' with sing-box-extended must pass
make_section_fixture "mieru" "$WORK_DIR/sec_mieru.json"
run_validator_fixture "$WORK_DIR/sec_mieru.json" "extended" "1.14.2-extended-2.7.2" \
    || fail "action 'mieru' must be accepted on sing-box-extended, log: $(cat "$WORK_DIR/logger.log")"
if grep -q "Aborted" "$WORK_DIR/logger.log"; then
    fail "action 'mieru' should not abort on sing-box-extended, log: $(cat "$WORK_DIR/logger.log")"
fi

# 2. Action 'mieru' with tachyon-core must pass: the core ships a mieru
#    outbound (KNOWN_OUTBOUND_TYPES in its validate.rs), so the old "does not
#    implement Mieru yet" refusal is stale.
run_validator_fixture "$WORK_DIR/sec_mieru.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "action 'mieru' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 3. Action 'warp' with tachyon-core must pass
make_section_fixture "warp" "$WORK_DIR/sec_warp.json"
run_validator_fixture "$WORK_DIR/sec_warp.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "action 'warp' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 4. Action 'openvpn' with tachyon-core must pass
make_section_fixture "openvpn" "$WORK_DIR/sec_openvpn.json"
run_validator_fixture "$WORK_DIR/sec_openvpn.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "action 'openvpn' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 4a. Action 'awg' with tachyon-core must pass: AmneziaWG lives inside its
#     wireguard endpoint (AwgParams::from_obj), so the binary gate must not fire.
make_section_fixture "awg" "$WORK_DIR/sec_awg.json"
run_validator_fixture "$WORK_DIR/sec_awg.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "action 'awg' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 4b. ...and must still be refused by a stock sing-box, which has no endpoint.
if run_validator_fixture "$WORK_DIR/sec_awg.json" "" "1.12.0"; then
    fail "action 'awg' must fail on stock sing-box"
fi

# 4c. awg_j1..j3/itime on tachyon-core must fail: the core has no junk-signature
#     fields and rejects unknown endpoint keys outright.
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
if run_validator_fixture "$WORK_DIR/sec_awg_junk.json" "tachyon-core" "v0.0.7-tachyon.0"; then
    fail "awg_j1/awg_itime must fail on tachyon-core"
fi
grep -q "does not accept junk-signature fields" "$WORK_DIR/logger.log" \
    || fail "awg_junk on tachyon-core must name the junk-signature fields, log: $(cat "$WORK_DIR/logger.log")"

# 5. Server 'mtproto' with tachyon-core must fail with core note
make_server_fixture "mtproto" "$WORK_DIR/srv_mtproto.json"
if run_validator_fixture "$WORK_DIR/srv_mtproto.json" "tachyon-core" "v0.0.7-tachyon.0"; then
    fail "server 'mtproto' must fail on tachyon-core"
fi
grep -q "tachyon-core does not implement MTProto yet" "$WORK_DIR/logger.log" \
    || fail "server 'mtproto' on tachyon-core must fail, log: $(cat "$WORK_DIR/logger.log")"

# 6. Server 'mtproto' with sing-box-extended must pass
run_validator_fixture "$WORK_DIR/srv_mtproto.json" "extended" "1.14.2-extended-2.7.2" \
    || fail "server 'mtproto' must be accepted on sing-box-extended, log: $(cat "$WORK_DIR/logger.log")"

# 7. Server 'naive' with tachyon-core must pass: the core lists a naive inbound
#    (KNOWN_INBOUND_TYPES) and Tachyon emits the standard users shape, so
#    nothing on our side may refuse it.
make_server_fixture "naive" "$WORK_DIR/srv_naive.json"
run_validator_fixture "$WORK_DIR/srv_naive.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "server 'naive' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"

# 8. Section action 'naive' is a plain outbound every core carries (its own
#    NaiveOutboundOptions in sing-box and naive.rs in tachyon-core), so it must
#    be a supported action with no variant gate at all.
make_section_fixture "naive" "$WORK_DIR/sec_naive.json"
run_validator_fixture "$WORK_DIR/sec_naive.json" "tachyon-core" "v0.0.7-tachyon.0" \
    || fail "action 'naive' must be accepted on tachyon-core, log: $(cat "$WORK_DIR/logger.log")"
run_validator_fixture "$WORK_DIR/sec_naive.json" "" "1.15.0" \
    || fail "action 'naive' must be accepted on stock sing-box, log: $(cat "$WORK_DIR/logger.log")"

printf 'validator action variant tests passed\n'
