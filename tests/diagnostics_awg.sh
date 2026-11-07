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

# ---- 4. Conntrack session parsing and fwmark decoding
cat >"$WORK_DIR/nf_conntrack" <<'CT'
ipv4     2 tcp      6 431995 ESTABLISHED src=192.168.1.50 dst=142.250.74.110 sport=54321 dport=443 packets=20 bytes=3200 src=142.250.74.110 dst=95.24.100.12 sport=443 dport=54321 packets=25 bytes=24800 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 170 src=192.168.1.50 dst=1.1.1.1 sport=60123 dport=443 packets=15 bytes=4100 src=1.1.1.1 dst=95.24.100.12 sport=443 dport=60123 packets=18 bytes=19200 [ASSURED] mark=33554433 zone=0 use=2
ipv4     2 tcp      6 15 TIME_WAIT src=192.168.1.50 dst=8.8.8.8 sport=50000 dport=443 packets=4 bytes=240 src=8.8.8.8 dst=95.24.100.12 sport=443 dport=50000 packets=4 bytes=240 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 300 ESTABLISHED src=192.168.1.50 dst=192.168.1.1 sport=55555 dport=80 packets=10 bytes=1200 src=192.168.1.1 dst=192.168.1.50 sport=80 dport=55555 packets=10 bytes=4500 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 300 ESTABLISHED src=95.24.100.12 dst=185.199.108.153 sport=41234 dport=443 packets=10 bytes=1500 src=185.199.108.153 dst=95.24.100.12 sport=443 dport=41234 packets=10 bytes=8500 [ASSURED] mark=134217728 zone=0 use=2
ipv4     2 tcp      6 300 ESTABLISHED src=37.143.105.83 dst=95.85.224.159 sport=45120 dport=443 packets=12 bytes=20400 src=95.85.224.159 dst=37.143.105.83 sport=443 dport=45120 packets=10 bytes=60 [ASSURED] mark=0 zone=0 use=2
CT

ct_json="$(TACHYON_CONNTRACK_FILE="$WORK_DIR/nf_conntrack" ucode -L "$TACHYON_LIB" -e '
  let routing = require("diagnostics.routing");
  let mark_info = {
    marks: { "33554433": "youtube_z2-out" },
    default_zapret: "zapret-out",
    default_zapret2: "youtube_z2-out"
  };
  let existing = {};
  existing[routing.connection_tuple_key("tcp", "192.168.1.50", "54321", "142.250.74.110", "443")] = true;
  let conns = routing.read_conntrack_connections(mark_info, existing);
  printf("%J\n", conns);
')"

JSON_VALUE="$ct_json" node - <<'NODE'
const conns = JSON.parse(process.env.JSON_VALUE);
if (!Array.isArray(conns) || conns.length !== 1) {
  console.error(`expected 1 non-duplicate active public conntrack connection, got ${JSON.stringify(conns)}`);
  process.exit(1);
}
const c = conns[0];
if (
  c.id !== "ct:udp:192.168.1.50:60123:1.1.1.1:443" ||
  c.dataSource !== "conntrack" ||
  c.upload !== 4100 ||
  c.download !== 19200 ||
  !Array.isArray(c.chains) ||
  c.chains[0] !== "youtube_z2-out"
) {
  console.error(`unexpected conntrack entry fields: ${JSON.stringify(c)}`);
  process.exit(1);
}
NODE

printf 'Diagnostics AWG checks passed\n'
