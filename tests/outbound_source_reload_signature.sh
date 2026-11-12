#!/usr/bin/env bash
# Editing a modular outbound_source (e.g. AmneziaWG params) must change the
# sing-box reload signature; otherwise reload is skipped as "unchanged" and the
# runtime keeps the old endpoint config.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

STATE_UC="$TACHYON_LIB/service/state.uc"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TACHYON_UCI_LOG_FILE="$WORK_DIR/uci.log"

write_state() {
  cat > "$TACHYON_UCI_STATE_FILE" <<EOF_UCI
tachyon.settings=settings
tachyon.AI=section
tachyon.AI.enabled=1
tachyon.AI.action=connection
tachyon.AI.outbound_source_refs=src_awg
tachyon.src_awg=outbound_source
tachyon.src_awg.enabled=$1
tachyon.src_awg.source_type=awg
tachyon.src_awg.awg_private_key=0Gm+E55B8QBcoKXMiT0gZJJ1HpsFFfsOU36JZKAZJms=
tachyon.src_awg.awg_server_address=203.0.113.1
tachyon.src_awg.awg_server_port=51820
tachyon.src_awg.awg_peer_public_key=jutYUoOA8uYAQ1jvOHhJ3CVPkfplca2tRf4OTXMkvCI=
tachyon.src_awg.awg_s3=$2
EOF_UCI
}

sig() {
  ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature
}

write_state 1 0
base="$(sig)"
[ -n "$base" ] || fail "sing-box-signature printed nothing"

write_state 1 64
[ "$(sig)" != "$base" ] ||
  fail "changing an outbound_source AWG field must change sing-box-signature"

write_state 0 0
[ "$(sig)" != "$base" ] ||
  fail "disabling an outbound_source must change sing-box-signature"

echo "PASS: outbound_source edits change the reload signature"
