// What each sing-box build is, and what it accepts.
//
// This is a pure table lookup: it never reads a marker file and never runs the
// installed binary. Callers pass the version and marker they already know about,
// and singbox/runtime.uc fills those in from the live system before calling in.
// Keeping the two apart is what lets the generator use this module - requiring
// runtime.uc from a generator would run its command-line dispatch on load and
// take the whole process down with a usage message.
//
// Plain data, deliberately: ucode evaluates a table initializer where the table
// stands, so a closure in here would have to be declared above the helpers it
// calls, and a helper table that must be ordered around itself is the fragility
// this model exists to remove. A field is either a literal answer ("yes", "no",
// a TLS field name) or "from-version:X.Y", meaning the answer is whether the
// build number reaches that level.
//
// certificate_sha256 hashes the whole DER certificate - the value a proxy link's
// pcs carries - and certificate_public_key_sha256 hashes the public key. They
// are different values, so the field is chosen per build and never substituted.
// trim() and lc() are ucode builtins; only as_string has to be imported.
let common = require("core.common");

let as_string = common.as_string;

const FROM_VERSION_PREFIX = "from-version:";

const CORE_PROFILES = {
    "upstream": {
        marker: "",
        version_contains: "",
        foreign_series: false,
        pin_field: FROM_VERSION_PREFIX + "1.15",
        schema_1_14: FROM_VERSION_PREFIX + "1.14",
        schema_1_15: FROM_VERSION_PREFIX + "1.15",
        xhttp: "build-tag",
        tailscale: "build-tag"
    },
    "lx": {
        marker: "lx",
        version_contains: "-lx",
        foreign_series: false,
        // Verified against the real binary: 1.14.2-lx.12 rejects
        // certificate_sha256 with "unknown field" and accepts the public-key one.
        pin_field: "certificate_public_key_sha256",
        schema_1_14: FROM_VERSION_PREFIX + "1.14",
        schema_1_15: "no",
        xhttp: "yes",
        tailscale: "yes"
    },
    "extended": {
        marker: "extended",
        version_contains: "extended",
        foreign_series: false,
        pin_field: FROM_VERSION_PREFIX + "1.15",
        schema_1_14: FROM_VERSION_PREFIX + "1.14",
        schema_1_15: FROM_VERSION_PREFIX + "1.15",
        // Same code base as extended-compressed below, so the same flat yes:
        // shtorm-7 compiles xhttp in unconditionally, and every caller used to
        // answer "extended supports xhttp" by hand anyway.
        xhttp: "yes",
        tailscale: "yes"
    },
    "extended-compressed": {
        marker: "extended-compressed",
        // Not plain "extended": that would swallow the uncompressed build, and
        // the two differ in capabilities, so an unmarked binary must not be
        // assumed to be the compressed one.
        version_contains: "extended-compressed",
        foreign_series: false,
        pin_field: FROM_VERSION_PREFIX + "1.15",
        schema_1_14: FROM_VERSION_PREFIX + "1.14",
        schema_1_15: FROM_VERSION_PREFIX + "1.15",
        xhttp: "yes",
        tailscale: "yes"
    },
    // Our own core. Its version is a different series entirely - the released
    // build reports "tachyon-core 0.0.1", a bare number with no fork suffix -
    // so what answers "is this 1.15" is the schema, read off the core's own
    // validator: buffer_size, flush_interval, store_dns and certificate_sha256
    // are all accepted there. Nothing is inferred from the number, which is why
    // these two are flat "yes" and not from-version.
    "tachyon-core": {
        marker: "tachyon-core",
        // A build that carries the suffix in its version is recognised on sight.
        // The released one does not - it reports a bare "0.0.1" - and is
        // recognised by its marker or by the name in its banner instead, which
        // is singbox/runtime.uc's job, not this module's.
        version_contains: "-tachyon.",
        foreign_series: true,
        pin_field: "certificate_sha256",
        schema_1_14: "yes",
        schema_1_15: "yes",
        xhttp: "yes",
        tailscale: "yes"
    }
};

// Most specific first. See profile() for why the fallback cannot go first.
const CORE_PROFILE_PRECEDENCE = [ "tachyon-core", "extended-compressed", "extended", "lx" ];

// Every protocol Tachyon can put into a config, so the interface can say "this
// core cannot do that" instead of dropping the section silently. Mirrors
// rule_action_supported() in config/validator.uc - keep the two in step.
const TACHYON_PROTOCOLS = [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2",
    "tuic", "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
    "socks", "http", "wireguard", "awg", "openvpn", "masque", "fptn",
    "selector", "urltest", "cloudflared", "tailscale", "openconnect", "bridge" ];

// Read off the cores themselves rather than off their names: KNOWN_INBOUND_TYPES
// and KNOWN_OUTBOUND_TYPES in tachyon-core's crates/core-config/src/validate.rs,
// plus the documented extras of each fork.
const CORE_PROTOCOLS = {
    "upstream": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic",
        "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "selector", "urltest", "tailscale" ],
    "extended": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic",
        "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "awg", "masque", "selector", "urltest",
        "tailscale" ],
    "extended-compressed": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2",
        "tuic", "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "awg", "masque", "selector", "urltest",
        "tailscale" ],
    "lx": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic",
        "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "awg", "masque", "selector", "urltest",
        "tailscale" ],
    "tachyon-core": [ "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic",
        "hysteria", "anytls", "snell", "naive", "shadowtls", "ssh", "tor",
        "socks", "http", "wireguard", "awg", "warp", "openvpn", "masque", "fptn", "selector", "urltest",
        "cloudflared", "tailscale", "openconnect", "bridge" ]
};

