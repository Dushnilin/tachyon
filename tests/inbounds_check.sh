#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DIAGNOSTICS_RUNTIME="$TACHYON_LIB/diagnostics/runtime.uc"
STATUS_UC="$TACHYON_LIB/diagnostics/status.uc"
LEAK_CHECK="$TACHYON_LIB/diagnostics/leak_check.uc"

# 1. Syntax check
ucode -L "$TACHYON_LIB" -c "$DIAGNOSTICS_RUNTIME" || fail "runtime.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$DIAGNOSTICS_RUNTIME" || fail "runtime.uc strict syntax error"
ucode -L "$TACHYON_LIB" -c "$STATUS_UC" || fail "status.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$STATUS_UC" || fail "status.uc strict syntax error"
ucode -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc strict syntax error"

# 2. Test check-inbounds runtime mode
check_out="$(ucode -L "$TACHYON_LIB" "$DIAGNOSTICS_RUNTIME" check-inbounds 2>/dev/null || true)"
[ -n "$check_out" ] || fail "check-inbounds should return JSON output"

JSON_VAL="$check_out" node - <<'NODE'
const data = JSON.parse(process.env.JSON_VAL);
if (typeof data.enabled_count !== 'number' || typeof data.requires_public_wan !== 'number') {
  console.error("Invalid check-inbounds response:", data);
  process.exit(1);
}
NODE

# 3. Test render_global_inbounds_check in status.uc for Tailscale
cat >"$WORK_DIR/test_tailscale.json" <<'EOF'
{
  "enabled_count": 1,
  "wan_ip": "192.168.1.60",
  "wan_public": 0,
  "requires_public_wan": 0,
  "items": [
    {
      "label": "Head",
      "protocol": "tailscale",
      "tag": "server-Head-in",
      "runtime_ok": 1,
      "routes_configured": 1
    }
  ]
}
EOF

render_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" global-inbounds-check < "$WORK_DIR/test_tailscale.json")"
if echo "$render_out" | grep -Fq "[WARN] WAN IP is not public"; then
  fail "Tailscale with private WAN IP should not produce [WARN] in render_global_inbounds_check: $render_out"
fi
if ! echo "$render_out" | grep -Fq "[OK] WAN IP: 192.168.1.60 (Tailscale does not require public WAN)"; then
  fail "Expected Tailscale exemption message in render_global_inbounds_check: $render_out"
fi

# 4. Test render_global_inbounds_check for public inbound (VLESS) with private WAN
cat >"$WORK_DIR/test_vless.json" <<'EOF'
{
  "enabled_count": 1,
  "wan_ip": "192.168.1.60",
  "wan_public": 0,
  "requires_public_wan": 1,
  "items": [
    {
      "label": "Vless",
      "protocol": "vless",
      "tag": "server-vless-in",
      "runtime_ok": 1,
      "routes_configured": 1,
      "listening": 1,
      "firewall_required": 1,
      "firewall_open": 1,
      "port_conflict": 0
    }
  ]
}
EOF

render_vless_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" global-inbounds-check < "$WORK_DIR/test_vless.json")"
if ! echo "$render_vless_out" | grep -Fq "[WARN] WAN IP is not public"; then
  fail "VLESS with private WAN IP should produce [WARN] in render_global_inbounds_check: $render_vless_out"
fi

# 5. Native Tailscale has no sing-box endpoint/route rule: the item must still
# report runtime_ok=1 (TCH-1037), while the same empty runtime without the
# native flag must keep reporting a failure.
# NB: no negative argument values here — ucode's CLI parses "-1" as an option.
native_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" inbound-item-json '{}' 'ts' 'Head' 'tailscale' 'native' \
  'server-Head-in' '0.0.0.0' '' '' '' 'tailscale' 'tcp' '0' '0' '0' '0' '' '1' '0' '0' '0' '1')"
printf '%s' "$native_out" | ucode -e '
let fs = require("fs");
let d = json(fs.readfile("/dev/stdin"));
if (int(d.runtime_ok) != 1)
    die("native tailscale item must report runtime_ok=1: " + sprintf("%J", d) + "\n");
if (d.routing_mode != "native")
    die("native tailscale item must keep routing_mode=native: " + sprintf("%J", d) + "\n");
' || fail "native Tailscale inbound item check failed"

non_native_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" inbound-item-json '{}' 'ts' 'Head' 'tailscale' 'rules' \
  'server-Head-in' '0.0.0.0' '' '' '' 'tailscale' 'tcp' '0' '0' '0' '0' '' '0' '0' '0' '0' '0')"
printf '%s' "$non_native_out" | ucode -e '
let fs = require("fs");
let d = json(fs.readfile("/dev/stdin"));
if (int(d.runtime_ok) != 0)
    die("missing non-native tailscale endpoint must still report runtime_ok=0: " + sprintf("%J", d) + "\n");
' || fail "non-native Tailscale inbound item regression"

printf 'inbounds check diagnostics tests passed\n'
