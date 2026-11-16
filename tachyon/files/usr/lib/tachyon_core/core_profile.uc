// Capability and version-gate definitions for tachyon-core.
//
// This is a pure table lookup: it never reads a state file and never runs the
// installed binary. Callers pass the version they already know about, and
// tachyon_core/runtime.uc fills that in from the live system before calling in.
// Keeping the two apart is what lets the generator use this module - requiring
// runtime.uc from a generator would run its command-line dispatch on load and
// take the whole process down with a usage message.
//
// Plain data, deliberately: ucode evaluates a table initializer where the table
// stands, so a closure in here would have to be declared above the helpers it
// calls. A field is either a literal answer ("yes", "no", a TLS field name) or
// "from-version:X.Y", meaning the answer is whether the build number reaches
// that level.
let common = require("core.common");

let as_string = common.as_string;

const FROM_VERSION_PREFIX = "from-version:";
const DEFAULT_CORE_PROFILE = "tachyon-core";

const CORE_PROFILES = {
    "tachyon-core": {
        marker: "tachyon-core",
        version_contains: "-tachyon.",
        foreign_series: true,
        pin_field: "certificate_sha256",
        schema_1_14: "yes",
        schema_1_15: "yes",
        xhttp: "yes",
        tailscale: "yes",
        // Native desync landed in tachyon-core 0.1.7.
        desync: FROM_VERSION_PREFIX + "0.1.7",
        unified_delay: "no",
        // Native URLTest balancers (stability, sticky, least_load, weighted,
        // passive, priority, hedged, throughput, quota) landed in 0.3.9.
        native_balancer: FROM_VERSION_PREFIX + "0.3.9"
    }
};

const CORE_PROFILE_PRECEDENCE = [ "tachyon-core" ];

// Every protocol Tachyon can put into a config, so the interface can say "this
// core cannot do that" instead of dropping the section silently. Mirrors
// rule_action_supported() in config/validator.uc - keep the two in step.
const TACHYON_PROTOCOLS = [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2",
    "tuic", "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
    "socks", "http", "wireguard", "awg", "openvpn", "masque", "fptn",
    "selector", "urltest", "cloudflared", "tailscale", "openconnect", "bridge",
    "mieru", "tewfai", "trusttunnel", "desync", "wdtt" ];

// Read off tachyon-core crates/core-config/src/validate.rs (KNOWN_OUTBOUND_TYPES).
const CORE_PROTOCOLS = {
    "tachyon-core": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic",
        "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "awg", "warp", "openvpn", "masque", "fptn", "selector", "urltest",
        "cloudflared", "tailscale", "openconnect", "bridge", "mieru", "tewfai", "trusttunnel", "desync", "mtproto", "wdtt" ]
};

// Inbound kinds supported by Tachyon.
const TACHYON_INBOUNDS = [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun" ];

// tachyon-core runs its tun stack on smoltcp in userspace (MTU 9000, no SYN reset).
const CORE_INBOUNDS = {
    "tachyon-core": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria", "tuic", "anytls",
        "snell", "naive", "shadowtls", "fptn", "mieru", "trusttunnel", "tewfai", "masque", "openconnect", "mtproto", "wdtt", "tailscale" ]
};

