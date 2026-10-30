#!/usr/bin/env ucode

let common = require("core.common");
let fs = require("fs");
let gomemlimit = require("core.gomemlimit");
let command_from_args = common.command_from_args;

const EMPTY_SRS_B64 = "U1JTAXjaYgAEAAD//wABAAE=";
const EMPTY_SRS_PATH = "/usr/share/tachyon/rulesets/empty.srs";
// Decoded length of the placeholder above. Derived so the two cannot drift.
const EMPTY_SRS_SIZE = 17;

const SRS_MAIN_URL = "https://github.com/itdoginfo/allow-domains/releases/latest/download";
const SRS_ADS_HAGEZI_PRO_URL = "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs";
const SRS_SUPERCELL_URL = "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs";
const SRS_GITHUB_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs";
const SRS_TWITCH_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs";
const SRS_GEOIP_RU_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/ru.srs";
const SRS_GEOSITE_RU_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ru.srs";
const SRS_GEOIP_US_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/us.srs";
const SRS_GEOIP_CN_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs";
const SRS_TACHYON_LISTS_BASE = "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/sing-box";
const TRS_TACHYON_LISTS_BASE = "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/tachyon";
const SRS_ROSCOMVPN_GEOSITE_BASE = "https://raw.githubusercontent.com/hydraponique/roscomvpn-geosite/master/release/sing-box";
const SRS_RUNETFREEDOM_GEOSITE_BASE = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite";

const ROSCOMVPN_GEOSITE_MAP = {
    ru_whitelist: "whitelist",
    ru_domains: "category-ru",
    push: "push",
    roscomvpn_whitelist: "whitelist",
    roscomvpn_geoblock: "category-geoblock-ru",
    roscomvpn_ru: "category-ru",
    roscomvpn_push: "push",
    apple: "apple",
    microsoft: "microsoft",
    win_spy: "win-spy",
    steam: "steam",
    epicgames: "epicgames",
    riot: "riot",
    origin: "origin",
    escapefromtarkov: "escapefromtarkov",
    faceit: "faceit",
    pinterest: "pinterest",
    torrent: "torrent",
    twitch_ads: "twitch-ads"
};

const RUNETFREEDOM_GEOSITE_MAP = {
    ru_blocked: "geosite-ru-blocked",
    ru_blocked_all: "geosite-ru-blocked-all",
    antifilter: "geosite-antifilter-download-community",
    ru_only_inside: "geosite-ru-available-only-inside",
    runetfreedom_blocked: "geosite-ru-blocked",
    runetfreedom_blocked_all: "geosite-ru-blocked-all",
    antifilter_community: "geosite-antifilter-download-community",
    refilter: "geosite-refilter",
    ru_available_only_inside: "geosite-ru-available-only-inside",
    ai_all: "geosite-category-ai-!cn",
    openai: "geosite-openai",
    anthropic: "geosite-anthropic",
    xai: "geosite-xai",
    spotify: "geosite-spotify",
    netflix: "geosite-netflix",
    docker: "geosite-docker",
    tor: "geosite-tor",
    fastly: "geosite-fastly"
};

const COMMUNITY_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    geoblock: true,
    block: true,
    porn: true,
    news: true,
    anime: true,
    youtube: true,
    hdrezka: true,
    tiktok: true,
    google_ai: true,
    google_play: true,
    hodca: true,
    discord: true,
    meta: true,
    twitter: true,
    cloudflare: true,
    cloudfront: true,
    digitalocean: true,
    hetzner: true,
    ovh: true,
    telegram: true,
    roblox: true,
    ads_hagezi_pro: true,
    supercell: true,
    github: true,
    twitch: true,
    geoip_ru: true,
    geosite_ru: true,
    geoip_us: true,
    geoip_cn: true,
    google_meet: true,
    ru_whitelist: true,
    ru_domains: true,
    ru_only_inside: true,
    push: true,
    ru_blocked: true,
    ru_blocked_all: true,
    antifilter: true,
    refilter: true,
    roscomvpn_whitelist: true,
    roscomvpn_geoblock: true,
    roscomvpn_ru: true,
    roscomvpn_push: true,
    apple: true,
    microsoft: true,
    win_spy: true,
    steam: true,
    epicgames: true,
    riot: true,
    origin: true,
    escapefromtarkov: true,
    faceit: true,
    pinterest: true,
    torrent: true,
    twitch_ads: true,
    runetfreedom_blocked: true,
    runetfreedom_blocked_all: true,
    antifilter_community: true,
    ru_available_only_inside: true,
    ai_all: true,
    openai: true,
    anthropic: true,
    xai: true,
    spotify: true,
    netflix: true,
    docker: true,
    tor: true,
    fastly: true
};

