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
        (!need_tproxy || index(data, "tproxy") >= 0);
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
