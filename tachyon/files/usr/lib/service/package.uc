#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

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
const PACKAGE_UPGRADE_STATE = env("TACHYON_PACKAGE_UPGRADE_STATE", "/tmp/tachyon-package-was-running");
const PACKAGE_TEST_MODE = env("TACHYON_PACKAGE_TEST_MODE", "") != "";
// apk aborts and rolls the whole transaction back if a hook outlives its
// patience, and the installer kills it even sooner. Anything that touches
// /etc/init.d/tachyon goes through rc.common, which waits on `flock -w 1000` —
// a stuck start or retry_start_on_wan_up holding that lock would stall the hook
// for a quarter of an hour. Every such call is bounded instead.
const HOOK_COMMAND_TIMEOUT = env("TACHYON_HOOK_COMMAND_TIMEOUT", "20");
// Starting the service legitimately takes longer than probing or stopping it —
// sing-box comes up, nft rules load, subscriptions may be re-read — so it gets
// its own, larger budget. Still bounded: postinst must end.
const HOOK_START_TIMEOUT = env("TACHYON_HOOK_START_TIMEOUT", "60");

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

// Which spelling of `timeout` this box understands, resolved once. BusyBox
// required `-t SECONDS` on older builds and rejects it on newer ones. Probing is
// done against /bin/true rather than the real command: an unsupported form would
// otherwise mean running the cleanup twice.
let timeout_prefix_cache = null;

function timeout_prefix() {
    if (timeout_prefix_cache != null)
        return timeout_prefix_cache;

    if (normalize_status(system("timeout 1 /bin/true >/dev/null 2>&1")) == 0)
        timeout_prefix_cache = [ "timeout" ];
    else if (normalize_status(system("timeout -t 1 /bin/true >/dev/null 2>&1")) == 0)
        timeout_prefix_cache = [ "timeout", "-t" ];
    else
        timeout_prefix_cache = []; // no usable timeout binary

    return timeout_prefix_cache;
}

// Same as command_success_from_args, but the command cannot outlive `seconds`.
// A timed-out command reports failure (timeout exits 124), which every caller
// here already treats as "could not do it, carry on" — the alternative is an
// upgrade the package manager rolls back.
function bounded_command_success_from_args(args, seconds) {
    seconds = as_string(seconds) != "" ? as_string(seconds) : HOOK_COMMAND_TIMEOUT;

    let prefix = timeout_prefix();
    if (length(prefix) == 0)
        return command_success_from_args(args);

    let bounded = [];
    for (let part in prefix)
        push(bounded, part);
    push(bounded, seconds);
    for (let arg in args)
        push(bounded, arg);

    return command_success_from_args(bounded);
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

    bounded_command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        bounded_command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    bounded_command_success_from_args([ SING_BOX_INIT, "stop" ]);
    bounded_command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function remember_upgrade_state(action) {
    // INIT_PATH status goes through rc.common's flock, so it is bounded like every
    // other init call here. A timeout is indistinguishable from "not running", and
    // that is the safe reading: the worst case is not restarting a service that was
    // wedged anyway, versus stalling the upgrade until apk rolls it back.
    if (as_string(action) != "upgrade" || !bounded_command_success_from_args([ INIT_PATH, "status" ])) {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }
    fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    if (!PACKAGE_TEST_MODE) {
        // Kill the WAN hotplug monitor and all init.d/tachyon/flock processes FIRST
        // to prevent INIT_PATH stop from blocking indefinitely on rc.common flock -w 1000.
        // This has to happen before the status probe below, or that probe becomes the
        // very thing that waits on the lock those processes hold.
        system("ps 2>/dev/null | grep -E '99-tachyon-wan|flock 1000|init[.]d/tachyon' | awk '{print $1}' | while read _pid; do kill -9 \"$_pid\" 2>/dev/null; done; true");
        system("ps 2>/dev/null | grep -F '/etc/init.d/tachyon' | awk '{print $1}' | while read _pid; do kill -9 \"$_pid\" 2>/dev/null; done; true");
    }

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        // Stop the service using BIN_PATH directly (bypasses rc.common flock)
        bounded_command_success_from_args([BIN_PATH, "stop"]);
        bounded_command_success_from_args([INIT_PATH, "stop"]);

        // Kill any remaining tachyon processes
        system("ps 2>/dev/null | grep -F '/usr/bin/tachyon' | awk '{print $1}' | while read _pid; do kill -9 \"$_pid\" 2>/dev/null; done; true");
        restore_dnsmasq_if_needed();
        remove_managed_sing_box();
    }
    remove_rt_tables_entry(); // best-effort
    return true;
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "" || !path_exists(PACKAGE_UPGRADE_STATE))
        return true;

    if (!PACKAGE_TEST_MODE) {
        // Kill any flock waiters and init.d/tachyon processes that appeared since prerm ran.
        system("ps 2>/dev/null | grep -E '99-tachyon-wan|flock 1000' | awk '{print $1}' | while read _pid; do kill -9 \"$_pid\" 2>/dev/null; done; true");
        system("ps 2>/dev/null | grep -F '/etc/init.d/tachyon' | awk '{print $1}' | while read _pid; do kill -9 \"$_pid\" 2>/dev/null; done; true");
    }
    // Start via INIT_PATH. Bounded: a start that hangs must not take the package
    // transaction down with it — the service can be started by hand afterwards,
    // a rolled-back upgrade leaves the user on the old build with no recourse.
    bounded_command_success_from_args([INIT_PATH, "start"], HOOK_START_TIMEOUT);
    unlink_if_exists(PACKAGE_UPGRADE_STATE);
    return true;
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

function remove_component_update_cache() {
    for (let path in fs.glob("/var/run/tachyon/component-update-checks/*.json"))
        unlink_if_exists(path);
    unlink_if_exists("/var/run/tachyon/component-update-check.timestamp");
    command_success_from_args([ "rm", "-rf", "/var/run/tachyon/component-action.lock" ]);
    for (let path in fs.glob("/var/run/tachyon/component-actions/*"))
        unlink_if_exists(path);
}

function luci_postinst() {
    remove_luci_index_cache();
    remove_component_update_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "tachyon", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}