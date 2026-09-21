#!/usr/bin/env ucode
//
// Plain-text list catalog for the steer engine.
//
// sing-box consumes .srs / rule-set JSON, which steer does not understand. For
// steer we use the xyzmean/ru-bypass-ipsets catalog: ready-made plain-text
// lists (prefix lists as A.B.C.D/N, domain lists one name per line) plus a
// manifest (categories.json) that names them. This module downloads the
// manifest and the selected lists into the steer list directory and returns
// the file paths the spec generator should reference.
//
// The manifest shape (fields we rely on):
//   { base_url, categories: [{id, file, default_on, ...}],
//     domain_lists: [{id, file, kind, default_on, ...}] }
//

let fs = require("fs");
let common = require("core.common");
let helpers = require("components.helpers");
let downloader = require("components.downloader");

let as_string = common.as_string;
let file_exists = common.file_exists;

const CATALOG_REPO = getenv("TACHYON_STEER_LISTS_REPO") || "xyzmean/ru-bypass-ipsets";
const CATALOG_BASE = getenv("TACHYON_STEER_LISTS_BASE") ||
    "https://raw.githubusercontent.com/" + CATALOG_REPO + "/main/lists";
const CATALOG_MANIFEST_URL = CATALOG_BASE + "/categories.json";

// The catalog is written in plain text under the steer list directory; the
// steer keep.d entry covers lists/custom, so downloaded lists live here.
const STEER_LISTS_DIR = getenv("TACHYON_STEER_LISTS_DIR") || "/etc/steer/lists";
const STEER_DOMAINS_DIR = STEER_LISTS_DIR + "/domains";

// ============================================================================
// Manifest
// ============================================================================

function parse_manifest(text) {
    text = as_string(text);
    if (trim(text) == "")
        return null;
    try {
        let data = json(text);
        if (type(data) != "object")
            return null;
        return data;
    }
    catch (e) {
        return null;
    }
}

function fetch_manifest() {
    let text = downloader.http_get(CATALOG_MANIFEST_URL);
    return parse_manifest(text);
}

// Selected ids -> list of category entries. `wanted` empty means "default_on".
function select_categories(manifest, wanted) {
    let out = [];
    if (manifest == null)
        return out;
    let list = type(manifest.categories) == "array" ? manifest.categories : [];
    for (let entry in list) {
        if (type(entry) != "object")
            continue;
        let id = as_string(entry.id || "");
        if (id == "")
            continue;
        let selected = length(wanted) > 0 ? index(wanted, id) >= 0 : entry.default_on === true;
        if (!selected)
            continue;
        push(out, entry);
    }
    return out;
}

function select_domain_lists(manifest, wanted) {
    let out = [];
    if (manifest == null)
        return out;
    let list = type(manifest.domain_lists) == "array" ? manifest.domain_lists : [];
    for (let entry in list) {
        if (type(entry) != "object")
            continue;
        let id = as_string(entry.id || "");
        if (id == "")
            continue;
        let selected = length(wanted) > 0 ? index(wanted, id) >= 0 : entry.default_on === true;
        if (!selected)
            continue;
        push(out, entry);
    }
    return out;
}

// ============================================================================
// Download
// ============================================================================

function category_url(manifest, entry) {
    let base = manifest != null ? as_string(manifest.base_url || "") : "";
    if (base == "")
        base = CATALOG_BASE;
    return base + "/" + as_string(entry.file || "");
}

// Download one list to the steer directory. Returns the destination path, or
// "" on failure. Existing files are left in place when the download fails, so
// routing keeps working with the last good copy.
function download_list(manifest, entry, subdir) {
    let url = category_url(manifest, entry);
    let file = as_string(entry.file || "");
    if (url == "" || file == "")
        return "";

    let dest = STEER_LISTS_DIR + "/" + file;
    let dir = subdir != null && subdir != "" ? STEER_LISTS_DIR + "/" + subdir : replace(dest, /\/[^\/]*$/, "");
    if (dir != "")
        common.ensure_dir(dir);

    let text = downloader.http_get(url);
    if (trim(text) == "")
        return file_exists(dest) ? dest : "";

    let tmp = dest + ".tachyon.tmp";
    if (!common.write_file(tmp, text)) {
        common.remove_file(tmp);
        return file_exists(dest) ? dest : "";
    }
    if (!fs.rename(tmp, dest)) {
        common.remove_file(tmp);
        return file_exists(dest) ? dest : "";
    }
    return dest;
}