function core_contains(values, needle) {
    for (let value in values)
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function is_from_version(value) {
    return substr(as_string(value), 0, length(FROM_VERSION_PREFIX)) == FROM_VERSION_PREFIX;
}

function from_version_level(value) {
    return substr(as_string(value), length(FROM_VERSION_PREFIX), length(as_string(value)));
}

function version_pair(value) {
    let text = trim(as_string(value));
    if (substr(text, 0, 1) == "v" || substr(text, 0, 1) == "V")
        text = trim(substr(text, 1, length(text)));
    let parts = split(text, ".");
    if (length(parts) < 2)
        return null;
    let major = int(trim(parts[0]));
    let minor = int(trim(parts[1]));
    if (major == null || minor == null || major < 0 || minor < 0)
        return null;
    return [ major, minor ];
}

function version_triple(value) {
    let text = trim(as_string(value));
    if (substr(text, 0, 1) == "v" || substr(text, 0, 1) == "V")
        text = trim(substr(text, 1, length(text)));
    let parts = split(text, ".");
    if (length(parts) < 2)
        return null;
    let major = int(trim(parts[0]));
    let minor = int(trim(parts[1]));
    if (major == null || minor == null || major < 0 || minor < 0)
        return null;
    let patch = 0;
    if (length(parts) > 2) {
        let parsed = int(trim(parts[2]));
        if (parsed != null && parsed >= 0)
            patch = parsed;
    }
    return [ major, minor, patch ];
}

function reaches_triple(value, level) {
    let build = version_triple(value);
    let want = version_triple(level);
    if (build == null || want == null)
        return false;
    if (build[0] != want[0])
        return build[0] > want[0];
    if (build[1] != want[1])
        return build[1] > want[1];
    return build[2] >= want[2];
}

function reaches(value, level) {
    return reaches_triple(value, level);
}

function profile_by_version(version) {
    return DEFAULT_CORE_PROFILE;
}

function profile(version, marker) {
    return DEFAULT_CORE_PROFILE;
}

function profile_data(name) {
    return type(CORE_PROFILES[name]) == "object" ? CORE_PROFILES[name] : CORE_PROFILES[DEFAULT_CORE_PROFILE];
}

function pin_field(version, marker) {
    let field = as_string(profile_data(profile(version, marker)).pin_field);
    if (is_from_version(field))
        return reaches(version, from_version_level(field)) ? "certificate_sha256" : "";
    return field;
}

function field_answers(declared, version, fallback_level) {
    let value = as_string(declared);
    if (is_from_version(value))
        return reaches(version, from_version_level(value));
    if (value == "yes")
        return true;
    if (value == "no")
        return false;
    return reaches(version, value == "" ? fallback_level : value);
}

function has_1_14(version, marker) {
    return field_answers(profile_data(profile(version, marker)).schema_1_14, version, "1.14");
}

function has_1_15(version, marker) {
    return field_answers(profile_data(profile(version, marker)).schema_1_15, version, "1.15");
}

function protocols(version, marker) {
    let list = CORE_PROTOCOLS[profile(version, marker)];
    return type(list) == "array" ? list : CORE_PROTOCOLS[DEFAULT_CORE_PROFILE];
}

function supports_protocol(protocol, version, marker) {
    return core_contains(protocols(version, marker), lc(trim(as_string(protocol))));
}

function missing_protocols(supported) {
    let missing = [];
    for (let protocol in TACHYON_PROTOCOLS)
        if (!core_contains(supported, protocol))
            missing[length(missing)] = protocol;
    return missing;
}

function inbounds(version, marker) {
    let list = CORE_INBOUNDS[profile(version, marker)];
    return type(list) == "array" ? list : CORE_INBOUNDS[DEFAULT_CORE_PROFILE];
}

function supports_inbound(kind, version, marker) {
    return core_contains(inbounds(version, marker), lc(trim(as_string(kind))));
}

function missing_inbounds(supported) {
    let missing = [];
    for (let kind in TACHYON_INBOUNDS)
        if (!core_contains(supported, kind))
            missing[length(missing)] = kind;
    return missing;
}

function output_has_build_tag(output, tag) {
    tag = as_string(tag);
    if (tag == "")
        return false;

    for (let token in split(trim(replace(as_string(output), /[,: \t\r\n]+/g, " ")), " "))
        if (as_string(token) == tag)
            return true;

    return false;
}

function flag(version, marker, field, tag, version_output) {
    let declared = as_string(profile_data(profile(version, marker))[field]);
    if (declared == "yes")
        return true;
    if (declared == "no")
        return false;
    if (declared == "build-tag") {
        if (as_string(version_output) == "")
            return null;
        return output_has_build_tag(version_output, tag);
    }
    if (is_from_version(declared))
        return reaches(version, from_version_level(declared));
    return null;
}

function supports_xhttp(version, marker, version_output) {
    return flag(version, marker, "xhttp", "with_xhttp", version_output);
}

function supports_tailscale(version, marker, version_output) {
    return flag(version, marker, "tailscale", "with_tailscale", version_output);
}

// Native desync arrived in tachyon-core 0.1.7.
function supports_desync(version, marker) {
    return flag(version, marker, "desync", "with_desync", null);
}

function supports_unified_delay(version, marker) {
    return flag(version, marker, "unified_delay", "with_unified_delay", null) === true;
}

// Native URLTest balancers (stability, sticky, least_load, weighted, passive,
// priority, hedged) landed in tachyon-core 0.3.9.
function supports_native_balancer(version, marker) {
    return flag(version, marker, "native_balancer", "with_native_balancer", null) === true;
}

return {
    CORE_PROFILES,
    CORE_PROTOCOLS,
    CORE_INBOUNDS,
    CORE_PROFILE_PRECEDENCE,
    TACHYON_PROTOCOLS,
    TACHYON_INBOUNDS,
    core_contains,
    profile,
    profile_by_version,
    profile_data,
    pin_field,
    has_1_14,
    has_1_15,
    protocols,
    supports_protocol,
    missing_protocols,
    inbounds,
    supports_inbound,
    missing_inbounds,
    output_has_build_tag,
    flag,
    supports_xhttp,
    supports_tailscale,
    supports_desync,
    supports_unified_delay,
    supports_native_balancer,
    version_triple,
    reaches_triple,
    reaches,
    version_pair
};
