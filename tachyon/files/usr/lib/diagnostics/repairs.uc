#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let common = require("core.common");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TACHYON_CONFIG = getenv("TACHYON_CONFIG") || constants.TACHYON_CONFIG || "/etc/config/" + CONFIG_NAME;
const UCI_BACKUP_DIR = "/etc/backup";
const UCI_BACKUP_PATH = UCI_BACKUP_DIR + "/tachyon_config";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let object_or_empty = common.object_or_empty;
let read_json_file = common.read_json_file;

const DOCTOR_FIXES_FILE = "/tmp/tachyon_doctor_fixes.json";

function doctor_fix_record(code) {
    let data = object_or_empty(read_json_file(DOCTOR_FIXES_FILE));
    let rec = data[code] || { count: 0, last: 0 };
    rec.count = int(rec.count) + 1;
    rec.last = time();
    data[code] = rec;
    let tmp_path = DOCTOR_FIXES_FILE + ".tmp." + int(clock()[0]);
    let f = fs.open(tmp_path, "w");
    if (f) {
        f.write(sprintf("%J\n", data));
        f.close();
        fs.rename(tmp_path, DOCTOR_FIXES_FILE);
    }
}

function doctor_fix_overused(code) {
    let data = object_or_empty(read_json_file(DOCTOR_FIXES_FILE));
    let rec = data[code];
    if (!rec) return false;
    let one_hour_ago = time() - 3600;
    return (int(rec.count) >= 3 && int(rec.last) > one_hour_ago);
}

function active_engine_name() {
    let engine = uci_core.get(CONFIG_NAME, "settings", "engine");
    return (engine != null && engine != "") ? as_string(engine) : "sing-box";
}

function active_engine_is_steer() {
    let name = active_engine_name();
    return name == "steer" || name == "steer-extended";
}

function uci_backup_save() {
    try {
        let data = fs.readfile(TACHYON_CONFIG);
        if (data == null || data == "") return false;
        fs.mkdir(UCI_BACKUP_DIR);
        let tmp = UCI_BACKUP_PATH + ".tmp";
        if (fs.writefile(tmp, data) == null) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        if (!fs.rename(tmp, UCI_BACKUP_PATH)) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        return true;
    } catch (e) { return false; }
}

function uci_backup_restore() {
    try {
        let data = fs.readfile(UCI_BACKUP_PATH);
        if (data == null || data == "") return false;
        let tmp = TACHYON_CONFIG + ".tmp";
        if (fs.writefile(tmp, data) == null) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        if (!fs.rename(tmp, TACHYON_CONFIG)) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        return true;
    } catch (e) { return false; }
}

function neutralize_zapret_defaults() {
    command_status("logger -t tachyon '[info] Standalone zapret is not neutralized automatically; Tachyon uses /opt/zapret/nfq/nfqws as an external provider and manages only its own NFQUEUE range.'");
    return 0;
}