// Inbound kinds, which are a separate question from protocols: a core can speak
// vless outbound and still not be able to hand traffic to the kernel that way.
// Tachyon needs both lists because it may have to refuse a feature for either
// reason, and "this core cannot" has to name which one.
const TACHYON_INBOUNDS = [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun" ];

// Every one of these cores is a sing-box descendant and carries a tun inbound, so
// the list is the same across them - but not the implementation, and that matters
// for what Tachyon may promise. Upstream and the forks run the tun stack on
// gVisor; our core runs it on smoltcp in userspace, which is why it keeps a
// tun0 with an MTU of 9000 and no connection reset on SYN. Tachyon therefore
// never writes a tun-specific expectation into the generated config - only
// fields every one of them accepts.
const CORE_INBOUNDS = {
    "upstream": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "shadowtls" ],
    "extended": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "anytls",
        "naive", "shadowtls", "fptn", "mtproto" ],
    "extended-compressed": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "anytls",
        "naive", "shadowtls", "fptn", "mtproto" ],
    "lx": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "shadowtls" ],
    "tachyon-core": [ "mixed", "direct", "redirect", "tproxy", "socks", "http", "tun",
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "anytls",
        "naive", "shadowtls", "fptn" ]
};

// Local, like every other module: core.common has no contains(), and the
// capability tables are the only thing here that needs one.
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

// major/minor of a version string, or null when there is none. Split rather than
// matched: ucode's match() returns the whole match and no capture groups, so
// match(/^([0-9]+).([0-9]+)/)[1] is null and a group-based parse silently
// compares 0.0.
function version_pair(value) {
    let text = trim(as_string(value));
    // "v1.16.1" is how every one of these builds prints itself, and int("v1") is
    // null rather than 1, so the prefix goes before parsing.
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

// Does a build reach a schema level? "1.14.2-lx.12" reaches 1.15: no. A core on
// its own version series reaches whatever its profile says it does.
function reaches(value, level) {
    let build = version_pair(as_string(value));
    let want = version_pair(as_string(level));
    if (build == null || want == null)
        return false;
    if (build[0] != want[0])
        return build[0] > want[0];
    return build[1] >= want[1];
}

function profile_matches_version(profile, version) {
    // A bare variant name ("sing-box-lx") carries no version, so nothing may be
    // concluded from it: reading lx's pin field off a name is how a core ends up
    // told it supports something it was never asked about.
    if (version_pair(version) == null)
        return false;
    let needle = as_string(profile.version_contains);
    if (needle != "")
        return index(as_string(version), needle) >= 0;
    return profile.marker == "";
}

// Which profile a version alone identifies, or "" when the version says nothing
// decisive. Our own core is the case that matters: a stale marker file says "lx"
// while the binary on disk says "-tachyon.", and the binary is the truth.
function profile_by_version(version) {
    for (let name in CORE_PROFILE_PRECEDENCE) {
        let entry = CORE_PROFILES[name];
        if (as_string(entry.marker) == "tachyon-core") {
            let needle = as_string(entry.version_contains);
            if (needle != "" && index(as_string(version), needle) >= 0)
                return name;
        }
    }
    return "";
}

// Which profile a version/marker pair belongs to. The marker decides when there
// is one, because a build does not always name itself; the version decides the
// rest. Our own core is only ever recognised by marker or by the banner name the
// caller passes in as the marker - its number alone says nothing.
function profile(version, marker) {
    version = as_string(version);
    marker = as_string(marker);

    if (marker != "") {
        for (let name, entry in CORE_PROFILES)
            if (entry.marker != "" && entry.marker == marker)
                return name;
    }
    for (let name in CORE_PROFILE_PRECEDENCE)
        if (profile_matches_version(CORE_PROFILES[name], version))
            return name;
    return "upstream";
}

function profile_data(name) {
    return type(CORE_PROFILES[name]) == "object" ? CORE_PROFILES[name] : CORE_PROFILES["upstream"];
}

// The TLS field this build accepts for a pin, or "" when it accepts none.
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
    return type(list) == "array" ? list : CORE_PROTOCOLS["upstream"];
}

function supports_protocol(protocol, version, marker) {
    return core_contains(protocols(version, marker), lc(trim(as_string(protocol))));
}

// Tachyon's protocols this core is missing, in Tachyon's own order so the
// interface renders a stable list.
function missing_protocols(supported) {
    let missing = [];
    for (let protocol in TACHYON_PROTOCOLS)
        if (!core_contains(supported, protocol))
            missing[length(missing)] = protocol;
    return missing;
}

function inbounds(version, marker) {
    let list = CORE_INBOUNDS[profile(version, marker)];
    return type(list) == "array" ? list : CORE_INBOUNDS["upstream"];
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

// The build-tag scan, as a pure string question: does this `sing-box version`
// output carry the tag? Tokenized rather than substring-matched, so "with_xhttp"
// does not match inside a longer word.
function output_has_build_tag(output, tag) {
    tag = as_string(tag);
    if (tag == "")
        return false;

    for (let token in split(trim(replace(as_string(output), /[,: \t\r\n]+/g, " ")), " "))
        if (as_string(token) == tag)
            return true;

    return false;
}

// The answer to one capability field for one build: true, false, or null when
// the answer lives in the binary's banner and the caller has not supplied it.
// Callers that get null run `sing-box version` themselves and settle it - this
// module never spawns anything, which is the whole reason it can be required
// from the generator and the validator, where requiring runtime.uc would run
// its command-line dispatch and kill the process.
//
// This is the one place that interprets a profile field. Before it existed the
// same question was answered by hand in runtime.uc, validator.uc and verifier.uc,
// and the three answers drifted apart the moment a new core shipped.
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
    reaches,
    version_pair
};