// Classification of community rule-sets based on upstream rule-set generation.
// Upstream allow-domains (itdoginfo/allow-domains convert.py) compiles:
// - general lists (russia_inside, russia_outside) and category lists as domain-only ("domains");
// - SUBNET_SERVICES (meta, twitter, telegram, roblox, google_meet)
//   as mixed containing both domain_suffix and ip_cidr ("mixed");
// - infrastructure / CDN provider lists (cloudflare, cloudfront, hetzner, ovh, digitalocean) as IP subnets ("subnets").
//   In sing-box 1.14+, these must NOT be placed into DNS response rules (match_response: true) because doing so
//   causes arbitrary third-party domains hosted behind these CDNs/providers (e.g. mtpro.xyz) to be issued a FakeIP,
//   discarding the real IP and breaking routing to direct. They are routed purely by destination IP in route.rules.
// - discord is also treated as subnets: its voice endpoints use Cloudflare Anycast with UDP QUIC (port 443).
//   FakeIP-ing Discord IP-in-DNS-response causes sing-box to dial tcp for UDP QUIC sessions → i/o timeout.
// - geoip_* lists from MetaCubeX/meta-rules-dat contain only ip_cidr ("subnets");
// - geosite_* lists from MetaCubeX/meta-rules-dat contain only domains ("domains");
// - external lists (github, twitch, ads_hagezi_pro, supercell) are domain-only ("domains").
//
// In sing-box 1.14+, referencing a rule-set with ip_cidr in a DNS rule without match_response: true
// is treated as a deprecated legacy address filter and rejected if query_type is present in DNS configuration.
const COMMUNITY_SUBNET_SERVICES = {
    meta: true,
    twitter: true,
    telegram: true,
    roblox: true,
    google_meet: true
};

const COMMUNITY_INFRASTRUCTURE_SERVICES = {
    discord: true,
    cloudflare: true,
    cloudfront: true,
    hetzner: true,
    ovh: true,
    digitalocean: true
};

const COMMUNITY_DOMAIN_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    geoblock: true,
    block: true,
    porn: true,
    news: true,
    anime: true,
    youtube: true,
    hdrezka: true,
    tiktok: true,
    google_ai: true,
    google_play: true,
    hodca: true,
    ads_hagezi_pro: true,
    supercell: true,
    github: true,
    twitch: true,
    ru_whitelist: true,
    ru_domains: true,
    ru_only_inside: true,
    push: true,
    ru_blocked: true,
    ru_blocked_all: true,
    antifilter: true,
    refilter: true,
    roscomvpn_whitelist: true,
    roscomvpn_geoblock: true,
    roscomvpn_ru: true,
    roscomvpn_push: true,
    apple: true,
    microsoft: true,
    win_spy: true,
    steam: true,
    epicgames: true,
    riot: true,
    origin: true,
    escapefromtarkov: true,
    faceit: true,
    pinterest: true,
    torrent: true,
    twitch_ads: true,
    runetfreedom_blocked: true,
    runetfreedom_blocked_all: true,
    antifilter_community: true,
    ru_available_only_inside: true,
    ai_all: true,
    openai: true,
    anthropic: true,
    xai: true,
    spotify: true,
    netflix: true,
    docker: true,
    tor: true,
    fastly: true
};

let as_string = common.as_string;

function is_community(name) {
    name = as_string(name);
    if (COMMUNITY_SERVICES[name] === true)
        return true;
    if (match(name, /^geoip_[a-z]{2}$/) != null || match(name, /^geosite_[a-z]{2}$/) != null)
        return true;
    return false;
}

