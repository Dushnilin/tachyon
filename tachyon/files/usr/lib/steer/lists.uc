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

// Download the selected catalog entries. Returns { prefixes: [...], domains: [...] }
// with absolute file paths suitable for a steer channel's prefixes_files /
// domains_files.
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
        download_list,
        sync
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/lists.uc (library module, no CLI)\n");
exit(1);
