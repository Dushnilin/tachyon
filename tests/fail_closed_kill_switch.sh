#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
# The kill-switch guard keeps fail-closed setups blocked while TachyonTable is
# absent. Only pure functions run here; nothing touches the host firewall.
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
NFT_UC="$TACHYON_LIB/nft/apply.uc"
HOTPLUG="$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"

cat >"$WORK_DIR/probe.uc" <<'UC'
let ks = require("service.kill_switch");
function check(ok, message) { if (!ok) die(message + "\n"); }
let blocked = { ".name": "vpn", enabled: "1", fail_policy: "block" };

check(ks.veto({}, [ blocked ]) == "fail_policy=block: vpn", "Fail-closed section did not veto");
check(ks.veto({ emergency_direct_bypass: "0" }, []) == "emergency_direct_bypass=0", "Global kill-switch did not veto");
check(ks.veto({}, [ { fail_policy: "keep" }, { fail_policy: "direct" },
                    { ".name": "off", enabled: "0", fail_policy: "block" } ]) == "",
    "Non fail-closed setup was vetoed");

check(join(",", ks.source_interfaces({})) == "br-lan", "Missing source interfaces did not default to br-lan");
let ifaces = ks.source_interfaces({ source_network_interfaces: [ "br-lan", "br-guest", "br-lan", "x\" } accept", "" ] });
check(join(",", ifaces) == "br-lan,br-guest", "Unsafe or duplicate interface names reached the ruleset");

let rs = ks.ruleset([ "br-lan", "br-guest" ]);
check(index(rs, "table inet " + ks.GUARD_TABLE + " {") >= 0, "Guard does not own a separate table");
check(index(rs, "set " + ks.GATE_SET + " {") >= 0 && index(rs, "type ifname") >= 0, "Guard has no interface gate set");
check(index(rs, "hook forward") >= 0, "Guard is not on the forward hook");
check(index(rs, "iifname { \"br-lan\", \"br-guest\" } oifname != { \"br-lan\", \"br-guest\" } iifname != @" + ks.GATE_SET + " counter drop") >= 0,
    "Guard does not drop LAN traffic leaving the LAN while the gate is closed");
// An fw4 reload replays this text: deleting the table would wipe an open gate.
check(index(rs, "delete table") < 0, "Replaying the guard would reset the gate");
print(rs);
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc" >"$WORK_DIR/ruleset.nft"

# Syntax-check the generated ruleset where nft can do so without applying it.
# Inside unprivileged containers / CI runners without CAP_NET_ADMIN, nft -c exits 1
# with "netlink: Error: cache initialization failed: Operation not permitted" after
# parsing, whereas invalid nft syntax emits "syntax error".
if command -v nft >/dev/null 2>&1; then
  if nft list tables >/dev/null 2>&1; then
    nft -c -f "$WORK_DIR/ruleset.nft" || fail "Generated kill-switch ruleset is rejected by nft"
  else
    nft_out="$(timeout 10 nft -c -f "$WORK_DIR/ruleset.nft" 2>&1 || true)"
    if printf '%s\n' "$nft_out" | grep -Fq 'syntax error'; then
      fail "Generated kill-switch ruleset has nft syntax errors: $nft_out"
    fi
  fi
fi

# Every window without TachyonTable must hold the guard.
awk '
  /^function cleanup_failed_runtime\(\)/ { f = 1 }
  f && /stop_main\(\);/ { stop = 1 }
  f && /kill_switch\.hold\(\)/ && stop { hold = 1 }
  f && /dnsmasq_restore_fail_safe\(\);/ && hold { ok = 1 }
  f && /^}/ { exit }
  END { exit ok ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "failed start must decide fail-closed before rolling DNS back"
for fn in 'restart' 'restart_runtime_for_reload'; do
  awk -v fn="^function ${fn}\\\\(\\\\)" '
    $0 ~ fn { f = 1 }
    f && /kill_switch\.hold\(\)/ { hold = 1 }
    f && /stop_main\(\);/ { ok = hold; exit }
    END { exit ok ? 0 : 1 }
  ' "$LIFECYCLE_UC" || fail "$fn must hold the kill-switch before stop_main drops interception"
done
awk '
  /^function stop_impl\(\)/ { f = 1 }
  f && /stop_main\(\);/ { stop = 1 }
  f && /kill_switch\.release\(\)/ && stop { ok = 1; exit }
  f && /^}/ { exit }
  END { exit ok ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "manual stop must release the kill-switch"
awk '
  /^function nft_rebuild_runtime_from_uci\(/ { f = 1 }
  f && /kill_switch\.hold\(\)/ { hold = 1 }
  f && /nft_delete_table\(table\)/ && !hold { exit }
  f && /if \(built\)/ && hold { built = 1 }
  f && /kill_switch\.release\(\)/ && built { ok = 1; exit }
  END { exit ok ? 0 : 1 }
' "$NFT_UC" || fail "nft rebuild must hold the guard before deleting the table and release it only once built"
awk '
  /^function restore_emergency_runtime\(\)/ { f = 1 }
  f && /kill_switch\.release\(\)/ { ok = 1; exit }
  f && /^}/ { exit }
  END { exit ok ? 0 : 1 }
' "$TACHYON_LIB/service/watchdog.uc" || fail "a chosen direct bypass must open the kill-switch gate"
grep -Fq 'require("service.kill_switch").boot()' "$HOTPLUG" ||
  fail "WAN ifup must engage the guard before Tachyon starts"
printf 'fail-closed kill-switch tests passed\n'
