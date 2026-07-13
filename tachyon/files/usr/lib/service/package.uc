#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

let common = require("core.common");
let as_string = common.as_string;
let shell_quote = common.shell_quote;

let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;


function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("TACHYON_CONFIG_NAME", "tachyon");
const RT_TABLES_PATH = env("TACHYON_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("TACHYON_BIN", "/usr/bin/tachyon");
const INIT_PATH = env("TACHYON_INIT", "/etc/init.d/tachyon");
const DNS_APPLY_UC = env("TACHYON_DNS_APPLY_UC", "/usr/lib/tachyon/dns/apply.uc");
const SING_BOX_INIT = env("TACHYON_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("TACHYON_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("TACHYON_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Tachyon managed sing-box service for binary variants");
const PACKAGE_TEST_MODE = env("TACHYON_PACKAGE_TEST_MODE", "") != "";


function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}


function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 tachyon") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function prerm_cleanup() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    if (!PACKAGE_TEST_MODE) {
        command_success_from_args([ INIT_PATH, "stop" ]);
        restore_dnsmasq_if_needed();
        remove_managed_sing_box();
    }
    return remove_rt_tables_entry();
}

function luci_cache_globs() {
    let configured = env("TACHYON_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    try {
        let uci = require("uci");
        let cursor = uci.cursor();
        cursor.load(CONFIG_NAME);
        if (cursor.get(CONFIG_NAME, "telegram") == null) {
            cursor.set(CONFIG_NAME, "telegram", "telegram");
            cursor.set(CONFIG_NAME, "telegram", "enabled", "0");
            cursor.set(CONFIG_NAME, "telegram", "poll_interval", "5");
            cursor.set(CONFIG_NAME, "telegram", "notify_crash", "1");
            cursor.set(CONFIG_NAME, "telegram", "notify_restart", "1");
            cursor.set(CONFIG_NAME, "telegram", "notify_server_switch", "1");
            cursor.set(CONFIG_NAME, "telegram", "notify_subscription", "1");
            cursor.set(CONFIG_NAME, "telegram", "notify_cert", "1");
            cursor.set(CONFIG_NAME, "telegram", "notify_dns_leak", "1");
            cursor.commit(CONFIG_NAME);
        }
    } catch(e) {}

    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "tachyon", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}
