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
const DNS_INBOUND_ADDRESS = require("core.constants").CORE_DNS_INBOUND_ADDRESS || "127.0.0.42";

// Actions whose traffic never goes through a proxy: a fail_policy left on
// them (after an action change, an import, the CLI) means nothing and must
// not turn the whole router Fail-Closed. Settings hides the option for them.
const NON_CAPTURING_ACTIONS = [ "bypass", "block", "dns", "hosts" ];

// An enabled section that captures traffic with fail_policy=block. The UI
// (failClosedSectionNames) mirrors this test.
function is_fail_closed_section(s) {
    s = common.object_or_empty(s);
    return common.bool_option(s, "enabled", true) &&
        index(NON_CAPTURING_ACTIONS, lc(trim(common.as_string(s.action || "")))) < 0 &&
        lc(trim(common.as_string(s.fail_policy || ""))) == "block";
}

// Why Tachyon may NOT fall back to direct WAN / direct DNS on its own, or ""
// when it may. One fail-closed section vetoes it router-wide because every
// fallback is router-wide; emergency_direct_bypass='0' vetoes it outright.
function veto(settings, sections) {
    if (common.object_or_empty(settings).emergency_direct_bypass == "0")
        return "emergency_direct_bypass=0";
    let names = [];
    for (let s in sections || []) {
        if (is_fail_closed_section(s))
            push(names, common.as_string(s[".name"]));
    }
    if (length(names) == 0)
        return "";
    return sprintf("fail_policy=block: %s", join(", ", names));
}

// Protections that default to "auto": on while a section is Fail-Closed, off
// otherwise; "1"/"0" are the user's explicit choice, so a client that needs
// its own resolver (a VPN app, a custom DNS) or direct WebRTC can opt out.
function auto_mode(settings, key) {
    let value = lc(trim(common.as_string(common.object_or_empty(settings)[key] || "")));
    if (index([ "1", "true", "yes", "on" ], value) >= 0)
        return "on";
    if (index([ "0", "false", "no", "off" ], value) >= 0)
        return "off";
    return "auto";
}

function auto_effective(settings, key, fail_closed) {
    let mode = auto_mode(settings, key);
    return mode == "on" || (mode == "auto" && !!fail_closed);
}

// settings.dns_intercept_all: LAN DNS redirect, DoT reject, DoH block.
function dns_intercept_mode(settings) {
    return auto_mode(settings, "dns_intercept_all");
}

function dns_intercept_effective(settings, fail_closed) {
    return auto_effective(settings, "dns_intercept_all", fail_closed);
}

// settings.webrtc_leak_protect: drop direct STUN/TURN, which would hand a
// proxied site the client's real address through WebRTC.
function webrtc_protect_mode(settings) {
    return auto_mode(settings, "webrtc_leak_protect");
}

function webrtc_protect_effective(settings, fail_closed) {
    return auto_effective(settings, "webrtc_leak_protect", fail_closed);
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

// TUN mode: the core's auto_route (rules 8999/9000, default dev tun0 in table
// 2022) is all that keeps LAN traffic off WAN. If the core dies, tun0 and its
// route vanish and LAN packets fall through to main's default route, i.e.
// out directly. These rules sit after the core's: while the core runs they are
// never reached; once it is gone, LAN packets keep the specific main routes
// (other LANs, site-to-site VPNs) but have no default route left. The router's
// own traffic (iif lo) is untouched. Replies of connections opened from
// outside (port forwards, inbound IPv6) carry the core's mark 0x2022 (set in
// nft/apply.uc) and keep main's default route: the peer already knows the
// router's address, so nothing leaks.
const TUN_GUARD_PREFS = [ 9499, 9500, 9501 ];
const TUN_AUTO_ROUTE_MARK = "0x2022";

function proxy_mode(settings) {
    return lc(trim(common.as_string(common.object_or_empty(settings).proxy_mode || "tproxy")));
}

// The ip-rule argument lists the TUN guard needs for this setup ([] = none).
function tun_guard_rules(settings, sections, service_enabled) {
    let rules = [];
    if (!service_enabled || proxy_mode(settings) != "tun" || veto(settings, sections) == "" ||
        !common.bool_option(settings, "tun_kill_switch", true))
        return rules;
    for (let family in [ "-4", "-6" ]) {
        for (let name in source_interfaces(settings)) {
            push(rules, [ family, "rule", "add", "iif", name, "fwmark", TUN_AUTO_ROUTE_MARK, "lookup", "main", "pref", "" + TUN_GUARD_PREFS[0] ]);
            push(rules, [ family, "rule", "add", "iif", name, "lookup", "main", "suppress_prefixlength", "0", "pref", "" + TUN_GUARD_PREFS[1] ]);
            push(rules, [ family, "rule", "add", "iif", name, "unreachable", "pref", "" + TUN_GUARD_PREFS[2] ]);
        }
    }
    return rules;
}

function ip(args) {
    let cmd = [ "ip" ];
    for (let arg in args)
        push(cmd, arg);
    return common.command_success_from_args(cmd);
}

function tun_guard_clear() {
    for (let family in [ "-4", "-6" ])
        for (let pref in TUN_GUARD_PREFS)
            for (let i = 0; i < 64; i++)
                if (!ip([ family, "rule", "del", "pref", "" + pref ]))
                    break;
}

// Install the TUN guard when the setup needs it, remove it otherwise.
function tun_guard_sync() {
    tun_guard_clear();
    let ok = true;
    for (let args in tun_guard_rules(uci_settings(), uci_core.section_objects(CONFIG_NAME, "section"), fs.lstat(ENABLED_LINK) != null))
        ok = ip(args) && ok;
    return ok;
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
    tun_guard_sync();
    return install(ruleset(source_interfaces(settings))) &&
        nft([ "flush", "set", "inet", GUARD_TABLE, GATE_SET ]);
}

// Open the gate: interception is in place, or the user chose direct Internet.
function release() {
    tun_guard_sync();
    if (!present())
        return true;
    return nft([ "add", "element", "inet", GUARD_TABLE, GATE_SET, nft_set(source_interfaces(uci_settings())) ]);
}

// Not fail-closed (any more): no gate at all, now or at the next boot.
function remove() {
    tun_guard_clear();
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
    is_fail_closed_section,
    uci_veto,
    dns_intercept_mode,
    dns_intercept_effective,
    webrtc_protect_mode,
    webrtc_protect_effective,
    source_interfaces,
    tun_guard_rules,
    tun_guard_sync,
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
