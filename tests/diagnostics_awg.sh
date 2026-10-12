#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROUTING="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/routing.uc"
STATUS="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/status.uc"
PROVIDERS_STATUS="$ROOT_DIR/tachyon/files/usr/lib/providers/status.uc"

# ---- 1. Routing expectations for AWG
cat >"$WORK_DIR/routing_probe.uc" <<'UC'
let routing = require("diagnostics.routing");
switch (ARGV[0]) {
case "proto":
    printf("%s", routing.server_required_inbound_proto(ARGV[1]));
    break;
case "type":
    printf("%s", routing.server_runtime_type_for_protocol(ARGV[1]));
    break;
case "port":
    printf("%s", routing.server_effective_listen_port(json(ARGV[1]), ARGV[2]));
    break;
}
UC

probe() {
  ucode -L "$TACHYON_LIB" "$WORK_DIR/routing_probe.uc" "$@"
}

[ "$(probe proto awg)" = "udp" ] || fail "AWG must be probed over UDP, not TCP"
[ "$(probe proto hysteria2)" = "udp" ] || fail "hysteria2 must stay UDP"
[ "$(probe proto vless)" = "tcp" ] || fail "vless must stay TCP"
[ "$(probe type awg)" = "wireguard" ] || fail "AWG runtime type must be wireguard"
[ "$(probe type mtproto)" = "mtproxy" ] || fail "mtproto must stay mtproxy"
[ "$(probe type vless)" = "vless" ] || fail "vless runtime type must stay vless"

# The generator gives awg_server_port precedence over listen_port and defaults
# to 51820; nft/apply.uc opens that same port - the probes must ask about it.
[ "$(probe port '{"awg_server_port":"51821","listen_port":"51820"}' awg)" = "51821" ] ||
  fail "awg_server_port must win for AWG"
[ "$(probe port '{"listen_port":"51820"}' awg)" = "51820" ] ||
  fail "AWG must fall back to listen_port"
[ "$(probe port '{}' awg)" = "51820" ] || fail "bare AWG must default to 51820"
[ "$(probe port '{"listen_port":"8443"}' vless)" = "8443" ] ||
  fail "non-AWG must keep the generic listen_port"

# ---- 2. An AWG tag generated as an endpoint must still answer inbound-summary
cat >"$WORK_DIR/endpoint_config.json" <<'JSON'
{
  "inbounds": [],
  "endpoints": [
    { "type": "wireguard", "tag": "server-awg-in", "listen_port": 51821 }
  ]
}
JSON

summary="$(ucode -L "$TACHYON_LIB" "$PROVIDERS_STATUS" inbound-summary \
  "$WORK_DIR/endpoint_config.json" "server-awg-in")"
JSON_VALUE="$summary" node - <<'NODE'
const v = JSON.parse(process.env.JSON_VALUE);
if (v.exists != 1 || v.type != "wireguard" || v.listen_port != 51821) {
  console.error(`endpoint must answer inbound-summary, got ${JSON.stringify(v)}`);
  process.exit(1);
}
NODE

missing="$(ucode -L "$TACHYON_LIB" "$PROVIDERS_STATUS" inbound-summary \
  "$WORK_DIR/endpoint_config.json" "no-such-tag")"
JSON_VALUE="$missing" node - <<'NODE'
const v = JSON.parse(process.env.JSON_VALUE);
if (v.exists != 0) {
  console.error(`unknown tag must not exist, got ${JSON.stringify(v)}`);
  process.exit(1);
}
NODE

# ---- 3. An endpoint-shaped AWG has no listen field; the port is what matches
awg_args=(
  '{"exists":"1","type":"wireguard","listen":"","listen_port":"51821"}'
  my_awg "AWG" awg rules server-awg-in 0.0.0.0 51821 "" "" wireguard udp
  1 1 1 0 "" 1 -1 -1 -1 -1
)
item="$(ucode -L "$TACHYON_LIB" -- "$STATUS" inbound-item-json "${awg_args[@]}")"
JSON_VALUE="$item" node - <<'NODE'
const v = JSON.parse(process.env.JSON_VALUE);
if (v.runtime_ok != 1) {
  console.error(`listening endpoint AWG must be runtime_ok, got ${JSON.stringify(v)}`);
  process.exit(1);
}
NODE

# The tolerance is only for the missing listen field - a port mismatch still fails.
awg_args[7]="51820"
item="$(ucode -L "$TACHYON_LIB" -- "$STATUS" inbound-item-json "${awg_args[@]}")"
JSON_VALUE="$item" node - <<'NODE'
const v = JSON.parse(process.env.JSON_VALUE);
if (v.runtime_ok != 0) {
  console.error(`AWG port mismatch must fail, got ${JSON.stringify(v)}`);
  process.exit(1);
}
NODE

printf 'Diagnostics AWG checks passed\n'
