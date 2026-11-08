// Shared observations for the controller and recovery verification. No repairs.
let fs = require("fs");
let common = require("core.common");

const EMERGENCY_FILE = getenv("TACHYON_EMERGENCY_STATE_FILE") || "/etc/tachyon/emergency_state.json";
const EMERGENCY_TMP = getenv("TACHYON_EMERGENCY_STATE_TMP") || "/tmp/tachyon_emergency_state.json";
const NATIVE_MARKER = getenv("TACHYON_NATIVE_INTERNET_MARKER") || "/var/run/tachyon/native_internet_restored";
const PAUSE_FILE = getenv("TACHYON_PAUSE_FILE") || "/tmp/tachyon_paused_until";

function emergency_active() {
    return fs.stat(EMERGENCY_FILE) != null || fs.stat(EMERGENCY_TMP) != null;
}

function manual_bypass_active(settings) {
    return settings.recovery_bypass == "1" || fs.stat(NATIVE_MARKER) != null ||
        int(trim(fs.readfile(PAUSE_FILE) || "0")) > time();
}

function interception_suppressed(settings) {
    return emergency_active() || manual_bypass_active(settings);
}

function tproxy_policy_route_ok() {
    let route_res = common.command_capture(common.command_from_args([
        "ip", "route", "list", "table", "tachyon"
    ]) + " 2>/dev/null");
    let route_out = route_res.output || "";
    if (index(route_out, "table inet ") >= 0)
        return true;
    if (route_res.status != 0 || index(route_out, "local default dev lo") < 0)
        return false;
    let rule_res = common.command_capture(common.command_from_args([
        "ip", "rule", "list"
    ]) + " 2>/dev/null");
    let rule_out = rule_res.output || "";
    return rule_res.status == 0 && index(rule_out, "lookup tachyon") >= 0 && index(rule_out, "fwmark") >= 0;
}

function inspect(settings) {
    let table = getenv("NFT_TABLE_NAME") || "TachyonTable";
    let result = common.command_capture(common.command_from_args([
        "nft", "list", "table", "inet", table
    ]) + " 2>/dev/null");
    let data = result.output || "";
    let table_present = result.status == 0 && index(data, "table inet " + table) >= 0;

    let mode = lc(trim(common.as_string(settings.proxy_mode || "tproxy")));
    let need_tproxy = mode != "tun" && mode != "socks";
    let nft_ok = table_present && index(data, "priority_rules") >= 0 &&
        (!need_tproxy || (index(data, "tproxy") >= 0 && tproxy_policy_route_ok()));
    if ((settings.routing_mode || "nftables") != "nftables")
        nft_ok = true;
    let qos_ok = settings.qos_priority_engine == "0" ||
        (table_present &&
         (index(data, "dscp set 0x2e") >= 0 || index(data, "dscp set ef") >= 0) &&
         (index(data, "dscp set 0x22") >= 0 || index(data, "dscp set af41") >= 0));
    return { nft_ok: nft_ok, qos_ok: qos_ok };
}

function tproxy_listening(port) {
    let hex_port = sprintf("%04X", int(port));
    for (let path in ["/proc/net/tcp6", "/proc/net/tcp"]) {
        for (let line in split(fs.readfile(path) || "", "\n")) {
            if (index(line, ":" + hex_port + " ") >= 0 && index(line, " 0A ") >= 0)
                return true;
        }
    }
    return false;
}

return {
    emergency_active,
    manual_bypass_active,
    interception_suppressed,
    inspect,
    tproxy_listening
};
