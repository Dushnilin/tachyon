// Router-wide kill-switch for fail-closed setups.
//
// A section with fail_policy=block promises its traffic never leaves directly.
// Interception lives in TachyonTable, and there are windows where that table
// does not exist: the boot before Tachyon runs, a restart between stop and
// start, a start that failed, the delete-then-build step of every nft rebuild.
//
// The guard is a gate in its own table: it drops everything forwarded from
// the LAN source interfaces to anywhere else, and their DNS (53, 853) to the
// router itself, unless the interface is in the `open` set. With LAN DNS shut
// out, the router's own resolver may fall back to WAN DNS while the gate is
// closed: the router keeps resolving (updates, NTP, subscriptions) and the
// clients still get nothing. Tachyon opens the gate once interception is in place and closes
// it before interception goes away.
//
// The same ruleset is installed as an fw4 ruleset-post include, so the closed
// gate exists from firewall start (S19), before any interface comes up. An
// fw4 reload re-declares the table, which keeps the set elements, so a reload
// while Tachyon runs leaves the gate open.
let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = "tachyon";
const GUARD_TABLE = "TachyonKillSwitch";
const GATE_SET = "open";
const RUNTIME_TABLE = "TachyonTable";
// Root-owned run dir, not world-writable /tmp: root loads whatever is here.
const RUNTIME_DIR = "/var/run/tachyon";
const RULESET_FILE = RUNTIME_DIR + "/kill-switch.nft";
const FW4_INCLUDE_ROOT = getenv("TACHYON_FW4_INCLUDE_ROOT") || "/usr/share/nftables.d";
const FW4_INCLUDE_DIR = FW4_INCLUDE_ROOT + "/ruleset-post";
const FW4_INCLUDE_FILE = FW4_INCLUDE_DIR + "/90-tachyon-kill-switch.nft";
const ENABLED_LINK = "/etc/rc.d/S99tachyon";
const DNS_INBOUND_ADDRESS = require("core.constants").SB_DNS_INBOUND_ADDRESS || "127.0.0.42";

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

// settings.dns_intercept_all: "auto" (default) intercepts LAN DNS while a
// section is Fail-Closed; "1"/"0" are the user's explicit choice, so clients
// that need their own resolver (a VPN app, a custom DNS) can still opt out.
function dns_intercept_mode(settings) {
    let value = lc(trim(common.as_string(common.object_or_empty(settings).dns_intercept_all || "")));
    if (index([ "1", "true", "yes", "on" ], value) >= 0)
        return "on";
    if (index([ "0", "false", "no", "off" ], value) >= 0)
        return "off";
    return "auto";
}