function community_kind(name) {
    name = as_string(name);
    if (match(name, /^geoip_[a-z]{2}$/) != null)
        return "subnets";
    if (match(name, /^geosite_[a-z]{2}$/) != null)
        return "domains";
    if (COMMUNITY_INFRASTRUCTURE_SERVICES[name] === true)
        return "subnets";
    if (COMMUNITY_SUBNET_SERVICES[name] === true)
        return "mixed";
    if (COMMUNITY_DOMAIN_SERVICES[name] === true)
        return "domains";
    return "unknown";
}

const TACHYON_LISTS_ALIAS_MAP = {
    roscomvpn_whitelist: "ru_whitelist",
    roscomvpn_geoblock: "geoblock",
    roscomvpn_ru: "ru_domains",
    roscomvpn_push: "push",
    runetfreedom_blocked: "ru_blocked",
    runetfreedom_blocked_all: "ru_blocked_all",
    antifilter_community: "antifilter",
    ru_available_only_inside: "ru_only_inside"
};

function should_compact_huge_ruleset(name) {
    name = as_string(name);
    if (name != "ru_blocked_all" && name != "runetfreedom_blocked_all")
        return false;
    if (getenv("TACHYON_FORCE_FULL_RULESETS") == "1")
        return false;
    if (getenv("TACHYON_COMPACT_HUGE_RULESETS") == "1")
        return true;
    let total_kb = gomemlimit.mem_total_kb();
    if (total_kb > 0 && total_kb < 786432)
        return true;
    return false;
}

function tachyon_lists_srs_url(name) {
    name = as_string(name);
    if (should_compact_huge_ruleset(name))
        name = "ru_blocked";
    let canonical = TACHYON_LISTS_ALIAS_MAP[name] || name;
    let custom_base = as_string(getenv("TACHYON_LISTS_SRS_URL") || "");
    if (custom_base != "")
        return replace(custom_base, /\/+$/, "") + "/" + canonical + ".srs";
    return SRS_TACHYON_LISTS_BASE + "/" + canonical + ".srs";
}

function tachyon_lists_trs_url(name) {
    name = as_string(name);
    if (should_compact_huge_ruleset(name))
        name = "ru_blocked";
    let canonical = TACHYON_LISTS_ALIAS_MAP[name] || name;
    let custom_base = as_string(getenv("TACHYON_LISTS_TRS_URL") || "");
    if (custom_base != "")
        return replace(custom_base, /\/+$/, "") + "/" + canonical + ".trs";
    let custom_srs_base = as_string(getenv("TACHYON_LISTS_SRS_URL") || "");
    if (custom_srs_base != "")
        return replace(custom_srs_base, /\/+$/, "") + "/" + canonical + ".trs";
    return TRS_TACHYON_LISTS_BASE + "/" + canonical + ".trs";
}

function community_trs_url(name) {
    name = as_string(name);
    if (COMMUNITY_SERVICES[name] === true)
        return tachyon_lists_trs_url(name);
    return "";
}

function community_trs_urls(name) {
    name = as_string(name);
    if (COMMUNITY_SERVICES[name] !== true)
        return [];
    if (should_compact_huge_ruleset(name))
        name = "ru_blocked";
    let canonical = TACHYON_LISTS_ALIAS_MAP[name] || name;
    let custom_trs = as_string(getenv("TACHYON_LISTS_TRS_URL") || "");
    if (custom_trs != "")
        return [ replace(custom_trs, /\/+$/, "") + "/" + canonical + ".trs" ];
    let custom_srs = as_string(getenv("TACHYON_LISTS_SRS_URL") || "");
    if (custom_srs != "")
        return [ replace(custom_srs, /\/+$/, "") + "/" + canonical + ".trs" ];
    return [
        TRS_TACHYON_LISTS_BASE + "/" + canonical + ".trs"
    ];
}

function supports_trs() {
    if (getenv("TACHYON_DISABLE_TRS") == "1")
        return false;
    if (getenv("TACHYON_ALLOW_TRS") == "1")
        return true;
    let bin = getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/tachyon-core";
    if (fs.stat(bin) != null)
        return true;
    let variant = trim(as_string(fs.readfile("/etc/tachyon/sing-box-variant")));
    return variant == "tachyon-core";
}

