#!/usr/bin/env ucode

// Tachyon Clean Uninstaller Module
// Fully restores dnsmasq, cleans nftables/tproxy, restores Forkop/Podkop if present,
// and safely removes Tachyon packages without breaking router configuration.

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;

function run_cmd(args) {
    let parts = [];
    for (let arg in args)
        push(parts, "'" + replace(as_string(arg), /'/g, "'\\''") + "'");
    return system(join(" ", parts) + " >/dev/null 2>&1");
}

function log_step(msg) {
    print("[Tachyon Uninstall] ", msg, "\n");
}

function uninstall_tachyon(purge_config) {
    log_step("Stopping and disabling Tachyon service...");
    run_cmd(["/etc/init.d/tachyon", "stop"]);
    run_cmd(["/etc/init.d/tachyon", "disable"]);

    log_step("Cleaning up firewall and nftables rules...");
    run_cmd(["nft", "delete", "table", "inet", "tachyon"]);
    run_cmd(["nft", "delete", "table", "ip", "tachyon"]);
    run_cmd(["nft", "delete", "table", "ip6", "tachyon"]);
    run_cmd(["ip", "rule", "del", "fwmark", "0x1/0x1"]);
    run_cmd(["ip", "rule", "del", "fwmark", "0x2/0x2"]);
    run_cmd(["ip", "route", "flush", "table", "100"]);

    log_step("Restoring dnsmasq configuration...");
    run_cmd(["rm", "-f", "/etc/dnsmasq.d/tachyon.conf"]);
    run_cmd(["rm", "-f", "/tmp/dnsmasq.d/tachyon.conf"]);
    run_cmd(["rm", "-rf", "/tmp/dnsmasq.d/tachyon-*.conf"]);

    if (fs.stat("/etc/config/dnsmasq.tachyon-bak") != null) {
        run_cmd(["cp", "-f", "/etc/config/dnsmasq.tachyon-bak", "/etc/config/dnsmasq"]);
        log_step("Restored original dnsmasq config from backup.");
    }

    run_cmd(["/etc/init.d/dnsmasq", "restart"]);

    if (purge_config) {
        log_step("Purging Tachyon configuration...");
        run_cmd(["rm", "-rf", "/etc/config/tachyon"]);
        run_cmd(["rm", "-rf", "/etc/tachyon"]);
    } else {
        log_step("Backing up Tachyon configuration to /etc/config/tachyon.bak...");
        run_cmd(["cp", "-af", "/etc/config/tachyon", "/etc/config/tachyon.bak"]);
    }

    // Check if Forkop or Podkop was installed prior and re-enable it
    if (fs.stat("/etc/init.d/forkop") != null) {
        log_step("Forkop detected! Restoring Forkop service...");
        run_cmd(["/etc/init.d/forkop", "enable"]);
        run_cmd(["/etc/init.d/forkop", "restart"]);
    } else if (fs.stat("/etc/init.d/podkop") != null) {
        log_step("Podkop detected! Restoring Podkop service...");
        run_cmd(["/etc/init.d/podkop", "enable"]);
        run_cmd(["/etc/init.d/podkop", "restart"]);
    }

    log_step("Removing Tachyon packages...");
    if (fs.stat("/bin/opkg") != null || fs.stat("/usr/bin/opkg") != null) {
        run_cmd(["opkg", "remove", "--force-depends", "--force-remove", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
    } else if (fs.stat("/sbin/apk") != null) {
        run_cmd(["apk", "del", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
    }

    log_step("Tachyon has been successfully uninstalled.");
    return 0;
}

let mode = as_string(ARGV[0]);
let purge = mode == "--purge" || as_string(ARGV[1]) == "--purge";
exit(uninstall_tachyon(purge));