function dns_intercept_effective(settings, fail_closed) {
    let mode = dns_intercept_mode(settings);
    return mode == "on" || (mode == "auto" && !!fail_closed);
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

function nft_set(interfaces) {
    return sprintf("{ %s }", join(", ", map(interfaces, (n) => sprintf("\"%s\"", n))));
}

// Idempotent: re-declaring the table, set and chain keeps the set elements;
// only the single rule is replaced.
function ruleset(interfaces) {
    let set = nft_set(interfaces);
    return sprintf("table inet %s {\n" +
        "\tset %s {\n" +
        "\t\ttype ifname\n" +
        "\t}\n" +
        "\tchain forward {\n" +
        "\t\ttype filter hook forward priority -200; policy accept;\n" +
        "\t}\n" +
        "\tchain input {\n" +
        "\t\ttype filter hook input priority -200; policy accept;\n" +
        "\t}\n" +
        "}\n" +
        "flush chain inet %s forward\n" +
        "add rule inet %s forward iifname %s oifname != %s iifname != @%s counter drop comment \"tachyon fail-closed kill-switch\"\n" +
        "flush chain inet %s input\n" +
        "add rule inet %s input iifname %s meta l4proto { tcp, udp } th dport { 53, 853 } iifname != @%s counter drop comment \"tachyon fail-closed kill-switch dns\"\n",
        GUARD_TABLE, GATE_SET, GUARD_TABLE, GUARD_TABLE, set, set, GATE_SET, GUARD_TABLE, GUARD_TABLE, set, GATE_SET);
}

function nft(args) {
    let cmd = [ "nft" ];
    for (let arg in args)
        push(cmd, arg);
    return common.command_success_from_args(cmd);
}

function present() {
    return nft([ "list", "table", "inet", GUARD_TABLE ]);
}

// Closed = the table exists and its gate set holds no interface.
function engaged() {
    if (!present())
        return false;
    let out = common.command_output_from_args([ "nft", "list", "set", "inet", GUARD_TABLE, GATE_SET ]) || "";
    return index(out, "elements") < 0;
}

// Validate before anything is installed: a broken fw4 include would stop the
// whole firewall from loading at boot.
function install(text) {
    fs.mkdir(RUNTIME_DIR);
    if (fs.writefile(RULESET_FILE, text) == null)
        return false;
    let ok = nft([ "-c", "-f", RULESET_FILE ]) && nft([ "-f", RULESET_FILE ]);
    if (ok && fs.stat(FW4_INCLUDE_ROOT) != null) {
        fs.mkdir(FW4_INCLUDE_DIR);
        ok = common.write_file(FW4_INCLUDE_FILE, text);
    }
    fs.unlink(RULESET_FILE);
    return ok;
}

function engage(settings) {
    return install(ruleset(source_interfaces(settings))) &&
        nft([ "flush", "set", "inet", GUARD_TABLE, GATE_SET ]);
}

// Open the gate: interception is in place, or the user chose direct Internet.
function release() {
    if (!present())
        return true;
    return nft([ "add", "element", "inet", GUARD_TABLE, GATE_SET, nft_set(source_interfaces(uci_settings())) ]);
}

// Not fail-closed (any more): no gate at all, now or at the next boot.
function remove() {
    fs.unlink(FW4_INCLUDE_FILE);
    return !present() || nft([ "delete", "table", "inet", GUARD_TABLE ]);
}

// Close the gate when the setup is fail-closed, drop the guard otherwise.
// Returns the veto reason ("" = not fail-closed).
function hold() {
    let reason = uci_veto();
    if (reason == "")
        remove();
    else
        engage(uci_settings());
    return reason;
}

// Why DNS must not be rolled back to direct WAN now, or "" when it may.
// Only an enabled, fail-closed service vetoes: disabling or removing Tachyon
// is the user leaving it, and the router must keep a working resolver then.
function dns_veto() {
    if (fs.lstat(ENABLED_LINK) == null)
        return "";
    let reason = uci_veto();
    // A closed gate already shuts LAN clients out of DNS and WAN, so the
    // router may resolve directly then; only an open gate (Tachyon running)
    // must keep DNS on the proxy.
    if (reason == "" || engaged())
        return "";
    return reason;
}

// dnsmasq answers LAN clients through Tachyon again (or Tachyon does not own
// DNS at all). Until then the gate stays closed, or clients would resolve real
// IPs over WAN DNS the moment it opens.
function dns_ready() {
    let dhcp = function(key) {
        return trim(common.as_string(uci_core.get("dhcp.@dnsmasq[0]." + key) || ""));
    };
    if (common.bool_option(uci_settings(), "dont_touch_dhcp", false) || dhcp("port") == "0")
        return true;
    let servers = uci_core.get("dhcp.@dnsmasq[0].server");
    servers = type(servers) == "array" ? servers : split(common.as_string(servers || ""), /[ \t]+/);
    return dhcp("noresolv") == "1" && index(servers, DNS_INBOUND_ADDRESS) >= 0;
}

// Open the gate once interception is up and DNS is back on the proxy.
function release_if_ready() {
    return dns_ready() ? release() : false;
}

// For stop: a disabled service is the user leaving Tachyon, so no gate and
// direct DNS; an enabled one stays fail-closed until it starts again.
// Returns the veto reason ("" = stop may go direct).
function stop_hold() {
    if (fs.lstat(ENABLED_LINK) == null) {
        remove();
        return "";
    }
    return hold();
}

// WAN hotplug. fw4 already created the closed gate at boot; settle it for
// the current state: no service, no gate; interception up, gate open.
function boot() {
    if (fs.lstat(ENABLED_LINK) == null)
        remove();
    else if (nft([ "list", "table", "inet", RUNTIME_TABLE ]))
        release();
    else
        hold();
}

return {
    GUARD_TABLE,
    GATE_SET,
    FW4_INCLUDE_FILE,
    veto,
    uci_veto,
    dns_intercept_mode,
    dns_intercept_effective,
    source_interfaces,
    ruleset,
    engaged,
    engage,
    release,
    remove,
    hold,
    stop_hold,
    dns_veto,
    dns_ready,
    release_if_ready,
    boot
};