function fallback_community_url(name) {
    name = as_string(name);
    if (should_compact_huge_ruleset(name))
        name = "ru_blocked";
    if (name == "ads_hagezi_pro")
        return SRS_ADS_HAGEZI_PRO_URL;
    if (name == "supercell")
        return SRS_SUPERCELL_URL;
    if (name == "github")
        return SRS_GITHUB_URL;
    if (name == "twitch")
        return SRS_TWITCH_URL;
    if (name == "geosite_ru")
        return SRS_GEOSITE_RU_URL;
    if (ROSCOMVPN_GEOSITE_MAP[name] != null)
        return SRS_ROSCOMVPN_GEOSITE_BASE + "/" + ROSCOMVPN_GEOSITE_MAP[name] + ".srs";
    if (RUNETFREEDOM_GEOSITE_MAP[name] != null)
        return SRS_RUNETFREEDOM_GEOSITE_BASE + "/" + RUNETFREEDOM_GEOSITE_MAP[name] + ".srs";

    let geoip_match = match(name, /^geoip_([a-z]{2})$/);
    if (geoip_match)
        return "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/" + geoip_match[1] + ".srs";

    let geosite_match = match(name, /^geosite_([a-z]{2})$/);
    if (geosite_match)
        return "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/" + geosite_match[1] + ".srs";

    return SRS_MAIN_URL + "/" + name + ".srs";
}

function community_url(name) {
    name = as_string(name);
    if (COMMUNITY_SERVICES[name] === true)
        return tachyon_lists_srs_url(name);

    return fallback_community_url(name);
}

function hash12(value) {
    value = as_string(value);
    let first = 2166136261;
    let second = 16777619;

    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        first = (first * 33 + code) % 4294967296;
        second = (second * 131 + code) % 4294967296;
    }

    return sprintf("%06x%06x", first % 16777216, second % 16777216);
}

function file_extension(value) {
    let basename = as_string(value);
    let slash = rindex(basename, "/");
    if (slash >= 0)
        basename = substr(basename, slash + 1);

    let query = index(basename, "?");
    if (query >= 0)
        basename = substr(basename, 0, query);

    let fragment = index(basename, "#");
    if (fragment >= 0)
        basename = substr(basename, 0, fragment);

    let dot = rindex(basename, ".");
    return dot >= 0 ? lc(substr(basename, dot + 1)) : "";
}

function kind_from_reference_hint(reference) {
    reference = lc(as_string(reference));
    let has_ip_hint = index(reference, "geoip") >= 0 ||
        index(reference, "subnet") >= 0 ||
        index(reference, "subnets") >= 0 ||
        index(reference, "cidr") >= 0 ||
        match(reference, /(^|[-_.\/])ips?([-_.\/]|$)/) != null;

    let has_domain_hint = index(reference, "geosite") >= 0 ||
        index(reference, "domain") >= 0 ||
        index(reference, "domains") >= 0 ||
        index(reference, "adguard") >= 0 ||
        index(reference, "adblock") >= 0 ||
        index(reference, "host") >= 0 ||
        index(reference, "hosts") >= 0;

    if (has_ip_hint && has_domain_hint)
        return "mixed";
    if (has_ip_hint)
        return "subnets";
    if (has_domain_hint)
        return "domains";
    return "unknown";
}

function remote_format(reference) {
    return file_extension(reference) == "json" ? "source" : "binary";
}

function is_plain_list_reference(reference) {
    let extension = file_extension(reference);
    return extension == "lst" || extension == "txt";
}

function is_valid_srs_file(path) {
    let p = as_string(path);
    let st = fs.stat(p);
    if (!st || st.size < 17)
        return false;
    let f = fs.open(p, "r");
    if (!f)
        return false;
    let magic = f.read(3);
    f.close();
    return magic == "SRS";
}

function is_valid_trs_file(path) {
    let p = as_string(path);
    let st = fs.stat(p);
    if (!st || st.size < 8)
        return false;
    let f = fs.open(p, "r");
    if (!f)
        return false;
    let magic = f.read(4);
    f.close();
    if (!magic || length(magic) < 3)
        return false;
    let m3 = substr(magic, 0, 3);
    return m3 == "TRS" || magic == "TSRS" || magic == "TCRS";
}

function is_usable_trs_file(path) {
    let p = as_string(path);
    let st = fs.stat(p);
    if (!st || st.size < 16)
        return false;
    return is_valid_trs_file(p);
}

function is_referenceable_trs_file(path) {
    return is_usable_trs_file(path);
}

