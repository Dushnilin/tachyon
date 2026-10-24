// Which core is installed right now, for callers that cannot ask
// tachyon_core/runtime.uc: its command-line dispatch runs on load and would take
// the generator down, and diagnostics only needs the state files anyway.
//
// The marker file is what components/action.uc wrote when it put this binary
// in place; the version covers a build that names itself in its number
// ("-lx", "-tachyon."). The pure table lookup lives in singbox/core_profile.uc.
let fs = require("fs");
let core_profile = require("tachyon_core.core_profile");

const VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/tachyon/tachyon-core-variant";
const VERSION_STATE_FILE = getenv("SB_VERSION_STATE_FILE") || "/etc/tachyon/tachyon-core-version";
const LEGACY_VARIANT_STATE_FILE = "/etc/tachyon/sing-box-variant";
const LEGACY_VERSION_STATE_FILE = "/etc/tachyon/sing-box-version";

function read_variant_marker() {
    let marker = trim(fs.readfile(VARIANT_STATE_FILE) || "");
    if (marker == "" && getenv("SB_VARIANT_STATE_FILE") == null)
        marker = trim(fs.readfile(LEGACY_VARIANT_STATE_FILE) || "");
    return marker;
}

function read_version_state() {
    let version = trim(fs.readfile(VERSION_STATE_FILE) || "");
    if (version == "" && getenv("SB_VERSION_STATE_FILE") == null)
        version = trim(fs.readfile(LEGACY_VERSION_STATE_FILE) || "");
    return version;
}

function current_profile() {
    let version = read_version_state();
    let marker = read_variant_marker();
    // A build that names itself in its version outranks the marker: the marker
    // describes what was installed previously and can lag behind a swapped
    // binary. Same order as sing_box_core_identity_marker() in
    // tachyon_core/runtime.uc, minus the banner probe - the generator never spawns.
    let from_version = core_profile.profile_by_version(version);
    if (from_version != "")
        return from_version;
    let by_ver_only = core_profile.profile(version, "");
    if (by_ver_only != "upstream")
        return by_ver_only;
    return core_profile.profile(version, marker);
}

// AWG is an endpoint with its fields at the root on sing-box-lx and on our own
// core; on extended it stays an inbound with an amnezia object, and upstream
// rejects a wireguard inbound outright ("unknown inbound type: wireguard").
function awg_endpoint_schema() {
    let profile = current_profile();
    return profile == "lx" || profile == "tachyon-core";
}

function is_tachyon_core() {
    let version = read_version_state();
    if (match(version, /^[vV]?[1-9]\.[0-9]+/) != null && index(version, "-tachyon.") < 0)
        return false;
    if (current_profile() == "tachyon-core")
        return true;
    return match(version, /^v?0\.[0-9]+\.[0-9]+/) != null;
}

return {
    read_variant_marker,
    read_version_state,
    current_profile,
    awg_endpoint_schema,
    is_tachyon_core
};
