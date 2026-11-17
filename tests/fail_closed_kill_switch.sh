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

check(type(ks.stop_hold) == "function" && type(ks.dns_veto) == "function", "Stop/DNS kill-switch helpers missing");

// dns_intercept_all: on by default with Fail-Closed, but always the user's to turn off.
check(ks.dns_intercept_mode({}) == "auto" && ks.dns_intercept_mode({ dns_intercept_all: "auto" }) == "auto",
    "Missing dns_intercept_all is not auto");
check(ks.dns_intercept_mode({ dns_intercept_all: "1" }) == "on" && ks.dns_intercept_mode({ dns_intercept_all: "0" }) == "off",
    "Explicit dns_intercept_all values are not honoured");
check(ks.dns_intercept_effective({}, true) && !ks.dns_intercept_effective({}, false),
    "auto does not follow Fail-Closed");
check(!ks.dns_intercept_effective({ dns_intercept_all: "0" }, true),
    "An explicit off was overridden by Fail-Closed (clients could not use their own DNS)");
check(ks.dns_intercept_effective({ dns_intercept_all: "1" }, false), "An explicit on was ignored");
// TUN guard: only TUN + Fail-Closed + enabled service; never in tproxy mode,
// where the rules would cut the LAN off instead of guarding it.
let tun = { proxy_mode: "tun", source_network_interfaces: [ "br-lan", "br-guest" ] };
let tun_rules = map(ks.tun_guard_rules(tun, [ blocked ], true), (r) => join(" ", r));
check(length(tun_rules) == 12, "TUN guard needs 3 rules x 2 families x 2 interfaces, got " + length(tun_rules));
check(index(tun_rules, "-4 rule add iif br-lan fwmark 0x2022 lookup main pref 9499") >= 0 &&
      index(tun_rules, "-4 rule add iif br-lan lookup main suppress_prefixlength 0 pref 9500") >= 0 &&
      index(tun_rules, "-4 rule add iif br-lan unreachable pref 9501") >= 0 &&
      index(tun_rules, "-6 rule add iif br-guest unreachable pref 9501") >= 0,
    "TUN guard does not leave LAN without a default route when the core is gone");
check(length(ks.tun_guard_rules(tun, [ { fail_policy: "keep" } ], true)) == 0, "TUN guard without Fail-Closed");
check(length(ks.tun_guard_rules({ proxy_mode: "tproxy" }, [ blocked ], true)) == 0, "TUN guard in tproxy mode");
check(length(ks.tun_guard_rules({}, [ blocked ], true)) == 0, "TUN guard with the default (tproxy) mode");
check(length(ks.tun_guard_rules(tun, [ blocked ], false)) == 0, "TUN guard while the service is disabled");
tun.tun_kill_switch = "0";
check(length(ks.tun_guard_rules(tun, [ blocked ], true)) == 0, "TUN guard ignores tun_kill_switch=0");
let rs = ks.ruleset([ "br-lan", "br-guest" ]);
check(index(rs, "table inet " + ks.GUARD_TABLE + " {") >= 0, "Guard does not own a separate table");
check(index(rs, "set " + ks.GATE_SET + " {") >= 0 && index(rs, "type ifname") >= 0, "Guard has no interface gate set");
check(index(rs, "hook forward") >= 0, "Guard is not on the forward hook");
check(index(rs, "iifname { \"br-lan\", \"br-guest\" } oifname != { \"br-lan\", \"br-guest\" } iifname != @" + ks.GATE_SET + " counter drop") >= 0,
    "Guard does not drop LAN traffic leaving the LAN while the gate is closed");
check(index(rs, "hook input") >= 0 && index(rs, "th dport { 53, 853 } iifname != @" + ks.GATE_SET + " counter drop") >= 0,
    "A closed gate does not shut LAN clients out of the router DNS");
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
# Stop is also what package upgrades, tachyon-core updates and the installer
# run: it must hold the gate and decide before any DNS rollback, never open it.
awk '
  /^function stop_impl\(\)/ { f = 1 }
  f && /kill_switch\.release\(\)/ { bad = 1 }
  f && /dnsmasq_restore\(/ && !hold { bad = 1 }
  f && /kill_switch\.stop_hold\(\)/ { hold = 1 }
  f && /stop_main\(\);/ { ok = hold; exit }
  END { exit (ok && !bad) ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "stop must hold the kill-switch before rolling DNS back or dropping interception"
awk '
  /^function uninstall\(\)/ { f = 1 }
  f && /kill_switch\.remove\(\)/ { ok = 1; exit }
  f && /^}/ { exit }
  END { exit ok ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "uninstall must remove the kill-switch"
awk '
  /^function failsafe_restore\(\)/ { f = 1 }
  f && /kill_switch\.dns_veto\(\)/ { veto = 1 }
  f && /dnsmasq_restore\(/ { ok = veto; exit }
  END { exit ok ? 0 : 1 }
' "$TACHYON_LIB/dns/apply.uc" || fail "every automatic DNS rollback must respect Fail-Closed"
[[ "$(grep -c 'require("service.kill_switch").hold();' "$TACHYON_LIB/diagnostics/doctor.uc")" -ge 2 ]] ||
  fail "doctor must hold the kill-switch before deleting the interception table"
awk '
  /^function nft_rebuild_runtime_from_uci\(/ { f = 1 }
  f && /kill_switch\.hold\(\)/ { hold = 1 }
  f && /nft_delete_table\(table\)/ && !hold { exit }
  f && /if \(built\)/ && hold { built = 1 }
  f && /kill_switch\.release_if_ready\(\)/ && built { ok = 1; exit }
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
# The fw4 include is written at runtime, so no package owns it: every removal
# path must delete it, or fw4 recreates a closed gate at each boot with nothing
# left to open it.
INCLUDE='/usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft'
[[ "$(grep -cF "$INCLUDE" "$ROOT_DIR/build.sh")" -ge 2 ]] || fail "build.sh removal hooks must delete the kill-switch include"
for f in "$ROOT_DIR/tachyon/Makefile" "$ROOT_DIR/uninstall.sh" "$TACHYON_LIB/service/uninstall.uc"; do
  grep -Fq "$INCLUDE" "$f" || fail "${f##*/} must delete the kill-switch include"
done
# The router keeps a resolver while the gate is closed (LAN DNS is shut out
# by the gate itself); only an open gate keeps DNS on the proxy.
grep -Fq 'if (reason == "" || engaged())' "$TACHYON_LIB/service/kill_switch.uc" ||
  fail "a closed gate must let the router itself resolve over WAN"
# Start rebuilds nft before DNS is back on the proxy: the gate may open only after.
awk '
  /^function start_impl\(\)/ { f = 1 }
  f && /dnsmasq_configure\(true\)/ { dns = 1 }
  f && /kill_switch\.release_if_ready\(\)/ { ok = dns; exit }
  END { exit ok ? 0 : 1 }
' "$LIFECYCLE_UC" || fail "start must open the gate only after DNS is back on the proxy"
printf 'fail-closed kill-switch tests passed\n'