// The placeholder this module writes when a list cannot be fetched is itself a
// syntactically valid SRS of exactly 17 bytes, so is_valid_srs_file() accepts
// it. Callers that mean "a real list is present locally" therefore treat the
// placeholder as downloaded: the generator emits `type: local` with no url, so
// sing-box can never fetch the real list again and the rule silently matches
// nothing. A block rule over an empty list is indistinguishable from no rule at
// all (TCH-1043), and the only recovery was a manual list update.
//
// So: a file the size of the placeholder is the placeholder, whatever the
// magic bytes say. Callers that only need "not corrupt" keep using
// is_valid_srs_file; callers that need "actually populated" use this.
// Every cheap measure of an .srs passes on a truncated one: the magic sits at the
// front and a partial file is still larger than the placeholder. sing-box then dies
// with "parse rule-set: read rule: unexpected EOF" and takes the whole generated
// config down with it, which leaves the router unapplyable - a red check that no
// list update can clear, reported on 1.4.9.
//
// The payload is a zlib stream, so its real length cannot be read off the header
// and a size comparison cannot tell a whole file from a prefix of one. Ask
// sing-box, which is already a dependency, to parse it. One process per list, only
// on the paths that adopt a file, never per generate.
function srs_file_parses(path) {
    let p = as_string(path);
    if (!is_valid_srs_file(p))
        return false;

    let st = fs.stat(p);
    if (st && int(st.size || 0) > 2097152) {
        let total_kb = gomemlimit.mem_total_kb();
        if (total_kb > 0 && total_kb < 786432)
            return true;
    }

    let bin = getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/tachyon-core";
    if (fs.stat(bin) == null)
        return true;

    // rule-set match is a second Go runtime next to the running daemon; without
    // a ceiling it is free to balloon exactly like `check` does.
    return common.command_status(
        gomemlimit.gomemlimit_env() +
        command_from_args([ bin, "rule-set", "match", "--format", "binary", p, "tachyon-validation.invalid" ]) +
        " >/dev/null"
    ) == 0;
}

function is_populated_srs_file(path) {
    let p = as_string(path);
    let st = fs.stat(p);
    if (!st || st.size <= EMPTY_SRS_SIZE)
        return false;
    return is_valid_srs_file(p);
}

// "Usable" is the question callers actually mean when they keep a file: whole,
// and not the placeholder. is_valid_srs_file() answers "not corrupt" and is kept
// for the callers that need exactly that.
function is_usable_srs_file(path) {
    return is_populated_srs_file(path) && srs_file_parses(path);
}

// Verifying means spawning sing-box, so remember what has already been verified
// and skip the spawn while the file is the same one we checked. The marker sits in
// tmpfs next to the files it describes, so it cannot outlive them and no verdict
// survives the file changing underneath it - which is also why the stamp carries
// the mtime and not just the size: a rewrite can land the same length.
const SRS_VERIFY_DIR = getenv("TACHYON_SRS_VERIFY_DIR") || "/tmp/.tachyon-srs-verified";

function srs_verify_marker_path(path) {
    return SRS_VERIFY_DIR + "/" + hash12(as_string(path)) + ".ok";
}

function srs_file_stamp(path) {
    let st = fs.stat(as_string(path));
    if (st == null)
        return "";
    return int(st.size) + ":" + int(st.mtime);
}

function srs_file_already_verified(path) {
    let stamp = srs_file_stamp(path);
    if (stamp == "")
        return false;
    let marker = fs.readfile(srs_verify_marker_path(path));
    return marker != null && trim(as_string(marker)) == stamp;
}

function remember_srs_file_verified(path) {
    let stamp = srs_file_stamp(path);
    if (stamp == "")
        return;
    try {
        common.ensure_dir(SRS_VERIFY_DIR);
        common.write_file(srs_verify_marker_path(path), stamp + "\n");
    } catch (e) {}
}

// The check for a file we are about to keep but have maybe already checked. The
// /tmp copy used to be trusted outright, which left a file downloaded by an older
// Tachyon in place forever: it passed the cheap test, sing-box died on it, and no
// apply could recover because the copy that was broken was the one believed.
function is_adoptable_srs_file(path) {
    if (!is_populated_srs_file(path))
        return false;
    if (srs_file_already_verified(path))
        return true;
    if (!srs_file_parses(path))
        return false;
    remember_srs_file_verified(path);
    return true;
}

