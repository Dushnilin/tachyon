// Router-wide kill-switch for fail-closed setups.
//
// A section with fail_policy=block promises its traffic never leaves directly.
// Interception lives in TachyonTable, and there are windows where that table
// does not exist: a restart between stop and start, a start that failed, the
// boot before Tachyon runs, the delete-then-build step of every nft rebuild.
// While the guard is engaged it drops everything forwarded from the LAN source
// interfaces to anywhere else. It lives in its own table, so rebuilds can
// delete and recreate TachyonTable underneath it.
let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = "tachyon";
const GUARD_TABLE = "TachyonKillSwitch";
const RUNTIME_TABLE = "TachyonTable";
// Root-owned run dir, not world-writable /tmp: root loads whatever is here.
const RUNTIME_DIR = "/var/run/tachyon";
const RULESET_FILE = RUNTIME_DIR + "/kill-switch.nft";
const ENABLED_LINK = "/etc/rc.d/S99tachyon";

// Why Tachyon may NOT fall back to direct WAN / direct DNS on its own, or ""
// when it may. One fail-closed section vetoes it router-wide because every
// fallback is router-wide; emergency_direct_bypass='0' vetoes it outright.
function veto(settings, sections) {
    if (common.object_or_empty(settings).emergency_direct_bypass == "0")
        return "emergency_direct_bypass=0";
    let names = [];
    for (let s in sections || []) {
        if (common.bool_option(s, "enabled", true) &&
            lc(trim(common.as_string(s.fail_policy || ""))) == "block")
            push(names, common.as_string(s[".name"]));
    }
    if (length(names) == 0)
        return "";
    return sprintf("fail_policy=block: %s", join(", ", names));
}

function uci_settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_veto() {
    return veto(uci_settings(), uci_core.section_objects(CONFIG_NAME, "section"));
}

// Interface names are spliced into an nft ruleset: anything outside the
// kernel's interface-name alphabet is dropped rather than quoted.
function source_interfaces(settings) {
    let names = [];
    for (let name in common.list_option(settings, "source_network_interfaces")) {
        name = trim(common.as_string(name));
        if (match(name, /^[A-Za-z0-9_.@-]{1,15}$/) && index(names, name) < 0)
            push(names, name);
    }
    if (length(names) == 0)
        push(names, "br-lan");
    return names;
}

function ruleset(interfaces) {
    let set = sprintf("{ %s }", join(", ", map(interfaces, (n) => sprintf("\"%s\"", n))));
    return sprintf("table inet %s\n" +
        "delete table inet %s\n" +
        "table inet %s {\n" +
        "\tchain forward {\n" +
        "\t\ttype filter hook forward priority -200; policy accept;\n" +
        "\t\tiifname %s oifname != %s counter drop comment \"tachyon fail-closed kill-switch\"\n" +
        "\t}\n" +
        "}\n", GUARD_TABLE, GUARD_TABLE, GUARD_TABLE, set, set);
}

function engaged() {
    return common.command_success_from_args([ "nft", "list", "table", "inet", GUARD_TABLE ]);
}

function engage(settings) {
    fs.mkdir(RUNTIME_DIR);
    if (fs.writefile(RULESET_FILE, ruleset(source_interfaces(settings))) == null)
        return false;
    let ok = common.command_success_from_args([ "nft", "-f", RULESET_FILE ]);
    fs.unlink(RULESET_FILE);
    return ok;
}

function release() {
    if (!engaged())
        return true;
    return common.command_success_from_args([ "nft", "delete", "table", "inet", GUARD_TABLE ]);
}

// Engage the guard when the setup is fail-closed, drop a stale one otherwise.
// Returns the veto reason ("" = not fail-closed).
function hold() {
    let reason = uci_veto();
    if (reason == "")
        release();
    else
        engage(uci_settings());
    return reason;
}

// Hotplug, before Tachyon starts: only an enabled service with no
// interception table yet needs the guard.
function boot() {
    if (fs.lstat(ENABLED_LINK) != null &&
        !common.command_success_from_args([ "nft", "list", "table", "inet", RUNTIME_TABLE ]))
        hold();
}

return {
    GUARD_TABLE,
    veto,
    uci_veto,
    source_interfaces,
    ruleset,
    engaged,
    engage,
    release,
    hold,
    boot
};
