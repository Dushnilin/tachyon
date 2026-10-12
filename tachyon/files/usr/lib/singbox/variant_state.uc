// Which core is installed right now, for callers that cannot ask
// singbox/runtime.uc: its command-line dispatch runs on load and would take
// the generator down, and diagnostics only needs the state files anyway.
//
// The marker file is what components/action.uc wrote when it put this binary
// in place; the version covers a build that names itself in its number
// ("-lx", "-tachyon."). The pure table lookup lives in singbox/core_profile.uc.
let fs = require("fs");
let core_profile = require("singbox.core_profile");

const VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/tachyon/sing-box-variant";
const VERSION_STATE_FILE = getenv("SB_VERSION_STATE_FILE") || "/etc/tachyon/sing-box-version";

function current_profile() {
    let version = trim(fs.readfile(VERSION_STATE_FILE) || "");
    let marker = trim(fs.readfile(VARIANT_STATE_FILE) || "");
    // A build that names itself in its version outranks the marker: the marker
    // describes what was installed previously and can lag behind a swapped
    // binary. Same order as sing_box_core_identity_marker() in
    // singbox/runtime.uc, minus the banner probe - the generator never spawns.
    let from_version = core_profile.profile_by_version(version);
    return from_version != "" ? from_version : core_profile.profile(version, marker);
}

// AWG is an endpoint with its fields at the root on sing-box-lx and on our own
// core; on extended it stays an inbound with an amnezia object, and upstream
// rejects a wireguard inbound outright ("unknown inbound type: wireguard").
function awg_endpoint_schema() {
    let profile = current_profile();
    return profile == "lx" || profile == "tachyon-core";
}

return {
    current_profile,
    awg_endpoint_schema
};