// Whether a generated config may point at this file. That needs sing-box to be
// able to read it, and it is not the same question as "is a real list here": the
// placeholder is a valid, parseable SRS that simply matches nothing, and it exists
// so a cold boot without a network still applies. Referencing it locally is right;
// emitting a remote rule-set instead puts the fetch back into sing-box's startup,
// and a GitHub hiccup then kills the core with "initialize rule-set: context
// deadline exceeded" - the failure prepare_community_rulesets() exists to avoid.
//
// A truncated list is the opposite case: valid magic, larger than the placeholder,
// and unreadable. It must never be referenced, so the generator falls through to
// the remote branch and sing-box fetches a whole list itself.
function is_referenceable_srs_file(path) {
    let p = as_string(path);
    if (!is_valid_srs_file(p))
        return false;
    if (!is_populated_srs_file(p))
        return true;
    return is_adoptable_srs_file(p);
}

function ensure_empty_srs_stub(target_path) {
    target_path = as_string(target_path);
    if (is_valid_srs_file(target_path))
        return true;

    let slash = rindex(target_path, "/");
    if (slash > 0)
        common.ensure_dir(substr(target_path, 0, slash));

    if (is_valid_srs_file(EMPTY_SRS_PATH)) {
        let content = fs.readfile(EMPTY_SRS_PATH);
        if (content && fs.writefile(target_path, content) != null)
            return true;
    }

    let b = b64dec(EMPTY_SRS_B64);
    if (b && fs.writefile(target_path, b) != null)
        return true;

    return false;
}

function module_exports() {
    return {
        EMPTY_SRS_PATH,
        EMPTY_SRS_B64,
        EMPTY_SRS_SIZE,
        COMMUNITY_SERVICES,
        COMMUNITY_SUBNET_SERVICES,
        COMMUNITY_DOMAIN_SERVICES,
        COMMUNITY_INFRASTRUCTURE_SERVICES,
        is_community,
        should_compact_huge_ruleset,
        tachyon_lists_srs_url,
        tachyon_lists_trs_url,
        community_trs_url,
        community_trs_urls,
        supports_trs,
        fallback_community_url,
        community_url,
        community_kind,
        hash12,
        file_extension,
        kind_from_reference_hint,
        remote_format,
        is_plain_list_reference,
        is_valid_srs_file,
        is_valid_trs_file,
        is_usable_trs_file,
        is_referenceable_trs_file,
        is_populated_srs_file,
        srs_file_parses,
        srs_file_already_verified,
        remember_srs_file_verified,
        is_usable_srs_file,
        is_adoptable_srs_file,
        is_referenceable_srs_file,
        ensure_empty_srs_stub
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "file-extension")
    print(file_extension(ARGV[1]), "\n");
else if (mode == "is-community")
    exit(is_community(ARGV[1]) ? 0 : 1);
else if (mode == "community-kind")
    print(community_kind(ARGV[1]), "\n");
else if (mode == "kind-from-reference-hint")
    print(kind_from_reference_hint(ARGV[1]), "\n");
else if (mode == "remote-format")
    print(remote_format(ARGV[1]), "\n");
else if (mode == "is-plain-list-reference")
    exit(is_plain_list_reference(ARGV[1]) ? 0 : 1);
else if (mode == "is-valid-srs-file")
    exit(is_valid_srs_file(ARGV[1]) ? 0 : 1);
else if (mode == "is-usable-srs-file")
    exit(is_usable_srs_file(ARGV[1]) ? 0 : 1);
else if (mode == "is-adoptable-srs-file")
    exit(is_adoptable_srs_file(ARGV[1]) ? 0 : 1);
else if (mode == "is-referenceable-srs-file")
    exit(is_referenceable_srs_file(ARGV[1]) ? 0 : 1);
else if (mode == "ensure-empty-srs-stub")
    exit(ensure_empty_srs_stub(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: singbox/rulesets.uc <file-extension|is-community|community-kind|kind-from-reference-hint|remote-format|is-valid-srs-file|is-usable-srs-file|is-adoptable-srs-file|is-referenceable-srs-file|ensure-empty-srs-stub> ...\n");
    exit(1);
}