// ============================================================================
// Section list materialisation (steer-specific plain text)
// ============================================================================
//
// steer does not read sing-box rule-set JSON, so a section's domain/IP sources
// are converted into plain-text lists under the steer list directory. Sources:
//   user_domains / user_domains_text  -> inline domains
//   domain_ip_lists                   -> URL or local file with domains/CIDRs
//   community_lists / community_subnets -> catalog entries
// Domains match by suffix, prefixes are written as-is; both files are plain
// text, one entry per line.

const SECTION_LISTS_DIR = STEER_LISTS_DIR + "/channels";

function section_dir(section_name) {
    let safe = as_string(section_name);
    safe = replace(safe, /[^A-Za-z0-9_.-]/g, "_");
    if (safe == "")
        safe = "channel";
    return SECTION_LISTS_DIR + "/" + safe;
}

function text_list_values(value) {
    value = trim(as_string(value));
    if (value == "")
        return [];
    return split(value, /[,\s]+/);
}

function list_option(section, key) {
    if (section == null || section[key] == null)
        return [];
    let value = section[key];
    if (type(value) == "array")
        return value;
    return text_list_values(value);
}

function looks_like_domain(value) {
    value = as_string(value);
    if (value == "")
        return false;
    if (match(value, /^[0-9a-fA-F:.]+(\/[0-9]+)?$/) != null)
        return false;   // address or CIDR
    if (index(value, "/") == 0)
        return false;   // local path
    if (match(value, /^https?:\/\//) != null)
        return false;   // url
    return index(value, ".") >= 0 || index(value, "*") >= 0;
}

function looks_like_prefix(value) {
    value = as_string(value);
    return match(value, /^[0-9a-fA-F:.]+(\/[0-9]+)?$/) != null;
}

// Read a reference: local file if it starts with "/", otherwise download it.
function read_reference(reference) {
    reference = as_string(reference);
    if (reference == "")
        return "";
    if (substr(reference, 0, 1) == "/") {
        let data = fs.readfile(reference);
        return data != null ? as_string(data) : "";
    }
    return downloader.http_get(reference);
}

function option(section, key, fallback) {
    if (section == null || section[key] == null)
        return fallback;
    let value = section[key];
    if (type(value) == "array")
        return length(value) > 0 ? value[0] : fallback;
    return value;
}

// Collect domains and prefixes for one section and write the plain-text lists.
// Returns { domains: path|"", prefixes: path|"" }.
// Plain-text upstream for a community id, when we know one. steer cannot read
// sing-box .srs, but the same lists are published as text by their upstreams:
// itdoginfo/allow-domains for service categories, MetaCubeX .list for geoip/
// geosite. Returns "" when there is no known text source.
const ITDOGINFO_BASE = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main";
const METACUBEX_BASE = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo";

function community_text_url(name) {
    name = as_string(name);

    let geoip = match(name, /^geoip_([a-z]{2})$/);
    if (geoip)
        return METACUBEX_BASE + "/geoip/" + geoip[1] + ".list";
    let geosite = match(name, /^geosite_([a-z]{2})$/);
    if (geosite)
        return METACUBEX_BASE + "/geosite/" + geosite[1] + ".list";

    if (name == "supercell")
        return "";
    if (name == "ads_hagezi_pro")
        return "";

    // Service categories live in Categories/ for lists like
    // block/porn/news/anime, and in Services/ for youtube/tiktok/etc.
    // Try Categories first; callers fall back to Services on a failed fetch.
    return ITDOGINFO_BASE + "/Categories/" + name + ".lst";
}

function community_text_url_alt(name) {
    name = as_string(name);
    return ITDOGINFO_BASE + "/Services/" + name + ".lst";
}


function materialize_section_lists(section, catalog) {
    catalog = type(catalog) == "object" ? catalog : {};
    let name = as_string(section[".name"] || section.label || "channel");
    let dir = section_dir(name);
    common.ensure_dir(dir);

    let domains = {};
    let prefixes = {};

    // Inline user domains.
    for (let value in list_option(section, "user_domains"))
        domains[trim(as_string(value))] = true;
    for (let value in text_list_values(option(section, "user_domains_text", "")))
        domains[trim(as_string(value))] = true;
    for (let value in list_option(section, "user_subnets"))
        prefixes[trim(as_string(value))] = true;

    // External references: URLs or local files, split by entry type.
    for (let reference in list_option(section, "domain_ip_lists")) {
        let text = read_reference(reference);
        for (let line in split(as_string(text), "\n")) {
            line = trim(line);
            if (line == "" || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";")
                continue;
            if (looks_like_prefix(line))
                prefixes[line] = true;
            else if (looks_like_domain(line))
                domains[line] = true;
        }
    }

    // Community ids: prefer an explicit catalog file, otherwise fetch the
    // upstream plain-text list (steer cannot read .srs).
    for (let value in list_option(section, "community_lists")) {
        let mapped = catalog[value];
        let text = "";
        if (mapped != null)
            text = read_reference(mapped);
        if (trim(as_string(text)) == "") {
            let url = community_text_url(value);
            if (url != "")
                text = downloader.http_get(url);
            if (trim(as_string(text)) == "") {
                let alt = community_text_url_alt(value);
                if (alt != "")
                    text = downloader.http_get(alt);
            }
        }
        for (let line in split(as_string(text), "\n")) {
            line = trim(line);
            if (line != "" && substr(line, 0, 1) != "#")
                domains[line] = true;
        }
    }
    for (let value in list_option(section, "community_subnets")) {
        let mapped = catalog[value];
        let text = "";
        if (mapped != null)
            text = read_reference(mapped);
        if (trim(as_string(text)) == "") {
            let url = community_text_url(value);
            if (url != "")
                text = downloader.http_get(url);
        }
        for (let line in split(as_string(text), "\n")) {
            line = trim(line);
            if (line == "" || substr(line, 0, 1) == "#")
                continue;
            if (looks_like_prefix(line))
                prefixes[line] = true;
            else if (looks_like_domain(line))
                domains[line] = true;
        }
    }

    let result = { domains: "", prefixes: "" };
    if (length(keys(domains)) > 0) {
        let path = dir + "/domains.lst";
        if (common.write_file(path, join("\n", sort(keys(domains))) + "\n"))
            result.domains = path;
    }
    if (length(keys(prefixes)) > 0) {
        let path = dir + "/prefixes.lst";
        if (common.write_file(path, join("\n", sort(keys(prefixes))) + "\n"))
            result.prefixes = path;
    }
    return result;
}

function sync(opts) {
    opts = type(opts) == "object" ? opts : {};
    let manifest = fetch_manifest();
    if (manifest == null)
        return { ok: false, reason: "manifest_unavailable", prefixes: [], domains: [] };

    let prefixes = [];
    let domains = [];

    for (let entry in select_categories(manifest, opts.categories || [])) {
        let path = download_list(manifest, entry, "");
        if (path != "")
            push(prefixes, path);
    }
    for (let entry in select_domain_lists(manifest, opts.domains || [])) {
        let path = download_list(manifest, entry, "domains");
        if (path != "")
            push(domains, path);
    }

    return { ok: true, reason: "", prefixes, domains, manifest };
}

// ============================================================================
// Module exports
// ============================================================================

function module_exports() {
    return {
        CATALOG_BASE,
        CATALOG_MANIFEST_URL,
        STEER_LISTS_DIR,
        STEER_DOMAINS_DIR,
        parse_manifest,
        fetch_manifest,
        select_categories,
        select_domain_lists,
        category_url,
        materialize_section_lists,
        SECTION_LISTS_DIR,
        download_list,
        sync
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/lists.uc (library module, no CLI)\n");
exit(1);
