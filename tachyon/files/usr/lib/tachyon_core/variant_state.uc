// Core state helpers for callers that cannot spawn tachyon_core/runtime.uc
// directly (requiring runtime.uc runs its CLI dispatcher on load).
//
// tachyon-core is the sole routing core; this module reads the recorded
// tachyon-core version state file and answers version-gated schema queries
// via tachyon_core/core_profile.uc.
let fs = require("fs");
let core_profile = require("tachyon_core.core_profile");

const VERSION_STATE_FILE = getenv("TACHYON_CORE_VERSION_FILE") || "/etc/tachyon/tachyon-core-version";

function read_variant_marker() {
    return "tachyon-core";
}

function read_version_state() {
    return trim(fs.readfile(VERSION_STATE_FILE) || "");
}

function current_profile() {
    return "tachyon-core";
}

function awg_endpoint_schema() {
    return true;
}

function is_tachyon_core() {
    return true;
}

function supports_native_balancer(live_version) {
    let version = trim(live_version || "");
    if (version == "")
        version = read_version_state();
    if (version == "")
        version = trim(getenv("TACHYON_CORE_VERSION_OVERRIDE") || "");
    if (version != "")
        return core_profile.supports_native_balancer(version, "tachyon-core") === true;
    return true;
}

return {
    read_variant_marker,
    read_version_state,
    current_profile,
    awg_endpoint_schema,
    is_tachyon_core,
    supports_native_balancer
};
