#!/usr/bin/env ucode

// Tachyon Clean Uninstaller Module
// Fully restores dnsmasq / dhcp, flushes nftables & policy routing,
// removes Tachyon packages & crontab hooks, restores Forkop/Podkop if present,
// and safely uninstalls Tachyon without leaving lingering state on OpenWrt.

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;

function run_cmd(args) {
    let parts = [];
    for (let arg in args)
        push(parts, "'" + replace(as_string(arg), /'/g, "'\\''") + "'");
    return system(join(" ", parts) + " >/dev/null 2>&1");
}

function run_shell(cmd) {
    return system(cmd + " >/dev/null 2>&1");
}

function log_step(msg) {
    print("[Tachyon Uninstall] ", msg, "\n");
}

function remove_file(path) {
    if (fs.stat(path) != null)
        fs.unlink(path);
}

function remove_tree(path) {
    if (fs.stat(path) != null)
        run_shell("rm -rf '" + replace(as_string(path), /'/g, "'\\''") + "'");
}

function clean_managed_sing_box(keep_binaries) {
    if (fs.stat("/etc/init.d/sing-box") != null) {
        let content = fs.readfile("/etc/init.d/sing-box");
        if (content && index(content, "Tachyon managed sing-box") >= 0) {
            run_cmd(["/etc/init.d/sing-box", "stop"]);
            run_cmd(["/etc/init.d/sing-box", "disable"]);
            remove_file("/etc/init.d/sing-box");
            run_shell("rm -f /etc/rc.d/*sing-box* 2>/dev/null || true");
        }
    }

    if (!keep_binaries) {
        if (fs.stat("/bin/opkg") != null || fs.stat("/usr/bin/opkg") != null) {
            for (let pkg in [ "sing-box-extended", "sing-box-tiny" ]) {
                let check = system("opkg list-installed '" + pkg + "' 2>/dev/null | grep -q '^" + pkg + " '");
                if (check == 0)
                    run_cmd(["opkg", "remove", "--force-depends", "--force-remove", pkg]);
            }
            if (fs.stat("/etc/init.d/sing-box") == null) {
                let check_sb = system("opkg list-installed 'sing-box' 2>/dev/null | grep -q '^sing-box '");
                if (check_sb == 0)
                    run_cmd(["opkg", "remove", "--force-depends", "--force-remove", "sing-box"]);
                remove_file("/usr/bin/sing-box");
            }
        }
        remove_file("/usr/lib/libcronet.so");
    }
}

function clean_rt_tables() {
    let rt_path = "/etc/iproute2/rt_tables";
    if (fs.stat(rt_path) == null)
        return;

    let content = fs.readfile(rt_path);
    if (!content || index(content, "tachyon") < 0)
        return;

    let lines = split(content, "\n");
    let clean = [];
    for (let line in lines) {
        if (match(line, /105\s+tachyon/) || match(line, /^\s*\d+\s+tachyon\s*$/))
            continue;
        push(clean, line);
    }
    fs.writefile(rt_path, join("\n", clean) + "\n");
}

function clean_crontab() {
    run_shell("crontab -l 2>/dev/null | grep -v -E 'tachyon|parental_quota_tick' | crontab - 2>/dev/null || true");
}

function restore_dhcp_dns() {
    let uci_core = null;
    try {
        uci_core = require("core.uci");
    } catch (e) {}

    if (uci_core != null) {
        try {
            // Remove 127.0.0.42 from server list
            let servers = uci_core.get("dhcp", "@dnsmasq[0]", "server");
            if (servers != null) {
                let s_list = type(servers) == "array" ? servers : [ servers ];
                let clean_servers = [];
                for (let s in s_list) {
                    s = as_string(s);
                    if (s != "127.0.0.42" && substr(s, 0, 13) != "127.0.0.42#")
                        push(clean_servers, s);
                }
                uci_core.delete("dhcp", "@dnsmasq[0]", "server");
                for (let s in clean_servers)
                    uci_core.add_list("dhcp", "@dnsmasq[0]", "server", s);
            }

            // Restore original server backup if saved
            let backup_servers = uci_core.get("dhcp", "@dnsmasq[0]", "tachyon_server");
            if (backup_servers != null && backup_servers != "") {
                uci_core.delete("dhcp", "@dnsmasq[0]", "server");
                let list = type(backup_servers) == "array" ? backup_servers : split(trim(backup_servers), /[ \t\r\n]+/);
                for (let s in list)
                    if (s != "")
                        uci_core.add_list("dhcp", "@dnsmasq[0]", "server", s);
                uci_core.delete("dhcp", "@dnsmasq[0]", "tachyon_server");
            }

            // Restore backed up options
            for (let opt in [ "noresolv", "cachesize", "rebind_protection", "localuse", "addn_hosts", "notinterface" ]) {
                let val = uci_core.get("dhcp", "@dnsmasq[0]", "tachyon_" + opt);
                if (val != null && val != "") {
                    uci_core.set("dhcp", "@dnsmasq[0]", opt, val);
                    uci_core.delete("dhcp", "@dnsmasq[0]", "tachyon_" + opt);
                }
            }

            // Failsafe sensible defaults
            if (uci_core.get("dhcp", "@dnsmasq[0]", "noresolv") == "1")
                uci_core.set("dhcp", "@dnsmasq[0]", "noresolv", "0");
            if (uci_core.get("dhcp", "@dnsmasq[0]", "cachesize") == "0")
                uci_core.set("dhcp", "@dnsmasq[0]", "cachesize", "150");

            uci_core.delete("dhcp", "tachyon");
            uci_core.commit("dhcp");
        } catch (e) {}
    } else {
        run_shell("uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.42' 2>/dev/null || true");
        run_shell("uci -q set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true");
        run_shell("uci -q set dhcp.@dnsmasq[0].cachesize='150' 2>/dev/null || true");
        run_shell("uci -q delete dhcp.tachyon 2>/dev/null || true");
        run_shell("uci -q commit dhcp 2>/dev/null || true");
    }

    remove_file("/etc/dnsmasq.d/tachyon.conf");
    remove_file("/tmp/dnsmasq.d/tachyon.conf");
    run_shell("rm -f /etc/dnsmasq.d/tachyon*.conf /tmp/dnsmasq.d/tachyon*.conf 2>/dev/null || true");

    if (fs.stat("/etc/init.d/dnsmasq") != null)
        run_cmd(["/etc/init.d/dnsmasq", "restart"]);
}

function clean_firewall_and_routing() {
    run_cmd(["nft", "delete", "table", "inet", "TachyonTable"]);
    run_cmd(["nft", "delete", "table", "inet", "tachyon"]);
    run_cmd(["nft", "delete", "table", "ip", "tachyon"]);
    run_cmd(["nft", "delete", "table", "ip6", "tachyon"]);
    remove_file("/usr/share/nftables.d/chain-pre/input/10-tachyon.nft");

    // Restart firewall to purge in-memory dynamic rules from inet fw4
    if (fs.stat("/etc/init.d/firewall") != null)
        run_cmd(["/etc/init.d/firewall", "restart"]);

    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x04000000/0x04000000", "table", "tachyon", "priority", "105"]);
    run_cmd(["ip", "-6", "rule", "del", "fwmark", "0x04000000/0x04000000", "table", "tachyon", "priority", "105"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x10000000/0x10000000", "lookup", "100"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x1/0x1", "lookup", "100"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x2/0x2", "lookup", "100"]);
    run_cmd(["ip", "route", "flush", "table", "tachyon"]);
    run_cmd(["ip", "route", "flush", "table", "105"]);
    run_cmd(["ip", "route", "flush", "table", "100"]);
    clean_rt_tables();

    // Clean network namespaces
    run_cmd(["ip", "netns", "del", "fkpsc"]);
    run_cmd(["ip", "link", "del", "fkpsc0"]);
    remove_tree("/etc/netns/fkpsc");
}

function uninstall_tachyon(purge_config, keep_binaries) {
    log_step("Stopping and disabling Tachyon service...");
    remove_file("/var/run/tachyon/starting");
    remove_file("/var/run/tachyon/reloading");
    run_shell("rm -f /var/run/tachyon*.lock 2>/dev/null || true");

    if (fs.stat("/etc/init.d/tachyon") != null) {
        run_cmd(["/etc/init.d/tachyon", "stop"]);
        run_cmd(["/etc/init.d/tachyon", "disable"]);
    }

    clean_managed_sing_box(keep_binaries);

    // Stop proxy and desync processes
    run_shell("killall sing-box nfqws nfqws2 ciadpi 2>/dev/null || true");
    // Stop background daemons safely (excluding self PID)
    run_shell("ps 2>/dev/null | grep -E 'dns_failover|watchdog|telegram' | grep -v grep | awk '{print $1}' | while read _pid; do [ \"$_pid\" != \"$$\" ] && kill -9 \"$_pid\" 2>/dev/null; done; true");

    log_step("Cleaning up firewall, nftables and routing rules...");
    clean_firewall_and_routing();

    log_step("Restoring DNS and dnsmasq configuration...");
    restore_dhcp_dns();

    log_step("Cleaning crontab jobs...");
    clean_crontab();

    log_step("Cleaning auxiliary files and hooks...");
    remove_file("/etc/hotplug.d/iface/99-tachyon-wan-monitor");
    remove_file("/www/cgi-bin/tachyon-agent");
    remove_file("/usr/lib/cgi-bin/tachyon-agent");
    remove_file("/usr/bin/tachyon");
    remove_file("/etc/init.d/tachyon");
    remove_file("/etc/tachyon_commit");
    remove_file("/etc/uci-defaults/50_luci-tachyon");

    remove_tree("/var/run/tachyon");
    run_shell("rm -rf /var/run/tachyon* /var/log/tachyon* /tmp/tachyon* /tmp/sing-box /tmp/ai_doctor* /tmp/tg_* /tmp/warp_* 2>/dev/null || true");

    if (purge_config) {
        log_step("Purging Tachyon configuration and state (--purge)...");
        run_shell("rm -rf /etc/config/tachyon* /etc/tachyon /etc/.tachyon /etc/backup/tachyon_config /etc/sing-box 2>/dev/null || true");
    } else {
        log_step("Backing up Tachyon configuration...");
        let ts = clock()[0];
        run_shell("cp -af /etc/config/tachyon /etc/config/tachyon.backup-" + ts + " 2>/dev/null || true");
        run_shell("cp -af /etc/config/tachyon /etc/config/tachyon.bak 2>/dev/null || true");
        run_shell("chmod 600 /etc/config/tachyon.backup-* /etc/config/tachyon.bak 2>/dev/null || true");
    }

    log_step("Removing Tachyon packages...");
    if (fs.stat("/bin/opkg") != null || fs.stat("/usr/bin/opkg") != null) {
        run_cmd(["opkg", "remove", "--force-depends", "--force-remove", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
    } else if (fs.stat("/sbin/apk") != null || fs.stat("/usr/sbin/apk") != null) {
        run_cmd(["apk", "del", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
    }

    // Clean translations and LuCI views
    run_shell("rm -rf /usr/lib/tachyon /usr/share/tachyon /www/luci-static/resources/view/tachyon /usr/share/luci/menu.d/luci-app-tachyon.json /usr/share/rpcd/acl.d/luci-app-tachyon.json /usr/lib/lua/luci/i18n/tachyon.* 2>/dev/null || true");

    // Clear LuCI cache and restart rpcd/uhttpd
    run_shell("rm -f /var/luci-indexcache* /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true");
    if (fs.stat("/etc/init.d/rpcd") != null)
        run_cmd(["/etc/init.d/rpcd", "restart"]);
    if (fs.stat("/etc/init.d/uhttpd") != null)
        run_cmd(["/etc/init.d/uhttpd", "restart"]);

    // Restore parent Forkop / Podkop / NetShift services if present
    if (fs.stat("/etc/init.d/forkop") != null) {
        log_step("Forkop detected! Restoring Forkop service...");
        run_cmd(["/etc/init.d/forkop", "enable"]);
        run_cmd(["/etc/init.d/forkop", "restart"]);
    } else if (fs.stat("/etc/init.d/podkop") != null) {
        log_step("Podkop detected! Restoring Podkop service...");
        run_cmd(["/etc/init.d/podkop", "enable"]);
        run_cmd(["/etc/init.d/podkop", "restart"]);
    } else if (fs.stat("/etc/init.d/netshift") != null) {
        log_step("NetShift detected! Restoring NetShift service...");
        run_cmd(["/etc/init.d/netshift", "enable"]);
        run_cmd(["/etc/init.d/netshift", "restart"]);
    }

    log_step("Tachyon has been successfully uninstalled.");
    return 0;
}

let purge = false;
let keep_bin = false;
for (let i = 0; i < length(ARGV); i++) {
    let arg = as_string(ARGV[i]);
    if (arg == "--purge" || arg == "-p")
        purge = true;
    if (arg == "--keep-binaries")
        keep_bin = true;
}

exit(uninstall_tachyon(purge, keep_bin));
