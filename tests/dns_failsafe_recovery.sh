#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
awk '/^let mode = ARGV\[0\]/{exit} {print}' \
  "$TACHYON_LIB/dns/apply.uc" >"$WORK_DIR/probe.uc"
cat >>"$WORK_DIR/probe.uc" <<'UC'
let opts = {};
let dns_listener = false;
let dns_config = false;
let resolves = false;
let adguard = false;
let restore_ok = false;
uci_available = function() { return true; };
uci_get = function(path) { return opts[path] || ""; };
log = function(message, level) {};
dnsmasq_has_tachyon_managed_state = function() { return true; };
dnsmasq_has_tachyon_dns = function() { return dns_config; };
dnsmasq_restore = function(force, quiet) { return restore_ok; };
sing_box_dns_listening = function() { return dns_listener; };
dnsmasq_default_config_is_complete = function() { return dns_config; };
common.command_success_from_args = function(args) { return resolves; };
run = function(cmd) { return adguard; };
function check(ok, message) { if (!ok) die(message + "\n"); }
check(!failsafe_restore(), "Failed DNS rollback was silently reported successful");
restore_ok = true;
check(failsafe_restore(), "Successful DNS rollback was rejected");
check(!recovery_ready(), "Missing DNS listener/config accepted");
dns_listener = true;
check(!recovery_ready(), "Missing managed DNS config accepted");
dns_config = true;
check(!recovery_ready(), "Failed DNS resolution accepted");
resolves = true;
check(recovery_ready(), "Healthy managed DNS rejected");
opts[CONFIG_NAME + ".settings.dont_touch_dhcp"] = "1";
dns_listener = false; dns_config = false; resolves = false;
check(recovery_ready(), "Recovery tried to manage explicitly external DNS");
opts = { "dhcp.@dnsmasq[0].port": "0" };
adguard = true;
check(recovery_ready(), "Recovery tried to replace AdGuard DNS");
adguard = false;
check(!recovery_ready(), "Port zero without AdGuard accepted as a DNS recovery");
print("DNS failsafe recovery tests passed\n");
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
