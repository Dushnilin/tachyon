#!/usr/bin/env ucode

let common = require("core.common");
let fs = require("fs");

const EMPTY_SRS_B64 = "U1JTAXjaYgAEAAD//wABAAE=";
const EMPTY_SRS_PATH = "/usr/share/tachyon/rulesets/empty.srs";

const SRS_MAIN_URL = "https://github.com/itdoginfo/allow-domains/releases/latest/download";
const SRS_ADS_HAGEZI_PRO_URL = "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs";
const SRS_SUPERCELL_URL = "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs";
const SRS_GITHUB_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs";
const SRS_TWITCH_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs";
const SRS_GEOIP_RU_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/ru.srs";
const SRS_GEOSITE_RU_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ru.srs";
const SRS_GEOIP_US_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/us.srs";
const SRS_GEOIP_CN_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs";

const COMMUNITY_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    ukraine_inside: true,
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
    google_meet: true
};

// Classification of community rule-sets based on upstream rule-set generation.
// Upstream allow-domains (itdoginfo/allow-domains convert.py) compiles:
// - general lists (russia_inside, russia_outside, ukraine_inside) and category lists as domain-only ("domains");
// - SUBNET_SERVICES (discord, meta, twitter, telegram, roblox, google_meet)
//   as mixed containing both domain_suffix and ip_cidr ("mixed");
// - infrastructure / CDN provider lists (cloudflare, cloudfront, hetzner, ovh, digitalocean) as IP subnets ("subnets").
//   In sing-box 1.14+, these must NOT be placed into DNS response rules (match_response: true) because doing so
//   causes arbitrary third-party domains hosted behind these CDNs/providers (e.g. mtpro.xyz) to be issued a FakeIP,
//   discarding the real IP and breaking routing to direct. They are routed purely by destination IP in route.rules.
// - geoip_* lists from MetaCubeX/meta-rules-dat contain only ip_cidr ("subnets");
// - geosite_* lists from MetaCubeX/meta-rules-dat contain only domains ("domains");
// - external lists (github, twitch, ads_hagezi_pro, supercell) are domain-only ("domains").
//
// In sing-box 1.14+, referencing a rule-set with ip_cidr in a DNS rule without match_response: true
// is treated as a deprecated legacy address filter and rejected if query_type is present in DNS configuration.
const COMMUNITY_SUBNET_SERVICES = {
    discord: true,
    meta: true,
    twitter: true,
    telegram: true,
    roblox: true,
    google_meet: true
};

const COMMUNITY_INFRASTRUCTURE_SERVICES = {
    cloudflare: true,
    cloudfront: true,
    hetzner: true,
    ovh: true,
    digitalocean: true
};

const COMMUNITY_DOMAIN_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    ukraine_inside: true,
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
    twitch: true
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

function community_url(name) {
    name = as_string(name);
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

    let geoip_match = match(name, /^geoip_([a-z]{2})$/);
    if (geoip_match)
        return "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/" + geoip_match[1] + ".srs";

    let geosite_match = match(name, /^geosite_([a-z]{2})$/);
    if (geosite_match)
        return "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/" + geosite_match[1] + ".srs";

    return SRS_MAIN_URL + "/" + name + ".srs";
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
        COMMUNITY_SERVICES,
        COMMUNITY_SUBNET_SERVICES,
        COMMUNITY_DOMAIN_SERVICES,
        COMMUNITY_INFRASTRUCTURE_SERVICES,
        is_community,
        community_url,
        community_kind,
        hash12,
        file_extension,
        kind_from_reference_hint,
        remote_format,
        is_plain_list_reference,
        is_valid_srs_file,
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
else if (mode == "ensure-empty-srs-stub")
    exit(ensure_empty_srs_stub(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: singbox/rulesets.uc <file-extension|is-community|community-kind|kind-from-reference-hint|remote-format|is-valid-srs-file|ensure-empty-srs-stub> ...\n");
    exit(1);
}