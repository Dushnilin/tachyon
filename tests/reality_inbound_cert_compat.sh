#!/usr/bin/env bash
# Invariant: reality server inbounds must attach tls_certificate_path and tls_key_path
# when configured, maintaining compatibility with tachyon-core <= 0.1.3 validator.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SERVERS_UC="$TACHYON_LIB/tachyon_core/servers.uc"
SERVICE_UC="$TACHYON_LIB/server/service.uc"

[ -f "$SERVERS_UC" ] || fail "missing $SERVERS_UC"
[ -f "$SERVICE_UC" ] || fail "missing $SERVICE_UC"

# 1. servers.uc must attach certificate/key to reality inbounds for tachyon-core <= 0.1.3 validator compatibility
if ! grep -q 'REALITY_FALLBACK_CERTIFICATE' "$SERVERS_UC"; then
  fail "servers.uc must declare REALITY_FALLBACK_CERTIFICATE"
fi

if ! awk '/else if \(security == "reality"\)/,/inbound\.tls = tls;/' "$SERVERS_UC" | grep -q 'tls\.certificate = REALITY_FALLBACK_CERTIFICATE'; then
  fail "servers.uc apply_tls must attach fallback certificate/key to reality inbounds"
fi

# 2. Test generate-config with reality server (without explicit cert paths)
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
[ -f "$GENERATOR_UC" ] || fail "missing $GENERATOR_UC"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "server": [
    {
      ".name": "VLESSXHTTP",
      ".type": "server",
      "enabled": "1",
      "protocol": "vless",
      "security": "reality",
      "server_uuid": "a86dca7b-fba1-4b19-9cf4-fa47d894b910",
      "reality_private_key": "dGhpc2lzYXNhbXBsZXJlYWxpdHlrZXkxMjM0NTY3ODk",
      "reality_handshake_server": "www.microsoft.com",
      "reality_handshake_server_port": "443"
    }
  ]
}
JSON

if command -v ucode >/dev/null 2>&1; then
  config="$WORK_DIR/config.json"
  mkdir -p "$config.section-cache" "$config.rulesets"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$config" "127.0.0.1" "0" "1" >/dev/null

  ucode -L "$TACHYON_LIB" -e '
  let fs = require("fs");
  let raw = fs.readfile("'"$config"'");
  let parsed = json(raw);

  let found = false;
  for (let inbound in parsed.inbounds) {
    if (inbound.tag == "server-VLESSXHTTP-in") {
      found = true;
      if (!inbound.tls || !inbound.tls.enabled)
        die("inbound.tls.enabled must be true");
      if (!inbound.tls.reality || !inbound.tls.reality.enabled)
        die("inbound.tls.reality.enabled must be true");
      if (!length(inbound.tls.certificate) || !length(inbound.tls.key))
        die("inbound.tls must have fallback inline certificate and key for reality");
    }
  }

  if (!found)
    die("server-VLESSXHTTP-in not found in inbounds");
  '
fi

printf 'reality inbound certificate compatibility checks passed\n'