function apply_quick_fix(codes_str) {
    if (!codes_str || codes_str == "") {
        print(sprintf("%J\n", { success: false, error: "No fix code provided" }));
        return 1;
    }

    let codes = split(replace(codes_str, /[ \[\]"]/g, ""), ",");
    let results = [];
    let all_ok = true;

    for (let c in codes) {
        c = trim(c);
        if (c == "") continue;

        let status = false;
        let msg = "";

        if (c == "start_singbox" || c == "start_steer") {
            if (active_engine_is_steer()) {
                let rc = command_status("/etc/init.d/steer restart >/dev/null 2>&1");
                status = (rc == 0);
                msg = status ? "steer restarted" : "steer restart failed (exit " + rc + ")";
            } else {
                let rc = command_status("/usr/bin/tachyon restore_dnsmasq 2>/dev/null; /etc/init.d/sing-box restart >/dev/null 2>&1");
                status = (rc == 0);
                msg = status ? "sing-box restarted" : "sing-box restart failed (exit " + rc + ")";
            }
        } else if (c == "rebuild_rules") {
            let rc = command_status("/etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Firewall rules rebuilt" : "Firewall reload failed (exit " + rc + ")";
        } else if (c == "fix_dnsmasq") {
            let rc = command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "dnsmasq restarted" : "dnsmasq restart failed (exit " + rc + ")";
        } else if (c == "fix_resolv_symlink") {
            let rc = command_status("ln -sf /tmp/resolv.conf.auto /etc/resolv.conf 2>/dev/null || ln -sf /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf 2>/dev/null");
            status = (rc == 0);
            msg = status ? "resolv.conf symlink fixed" : "resolv.conf symlink fix failed (exit " + rc + ")";
        } else if (c == "start_watchdog") {
            let rc = command_status("/etc/init.d/tachyon restart >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Watchdog started" : "Watchdog start failed (exit " + rc + ")";
        } else if (c == "restart_singbox_dns" || c == "restart_steer_dns") {
            if (active_engine_is_steer()) {
                command_status("/etc/init.d/steer reload_dnsd >/dev/null 2>&1");
                let rc = command_status("/etc/init.d/dnsmasq reload >/dev/null 2>&1");
                status = (rc == 0);
                msg = status ? "steer dnsd and dnsmasq reloaded" : "reload failed";
            } else {
                let rc = command_status("/etc/init.d/sing-box restart >/dev/null 2>&1");
                status = (rc == 0);
                msg = status ? "sing-box DNS restarted" : "sing-box DNS restart failed (exit " + rc + ")";
            }
        } else if (c == "fix_uci_config") {
            status = uci_backup_restore();
            if (!status) {
                status = command_status("cp /etc/config/tachyon.bak /etc/config/tachyon 2>/dev/null") == 0;
            }
            msg = status ? "UCI config restored from backup" : "UCI config restore failed (no valid backup found)";
        } else if (c == "fix_wan_interface") {
            let rc = command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
            status = (rc == 0);
            msg = status ? "WAN interface re-up triggered" : "WAN interface re-up failed (exit " + rc + ")";
        } else if (c == "fix_gateway") {
            let rc = command_status("/etc/init.d/network restart >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Network restarted to resolve gateway" : "Network restart failed (exit " + rc + ")";
        } else if (c == "clear_dns_cache") {
            let rc = command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1; ip route flush cache 2>/dev/null");
            status = (rc == 0);
            msg = status ? "DNS cache cleared and dnsmasq restarted" : "DNS cache clear failed (exit " + rc + ")";
        } else if (c == "update_subscriptions") {
            let rc = command_status(command_from_args([ "/usr/bin/tachyon", "component_action_async", "update_subscriptions", "update" ]));
            status = (rc == 0);
            msg = status ? "Subscription update triggered" : "Subscription update trigger failed (exit " + rc + ")";
        } else if (c == "reset_firewall") {
            let rc = command_status("/etc/init.d/firewall restart >/dev/null 2>&1; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Firewall restarted" : "Firewall restart failed (exit " + rc + ")";
        } else if (c == "restart_network") {
            let rc = command_status("/etc/init.d/network restart >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Network service restarted" : "Network restart failed (exit " + rc + ")";
        } else if (c == "restart_zapret") {
            let rc = command_status("/etc/init.d/zapret stop >/dev/null 2>&1; /etc/init.d/zapret disable >/dev/null 2>&1; /etc/init.d/zapret2 stop >/dev/null 2>&1; /etc/init.d/zapret2 disable >/dev/null 2>&1; /etc/init.d/byedpi stop >/dev/null 2>&1; /etc/init.d/byedpi disable >/dev/null 2>&1; ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/zapret/runtime.uc start-runtime >/dev/null 2>&1; ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/zapret2/runtime.uc start-runtime >/dev/null 2>&1; ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/byedpi/runtime.uc start-runtime >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Zapret/ByeDPI standalone services stopped and Tachyon engines restarted" : "Zapret/ByeDPI restart failed (exit " + rc + ")";
        } else if (c == "optimize_memory") {
            let rc = command_status("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; rm -rf /tmp/sing-box/*.tmp 2>/dev/null; /etc/init.d/sing-box restart >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Memory caches flushed and sing-box restarted" : "Memory optimization failed (exit " + rc + ")";
        } else if (c == "switch_to_doh") {
            let rc = command_status("uci set tachyon.settings.dns_type='doh'; uci commit tachyon; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Switched DNS mode to DoH and reloaded firewall" : "DoH switch failed (exit " + rc + ")";
        } else if (c == "heal_network_stack") {
            let rc = command_status("ln -sf /tmp/resolv.conf /etc/resolv.conf 2>/dev/null; /etc/init.d/dnsmasq restart >/dev/null 2>&1; /etc/init.d/tachyon restart >/dev/null 2>&1; ip route flush cache 2>/dev/null; ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null");
            status = (rc == 0);
            msg = status ? "Full network stack recovery executed" : "Network stack recovery failed (exit " + rc + ")";
        } else if (c == "enable_safe_bypass") {
            let rc = command_status("uci set tachyon.settings.recovery_bypass='1'; uci commit tachyon; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Safe Direct WAN bypass enabled" : "Safe bypass enable failed (exit " + rc + ")";
        } else if (c == "restore_native_internet") {
            let rc = command_status("/usr/bin/tachyon restore_dnsmasq 2>/dev/null; /etc/init.d/tachyon stop >/dev/null 2>&1; nft delete table inet TachyonTable 2>/dev/null; ip -4 rule del fwmark 0x04000000/0x04000000 table tachyon 2>/dev/null; ip -6 rule del fwmark 0x04000000/0x04000000 table tachyon 2>/dev/null; ip route flush table tachyon 2>/dev/null; /etc/init.d/dnsmasq restart >/dev/null 2>&1; ip route flush cache 2>/dev/null");
            status = (rc == 0);
            msg = status ? "Tachyon stopped, stock dnsmasq and native direct internet routing restored" : "Native internet restore failed (exit " + rc + ")";
        } else if (c == "fix_system_time") {
            let rc = command_status("ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 162.159.200.1 2>/dev/null || ntpd -q -p pool.ntp.org 2>/dev/null || rdate -s time.cloudflare.com 2>/dev/null; /etc/init.d/sysntpd restart 2>/dev/null");
            status = (rc == 0);
            msg = status ? "System time synchronized with NTP" : "NTP sync failed (exit " + rc + ")";
        } else if (c == "flush_conntrack") {
            let rc = command_status("sysctl -w net.netfilter.nf_conntrack_max=65536 2>/dev/null; echo 1 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true; conntrack -F 2>/dev/null || true");
            status = (rc == 0);
            msg = status ? "Conntrack table limits expanded and flushed" : "Conntrack flush failed (exit " + rc + ")";
        } else if (c == "fix_bootstrap_dns") {
            let rc = command_status("uci set tachyon.settings.bootstrap_dns_server='77.88.8.8'; uci commit tachyon; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "Bootstrap DNS reset to reliable public resolver (77.88.8.8) and reloaded" : "Bootstrap DNS fix failed (exit " + rc + ")";
        } else if (c == "restart_providers") {
            let rc = command_status("ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/wdtt/runtime.uc start-runtime >/dev/null 2>&1; ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/olcrtc/runtime.uc start-runtime >/dev/null 2>&1; ucode -L " + LIB_DIR + " " + LIB_DIR + "/providers/fptn/runtime.uc start-runtime >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "WDTT/OLCRTC/FPTN provider runtimes restarted" : "Provider runtimes restart failed (exit " + rc + ")";
        } else if (c == "optimize_mtu") {
            let rc = command_status("/usr/bin/tachyon discover-awg-mtu 2>/dev/null; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = (rc == 0);
            msg = status ? "AWG MTU discovery executed and tunnels reloaded" : "MTU optimization failed (exit " + rc + ")";
        } else if (c == "upgrade_to_singbox_extended") {
            let rc = command_status(command_from_args([ "/usr/bin/tachyon", "component_action_async", "sing_box", "install_extended" ]));
            status = (rc == 0);
            msg = status ? "Sing-box Extended upgrade initiated" : "Sing-box Extended upgrade trigger failed (exit " + rc + ")";
        } else {
            status = false;
            msg = "Unknown fix code: " + c;
            all_ok = false;
        }

        push(results, { code: c, success: status, message: msg });
        doctor_fix_record(c);
    }

    let doctor_mod = require("diagnostics.doctor");
    let post_verify = doctor_mod.verify_system();

    print(sprintf("%J\n", {
        success: all_ok,
        verified: post_verify.failed == 0,
        remaining_failures: post_verify.failed,
        results: results
    }));
    return all_ok ? 0 : 1;
}

return {
    uci_backup_save,
    uci_backup_restore,
    neutralize_zapret_defaults,
    doctor_fix_record,
    doctor_fix_overused,
    apply_quick_fix
};
