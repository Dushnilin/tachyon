#!/usr/bin/env ucode

// Tachyon Clean Uninstaller Module
// Fully restores dnsmasq / dhcp, flushes nftables & policy routing,
// removes Tachyon packages & crontab hooks, and safely uninstalls Tachyon
// without leaving lingering state on OpenWrt.
// External legacy components (zapret, byedpi, sing-box, etc.) are only
// removed when a Tachyon-managed marker proves Tachyon installed them;
// standalone user installs are backed up and left intact.

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

const EXTERNAL_BACKUP_DIR = "/etc/tachyon/external-configs-backup";

function backup_config_path(component, source_path) {
    let dest_dir = EXTERNAL_BACKUP_DIR + "/" + as_string(component);
    if (fs.stat(source_path) == null)
        return;

    run_cmd(["mkdir", "-p", dest_dir]);
    // Preserve directory structure under dest_dir using the basename
    let basename = replace(as_string(source_path), /^.*\//, "");
    if (basename == "")
        return;

    let dest = dest_dir + "/" + basename;
    let src_stat = fs.stat(source_path);
    let dst_stat = fs.stat(dest);
    // Only copy if the destination does not already exist (non-destructive)
    if (dst_stat == null) {
        if (src_stat != null && as_string(src_stat.type || "") == "directory")
            run_shell("cp -a '" + replace(as_string(source_path), /'/g, "'\\''") + "' '" + replace(dest, /'/g, "'\\''") + "'");
        else
            run_cmd(["cp", "-a", source_path, dest]);
    }
}

function backup_external_configs() {
    // zapret
    backup_config_path("zapret", "/etc/config/zapret");
    for (let p in (fs.glob("/opt/zapret/config") || []))
        backup_config_path("zapret", p);
    for (let p in (fs.glob("/opt/zapret/init.d") || []))
        backup_config_path("zapret", p);
    for (let p in (fs.glob("/opt/zapret/ipset") || []))
        backup_config_path("zapret", p);

    // zapret2
    backup_config_path("zapret2", "/etc/config/zapret2");
    for (let p in (fs.glob("/opt/zapret2/config") || []))
        backup_config_path("zapret2", p);

    // byedpi
    backup_config_path("byedpi", "/etc/config/byedpi");
    for (let p in (fs.glob("/etc/byedpi*") || []))
        backup_config_path("byedpi", p);

    // wdtt
    backup_config_path("wdtt", "/etc/config/wdtt");
    backup_config_path("wdtt", "/etc/wdtt");

    // qwdtt
    backup_config_path("qwdtt", "/etc/config/qwdtt");
    backup_config_path("qwdtt", "/etc/qwdtt");

    // olcrtc
    backup_config_path("olcrtc", "/etc/config/olcrtc");
    backup_config_path("olcrtc", "/etc/olcrtc");

    // sing-box
    backup_config_path("sing-box", "/etc/config/sing-box");
    backup_config_path("sing-box", "/etc/sing-box");
}

function is_tachyon_managed_component(component) {
    component = as_string(component);

    // Check /etc/init.d/<component> for "Tachyon managed" marker
    let init_path = "/etc/init.d/" + component;
    let init_data = fs.readfile(init_path);
    if (init_data != null && index(init_data, "Tachyon managed") >= 0)
        return true;

    // Normalize component name for backup dir lookup
    let backup_name = replace(component, /-/g, "_");
    if (backup_name == "wdtt_client")
        backup_name = "wdtt";

    // Check /etc/tachyon/component-backups/<component>
    if (fs.stat("/etc/tachyon/component-backups/" + backup_name) != null)
        return true;

    // Check /var/run/tachyon/<component> supervisor directory
    if (fs.stat("/var/run/tachyon/" + backup_name) != null) {
        let st = fs.stat("/var/run/tachyon/" + backup_name);
        if (st != null && as_string(st.type || "") == "directory")
            return true;
    }

    return false;
}

function selective_cleanup_component(component, keep_binaries) {
    component = as_string(component);
    if (!is_tachyon_managed_component(component))
        return;

    let init_path = "/etc/init.d/" + component;
    if (fs.stat(init_path) != null) {
        run_cmd([init_path, "stop"]);
        run_cmd([init_path, "disable"]);
        remove_file(init_path);
    }
    run_shell("rm -f /etc/rc.d/*" + component + "* 2>/dev/null || true");
}

function clean_managed_core(keep_binaries) {
    if (fs.stat("/etc/init.d/tachyon-core") != null) {
        let content = fs.readfile("/etc/init.d/tachyon-core");
        if (content && (index(content, "Tachyon managed tachyon-core") >= 0 || index(content, "Tachyon managed sing-box") >= 0)) {
            run_cmd(["/etc/init.d/tachyon-core", "stop"]);
            run_cmd(["/etc/init.d/tachyon-core", "disable"]);
            remove_file("/etc/init.d/tachyon-core");
            run_shell("rm -f /etc/rc.d/*tachyon-core* 2>/dev/null || true");
        }
    }

    // Only clean sing-box if it was installed/managed by Tachyon
    let sing_box_managed = false;
    if (fs.stat("/etc/init.d/sing-box") != null) {
        let legacy_content = fs.readfile("/etc/init.d/sing-box");
        if (legacy_content && index(legacy_content, "Tachyon managed") >= 0) {
            sing_box_managed = true;
            run_cmd(["/etc/init.d/sing-box", "stop"]);
            run_cmd(["/etc/init.d/sing-box", "disable"]);
            remove_file("/etc/init.d/sing-box");
            run_shell("rm -f /etc/rc.d/*sing-box* 2>/dev/null || true");
        }
    }
    if (!sing_box_managed &&
        (fs.stat("/etc/tachyon/sing-box-version") != null ||
         fs.stat("/etc/tachyon/sing-box-variant") != null ||
         fs.stat("/etc/tachyon/component-backups/sing_box") != null))
        sing_box_managed = true;

    if (sing_box_managed)
        remove_tree("/etc/sing-box");

    if (!keep_binaries && sing_box_managed) {
        if (fs.stat("/bin/opkg") != null || fs.stat("/usr/bin/opkg") != null) {
            for (let pkg in [ "sing-box-extended", "sing-box-tiny" ]) {
                let check = system("opkg list-installed '" + pkg + "' 2>/dev/null | grep -q '^" + pkg + " '");
                if (check == 0)
                    run_cmd(["opkg", "remove", "--force-depends", "--force-remove", pkg]);
            }
            if (fs.stat("/etc/init.d/tachyon-core") == null) {
                let check_sb = system("opkg list-installed 'sing-box' 2>/dev/null | grep -q '^sing-box '");
                if (check_sb == 0)
                    run_cmd(["opkg", "remove", "--force-depends", "--force-remove", "sing-box"]);
            }
        }
    }
    if (!keep_binaries) {
        remove_file("/usr/bin/tachyon-core");
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
    if (fs.stat("/usr/lib/tachyon/dns/apply.uc") != null)
        run_cmd([ "ucode", "-L", "/usr/lib/tachyon", "/usr/lib/tachyon/dns/apply.uc", "odhcpd-restore" ]);

    let uci_core = null;
    try {
        uci_core = require("core.uci");
    } catch (e) {}

    if (uci_core != null) {
        try {
            // Release any leftover MagicDNS serversfile/localservice markers from older versions
            let dnsmasq_names = [];
            for (let s in (uci_core.sections("dhcp", "dnsmasq") || [])) {
                let name = type(s) == "object" ? as_string(s[".name"] || "") : as_string(s);
                if (name != "")
                    push(dnsmasq_names, name);
            }
            if (length(dnsmasq_names) == 0 && uci_core.get("dhcp", "@dnsmasq[0]", ".type") == "dnsmasq")
                push(dnsmasq_names, "@dnsmasq[0]");
            for (let name in dnsmasq_names) {
                let base = "dhcp." + name + ".";
                if (as_string(uci_core.get(base + "tachyon_serversfile")) != "") {
                    if (as_string(uci_core.get(base + "serversfile")) == "/etc/tachyon/dnsmasq-tailscale.servers")
                        uci_core.delete(base + "serversfile");
                    uci_core.delete(base + "tachyon_serversfile");
                }
                let saved_local = as_string(uci_core.get(base + "tachyon_localservice"));
                if (saved_local != "") {
                    if (as_string(uci_core.get(base + "localservice")) == "0") {
                        if (saved_local == "unset")
                            uci_core.delete(base + "localservice");
                        else
                            uci_core.set(base + "localservice", saved_local);
                    }
                    uci_core.delete(base + "tachyon_localservice");
                }
            }

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

            // Restore backed up odhcpd LAN options if dns/apply.uc did not already clean them up
            for (let opt in [ "ra", "dhcpv6", "ndp", "ra_dns", "ra_default" ]) {
                let val = uci_core.get("dhcp", "lan", "tachyon_lan_" + opt);
                if (val == "__absent__") {
                    uci_core.delete("dhcp", "lan", opt);
                } else if (val != null && val != "") {
                    uci_core.set("dhcp", "lan", opt, val);
                }
                uci_core.delete("dhcp", "lan", "tachyon_lan_" + opt);
            }
            let lan_dns = uci_core.get("dhcp", "lan", "tachyon_lan_dns");
            if (lan_dns != null) {
                uci_core.delete("dhcp", "lan", "dns");
                if (lan_dns != "__absent__") {
                    let list = type(lan_dns) == "array" ? lan_dns : split(trim(lan_dns), /[ \t\r\n]+/);
                    for (let d in list)
                        if (d != "")
                            uci_core.add_list("dhcp", "lan", "dns", d);
                }
                uci_core.delete("dhcp", "lan", "tachyon_lan_dns");
            }
            uci_core.delete("dhcp", "lan", "tachyon_lan_managed");

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
    remove_file("/etc/tachyon/dnsmasq-tailscale.servers");
    remove_file("/tmp/dnsmasq.d/tachyon-tailscale.conf");
    run_shell("rm -f /etc/dnsmasq.d/tachyon*.conf /tmp/dnsmasq.d/tachyon*.conf 2>/dev/null || true");

    if (fs.stat("/etc/init.d/dnsmasq") != null)
        run_cmd(["/etc/init.d/dnsmasq", "restart"]);
    if (fs.stat("/etc/init.d/odhcpd") != null)
        run_cmd(["/etc/init.d/odhcpd", "restart"]);
}

function clean_firewall_and_routing() {
    run_cmd(["nft", "delete", "table", "inet", "TachyonTable"]);
    run_cmd(["rm", "-f", "/usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft"]);
    run_cmd(["nft", "delete", "table", "inet", "TachyonKillSwitch"]);
    run_cmd(["nft", "delete", "table", "inet", "tachyon"]);
    run_cmd(["nft", "delete", "table", "inet", "steer"]);
    run_cmd(["nft", "delete", "table", "inet", "tachyon_tailscale"]);
    run_cmd(["nft", "delete", "table", "inet", "zapret"]);
    run_cmd(["nft", "delete", "table", "ip", "zapret"]);
    run_cmd(["nft", "delete", "table", "ip6", "zapret"]);
    run_cmd(["nft", "delete", "table", "inet", "zapret2"]);
    run_cmd(["nft", "delete", "table", "ip", "zapret2"]);
    run_cmd(["nft", "delete", "table", "ip6", "zapret2"]);
    run_cmd(["nft", "delete", "table", "ip", "tachyon"]);
    run_cmd(["nft", "delete", "table", "ip6", "tachyon"]);
    remove_file("/usr/share/nftables.d/chain-pre/input/10-tachyon.nft");

    // Restart firewall to purge in-memory dynamic rules from inet fw4
    if (fs.stat("/etc/init.d/firewall") != null)
        run_cmd(["/etc/init.d/firewall", "restart"]);

    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x04000000/0x04000000", "table", "tachyon", "priority", "105"]);
    run_cmd(["ip", "-6", "rule", "del", "fwmark", "0x04000000/0x04000000", "table", "tachyon", "priority", "105"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x10000000/0x10000000", "lookup", "100"]);
    run_cmd(["ip", "-6", "rule", "del", "fwmark", "0x10000000/0x10000000", "lookup", "100"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x1/0x1", "lookup", "100"]);
    run_cmd(["ip", "-4", "rule", "del", "fwmark", "0x2/0x2", "lookup", "100"]);
    run_cmd(["ip", "rule", "del", "to", "100.64.0.0/10", "priority", "100", "table", "4247"]);
    run_cmd(["ip", "-6", "rule", "del", "to", "fd7a:115c:a1e0::/48", "priority", "100", "table", "4247"]);
    run_cmd(["ip", "rule", "del", "fwmark", "0x00200000/0x00ff0000", "priority", "90", "table", "4248"]);
    run_cmd(["ip", "route", "flush", "table", "tachyon"]);
    run_cmd(["ip", "route", "flush", "table", "105"]);
    run_cmd(["ip", "route", "flush", "table", "100"]);
    run_cmd(["ip", "route", "flush", "table", "4247"]);
    run_cmd(["ip", "route", "flush", "table", "4248"]);
    run_cmd(["ip", "-6", "route", "flush", "table", "tachyon"]);
    run_cmd(["ip", "-6", "route", "flush", "table", "105"]);
    run_cmd(["ip", "-6", "route", "flush", "table", "100"]);
    run_cmd(["ip", "-6", "route", "flush", "table", "4247"]);
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

    // Non-destructive backup of external configs before any cleanup
    log_step("Backing up external component configurations...");
    backup_external_configs();

    clean_managed_core(keep_binaries);

    // Clean Tachyon's own internal steer remnants (always Tachyon-managed)
    for (let svc in [ "/etc/init.d/tachyon-steer-zapret", "/etc/init.d/steer" ]) {
        if (fs.stat(svc) != null) {
            run_cmd([ svc, "stop" ]);
            run_cmd([ svc, "disable" ]);
            remove_file(svc);
        }
    }
    run_shell("rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer 2>/dev/null || true");

    // Selectively remove legacy components ONLY if Tachyon-managed
    for (let comp in [ "zapret", "zapret2", "byedpi", "wdtt-client", "qwdtt", "olcrtc" ])
        selective_cleanup_component(comp, keep_binaries);

    let managed_tailscale = false;
    if (fs.stat("/etc/init.d/tailscale") != null) {
        let ts_init = fs.readfile("/etc/init.d/tailscale");
        if (ts_init && index(ts_init, "Tachyon managed") >= 0) {
            managed_tailscale = true;
            run_cmd([ "/etc/init.d/tailscale", "stop" ]);
            run_cmd([ "/etc/init.d/tailscale", "disable" ]);
            remove_file("/etc/init.d/tailscale");
            run_shell("rm -f /etc/rc.d/*tailscale* 2>/dev/null || true");
        }
    }
    if (!managed_tailscale &&
        (fs.stat("/etc/tachyon/component-backups/tailscale") != null ||
         length(fs.glob("/etc/tachyon/tailscale/*/native") || []) > 0))
        managed_tailscale = true;

    if (managed_tailscale)
        run_shell("rm -rf /etc/tachyon/tailscale/*/native 2>/dev/null || true");

    // Stop core and Tachyon background processes
    run_shell("killall tachyon-core steer 2>/dev/null || true");
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
    run_shell("rm -rf /var/run/tachyon* /var/log/tachyon* /tmp/tachyon* /tmp/tachyon-core /tmp/ai_doctor* /tmp/tg_* /tmp/warp_* 2>/dev/null || true");

    if (purge_config) {
        log_step("Purging Tachyon configuration and state (--purge)...");
        run_shell("rm -rf /etc/config/tachyon* /etc/tachyon /etc/.tachyon /etc/backup/tachyon_config /etc/tachyon-core 2>/dev/null || true");
    } else {
        log_step("Backing up Tachyon configuration...");
        let ts = clock()[0];
        run_shell("cp -af /etc/config/tachyon /etc/config/tachyon.backup-" + ts + " 2>/dev/null || true");
        run_shell("cp -af /etc/config/tachyon /etc/config/tachyon.bak 2>/dev/null || true");
        run_shell("chmod 600 /etc/config/tachyon.backup-* /etc/config/tachyon.bak 2>/dev/null || true");
    }

    log_step("Removing Tachyon packages...");
    // Only remove legacy component packages if they were Tachyon-managed
    let managed_legacy_pkgs = [];
    for (let comp in [ "zapret", "zapret2", "byedpi", "wdtt", "qwdtt", "olcrtc" ]) {
        if (is_tachyon_managed_component(comp))
            push(managed_legacy_pkgs, comp);
    }
    if (managed_tailscale)
        push(managed_legacy_pkgs, "tailscale");

    if (fs.stat("/bin/opkg") != null || fs.stat("/usr/bin/opkg") != null) {
        run_cmd(["opkg", "remove", "--force-depends", "--force-remove", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
        if (!keep_binaries) {
            for (let lp in managed_legacy_pkgs)
                run_cmd(["opkg", "remove", "--force-depends", "--force-remove", lp]);
        }
    } else if (fs.stat("/sbin/apk") != null || fs.stat("/usr/sbin/apk") != null || fs.stat("/usr/bin/apk") != null) {
        run_cmd(["apk", "del", "--no-network", "--repositories-file", "/dev/null", "luci-i18n-tachyon-ru", "luci-app-tachyon", "tachyon"]);
        if (!keep_binaries) {
            for (let lp in managed_legacy_pkgs) {
                run_shell("sed -i -E '/^" + lp + "([><= ].*)?$/d' /etc/apk/world 2>/dev/null || true");
                run_cmd(["apk", "del", "--no-network", "--repositories-file", "/dev/null", lp]);
            }
        }
    }
    if (!keep_binaries) {
        // Only remove binaries/configs of Tachyon-managed components
        for (let comp in [ "zapret", "zapret2", "byedpi", "wdtt", "qwdtt", "olcrtc" ]) {
            if (!is_tachyon_managed_component(comp))
                continue;

            if (comp == "zapret")
                run_shell("rm -rf /opt/zapret /etc/config/zapret 2>/dev/null || true");
            else if (comp == "zapret2")
                run_shell("rm -rf /opt/zapret2 /etc/config/zapret2 2>/dev/null || true");
            else if (comp == "byedpi")
                run_shell("rm -rf /etc/config/byedpi 2>/dev/null || true");
            else if (comp == "wdtt")
                run_shell("rm -rf /etc/wdtt /etc/config/wdtt 2>/dev/null || true");
            else if (comp == "qwdtt")
                run_shell("rm -rf /etc/qwdtt /etc/config/qwdtt 2>/dev/null || true");
            else if (comp == "olcrtc")
                run_shell("rm -rf /etc/olcrtc /etc/config/olcrtc 2>/dev/null || true");
        }
        // Remove Tachyon-managed binaries only
        if (is_tachyon_managed_component("zapret"))
            run_shell("rm -f /usr/bin/nfqws 2>/dev/null || true");
        if (is_tachyon_managed_component("zapret2"))
            run_shell("rm -f /usr/bin/nfqws2 2>/dev/null || true");
        if (is_tachyon_managed_component("byedpi"))
            run_shell("rm -f /usr/bin/ciadpi 2>/dev/null || true");
        if (is_tachyon_managed_component("wdtt") || is_tachyon_managed_component("wdtt-client"))
            run_shell("rm -f /usr/bin/wdtt /usr/sbin/wdtt-genlists /usr/sbin/wdtt-resolve 2>/dev/null || true");
        if (is_tachyon_managed_component("qwdtt"))
            run_shell("rm -f /usr/bin/qwdtt-client 2>/dev/null || true");
        if (is_tachyon_managed_component("olcrtc"))
            run_shell("rm -f /usr/bin/olcrtc 2>/dev/null || true");
    }

    // Clean Tachyon component update state for managed components
    run_shell("rm -rf /var/run/tachyon/component-update-checks 2>/dev/null || true");
    for (let comp in [ "zapret", "zapret2", "byedpi", "wdtt", "qwdtt", "olcrtc" ]) {
        if (is_tachyon_managed_component(comp))
            run_shell("rm -rf /etc/tachyon/component-backups/" + replace(comp, /-/g, "_") + " 2>/dev/null || true");
    }

    // Clean translations and LuCI views
    run_shell("rm -rf /usr/lib/tachyon /usr/share/tachyon /www/luci-static/resources/view/tachyon /usr/share/luci/menu.d/luci-app-tachyon.json /usr/share/rpcd/acl.d/luci-app-tachyon.json /usr/lib/lua/luci/i18n/tachyon.* 2>/dev/null || true");

    // Clear LuCI cache and restart rpcd/uhttpd
    run_shell("rm -f /var/luci-indexcache* /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true");
    if (fs.stat("/etc/config/ucitrack") != null) {
        run_shell("uci -q delete ucitrack.@tachyon[0] >/dev/null 2>&1; uci -q commit ucitrack >/dev/null 2>&1 || true");
    }
    if (fs.stat("/etc/init.d/rpcd") != null)
        run_cmd(["/etc/init.d/rpcd", "restart"]);
    if (fs.stat("/etc/init.d/uhttpd") != null)
        run_cmd(["/etc/init.d/uhttpd", "restart"]);

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
