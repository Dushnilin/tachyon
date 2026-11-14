#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DNS_FAILOVER_UC="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/dns_failover.uc"
PRIORITY_UC="$ROOT_DIR/tachyon/files/usr/lib/tachyon_core/priority.uc"
WATCHDOG_UC="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# 1. dns_failover.uc: recovery probe short-circuits when current_index == 0
cat >"$WORK_DIR/dns-state.json" <<'JSON'
{
  "main_servers": [ "77.88.8.8", "1.1.1.1" ],
  "bootstrap_servers": [ "77.88.8.8" ],
  "main_index": 0,
  "bootstrap_index": 0
}
JSON
cat >"$WORK_DIR/dns-alive.json" <<'JSON'
{
  "0": 0,
  "1": 1
}
JSON

recovery_out="$(ucode -L "$TACHYON_LIB" "$DNS_FAILOVER_UC" select-fixture "$WORK_DIR/dns-state.json" "$WORK_DIR/dns-alive.json" main 1)"
node - "$recovery_out" <<'NODE'
const parsed = JSON.parse(process.argv[2]);
if (parsed.index !== 0 || parsed.reason !== 'unchanged' || parsed.alive !== true) {
  console.error('Expected recovery at index 0 to short-circuit without switching:', parsed);
  process.exit(1);
}
NODE

# 2. priority.uc: default active_check_interval >= 15s
prio_default_iv="$(ucode -L "$TACHYON_LIB" -e '
const pr = require("tachyon_core.priority");
let st = pr.init_group_state({}, { tag: "p1", kind: "priority", levels: [ { outbounds: [ "a" ] }, { outbounds: [ "b" ] } ] });
printf("%d\n", int(st.nextActiveCheck) >= 0 ? 1 : 0);
')"
assert_eq "1" "$prio_default_iv" "priority init_group_state succeeds"

# 3. watchdog.uc: lite-busy-check scales load1 threshold with CPU count (4 cores: load 2.50 is not busy, 3.60 is busy)
cat >"$WORK_DIR/proc-stat-4cpu" <<'STAT'
cpu  1000 0 500 50000 0 0 0 0
cpu0 250 0 125 12500 0 0 0 0
cpu1 250 0 125 12500 0 0 0 0
cpu2 250 0 125 12500 0 0 0 0
cpu3 250 0 125 12500 0 0 0 0
STAT
printf 'tachyon.settings=settings\ntachyon.settings.lite_mode=1\n' >"$WORK_DIR/lite-uci.state"

printf '2.50 2.40 2.10 1/120 1234\n' >"$WORK_DIR/loadavg-ok"
busy_ok="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/lite-uci.state" TACHYON_CONFIG_NAME="tachyon" \
  ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" lite-busy-check "$WORK_DIR/proc-stat-4cpu" "$WORK_DIR/loadavg-ok")"
assert_eq "0" "$busy_ok" "4-core router at load 2.50 must not falsely hibernate probes"

printf '3.60 3.10 2.80 3/150 1235\n' >"$WORK_DIR/loadavg-high"
busy_high="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/lite-uci.state" TACHYON_CONFIG_NAME="tachyon" \
  ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" lite-busy-check "$WORK_DIR/proc-stat-4cpu" "$WORK_DIR/loadavg-high")"
assert_eq "1" "$busy_high" "4-core router at load 3.60 (>= 0.85 * 4) must be marked busy"

# 4. subscription/parser.uc: Xray probeInterval < 30s is clamped to 30s
cat >"$WORK_DIR/xray-sub.json" <<'JSON'
{
  "observatory": {
    "probeInterval": "5s",
    "probeUrl": "https://cp.cloudflare.com/generate_204"
  },
  "outbounds": [
    {
      "tag": "node-1",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "1.1.1.1",
            "port": 443,
            "users": [ { "id": "11111111-1111-1111-1111-111111111111" } ]
          }
        ]
      }
    }
  ],
  "routing": {
    "balancers": [
      {
        "tag": "fast",
        "selector": [ "node-1" ],
        "strategy": { "type": "leastPing" }
      }
    ]
  }
}
JSON

ucode -L "$TACHYON_LIB" -e "
const parser = require('subscription.parser');
let ok = parser.normalize_content_validated('$WORK_DIR/xray-sub.json', '$WORK_DIR/xray-out.json', '', 'tachyon-core');
if (!ok) {
    warn(parser.get_last_normalize_error() + '\n');
    exit(1);
}
"
node - "$WORK_DIR/xray-out.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ut = (data.outbounds || []).find(o => o.type === 'urltest' && o.tag === 'fast');
if (!ut || ut.interval !== '30s') {
  console.error('Expected urltest interval clamped to 30s, got:', ut);
  process.exit(1);
}
NODE

printf 'background probe discipline checks passed\n'
