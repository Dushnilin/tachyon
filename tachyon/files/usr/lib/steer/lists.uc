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
let engine = require("core.engine");

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
// Per-section subscription files. The single /etc/steer/sub.txt would be
// overwritten by every subscription section in turn, so with two or more
// sections all vless outputs ended up reading the same (last) node list. The
// steer keep.d covers the subs/ directory, so the files survive sysupgrade.
const STEER_SUBS_DIR = getenv("TACHYON_STEER_SUBS_DIR") || "/etc/steer/subs";
// Tachyon caches parsed subscription outbounds here; the `links` map holds the
// original share links (vless:// etc), which is exactly what steer's sub.txt
// expects.
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") ||
    (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/section-cache";

// Write the section's VLESS/Reality nodes to steer's subscription file.
// Returns the destination path on success, "" when the section has no usable
// subscription nodes. steer-extended reads this file for `kind: vless` outputs.
function write_subscription_file(section_name) {
    section_name = as_string(section_name);
    if (section_name == "")
        return "";
    let cache_path = SECTION_CACHE_DIR + "/" + section_name + ".json";
    let data = fs.readfile(cache_path);
    if (data == null)
        return "";
    let parsed = null;
    try {
        parsed = json(as_string(data));
    }
    catch (e) {
        return "";
    }
    if (type(parsed) != "object" || type(parsed.links) != "object")
        return "";

    // 1. URLTest group outbounds in order
    let lines = [];
    let seen = {};
    if (type(parsed.urltestGroups) == "object") {
        for (let grp_id, grp in parsed.urltestGroups) {
            if (type(grp) == "object" && type(grp.outbounds) == "array") {
                for (let ob in grp.outbounds) {
                    let link = parsed.links[ob];
                    if (link != null && match(trim(as_string(link)), /^vless:\/\//) != null && !seen[ob]) {
                        push(lines, trim(as_string(link)));
                        seen[ob] = true;
                    }
                }
            }
        }
    }

    // 2. Non-hidden links that were not already added from the urltest groups.
    let hidden = type(parsed.hiddenOutboundTags) == "object" ? parsed.hiddenOutboundTags : {};
    for (let name, link in parsed.links) {
        if (seen[name] || hidden[name]) continue;
        link = trim(as_string(link));
        if (match(link, /^vless:\/\//) != null) {
            push(lines, link);
            seen[name] = true;
        }
    }

    // 3. Remaining links (hidden detour variants)
    for (let name, link in parsed.links) {
        if (seen[name]) continue;
        link = trim(as_string(link));
        if (match(link, /^vless:\/\//) != null) {
            push(lines, link);
            seen[name] = true;
        }
    }


    if (length(lines) == 0)
        return "";

    let safe = replace(section_name, /[^A-Za-z0-9_.-]/g, "_");
    if (safe == "")
        safe = "subscription";
    let sub_file = STEER_SUBS_DIR + "/" + safe + ".txt";
    let dir = replace(sub_file, /\/[^\/]*$/, "");
    if (dir != "")
        common.ensure_dir(dir);
    if (!common.write_file(sub_file, join("\n", lines) + "\n"))
        return "";
    return sub_file;
}

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
    return split(value, /[ \t\r\n,]+/);
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
    return ITDOGINFO_BASE + "/Categories/" + name + ".lst";
}

function community_text_url_alt(name) {
    name = as_string(name);
    return ITDOGINFO_BASE + "/Services/" + name + ".lst";
}

const RULESETS_DIR = "/etc/tachyon/rulesets";
const CACHE_LISTS_DIR = STEER_LISTS_DIR + "/cache";

function is_zapret_section(section) {
    let action = as_string(option(section, "action", ""));
    return action == "zapret" || action == "zapret2";
}

// Provider default strategy for a zapret/zapret2 section (used when the section
// carries no user strategy of its own).
function default_zapret_strategy(section) {
    let is_z2 = as_string(option(section, "action", "")) == "zapret2";
    let option_name = is_z2 ? "ZAPRET2_DEFAULT_NFQWS2_OPT" : "ZAPRET_DEFAULT_NFQWS_OPT";
    let value = getenv(option_name);
    if (trim(as_string(value)) == "") {
        try {
            let constants = require("core.constants");
            value = constants[option_name];
        }
        catch (e) {
            value = "";
        }
    }
    return trim(as_string(value));
}

// The opts file for the steer-nfqws wrapper must contain the FULL effective
// command line, not just the user strategy. The sing-box path starts the binary
// with provider base args around the strategy:
//   --lua-init=@zapret-lib.lua ...   (without them --lua-desync strategies have
//                                     no Lua runtime and silently do nothing)
//   --blob=<name>:@<file>            (external fake blobs, e.g. discord_udp)
//   --filter-tcp=443 --filter-l7=tls (default filter when strategy has none)
// Only the fwmark arg is dropped: the wrapper marks packets with steer's own
// ZAPRET_OWN_MARK, not the sing-box desync mark.
function zapret_opts_lines(section) {
    let is_z2 = as_string(option(section, "action", "")) == "zapret2";
    let provider = null;
    try {
        provider = require(is_z2 ? "providers.zapret2.common" : "providers.zapret.common").config({});
    }
    catch (e) {
        provider = null;
    }

    let strategy_option = provider != null ? provider.strategy_option : (is_z2 ? "nfqws2_opt" : "nfqws_opt");
    let zapret_opt = trim(as_string(option(section, strategy_option, "")));
    if (zapret_opt == "")
        zapret_opt = provider != null ? trim(as_string(provider.default_strategy)) : default_zapret_strategy(section);
    if (zapret_opt == "")
        return [];

    let lines = [];
    // If the strategy string already embeds --lua-init references (e.g. saved
    // from fuzzer runs that inlined them), skip adding them from base_args to
    // avoid duplicating the Lua scripts in the opts file. steer-nfqws passes
    // every non-comment line as a separate argument, so duplicates would cause
    // nfqws2 to load the same Lua file twice and emit confusing errors.
    let strategy_has_lua = (index(zapret_opt, "--lua-init") >= 0);

    if (provider != null) {
        for (let arg in (provider.base_args || [])) {
            arg = as_string(arg);
            // Drop fwmark: steer-nfqws uses its own ZAPRET_OWN_MARK.
            if (index(arg, "--fwmark") == 0 || index(arg, "--dpi-desync-fwmark") == 0)
                continue;
            // Skip lua-init from base_args when already present in strategy.
            if (strategy_has_lua && index(arg, "--lua-init") == 0)
                continue;
            if (trim(arg) != "")
                push(lines, arg);
        }
        if (type(provider.prepare_strategy_args) == "function") {
            for (let arg in provider.prepare_strategy_args(zapret_opt)) {
                arg = trim(as_string(arg));
                if (arg != "")
                    push(lines, arg);
            }
        }
    }
    push(lines, zapret_opt);
    return lines;
}

function parse_raw_lines(raw_val) {
    let result = [];
    if (raw_val == null) return result;
    let items = type(raw_val) == "array" ? raw_val : [ raw_val ];
    for (let item in items) {
        for (let line in split(as_string(item), "\n")) {
            line = trim(line);
            if (line == "" || substr(line, 0, 2) == "//" || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";")
                continue;
            let comment_idx = index(line, "//");
            if (comment_idx > 0)
                line = trim(substr(line, 0, comment_idx));
            comment_idx = index(line, " #");
            if (comment_idx > 0)
                line = trim(substr(line, 0, comment_idx));
            if (line != "")
                push(result, line);
        }
    }
    return result;
}

function load_local_ruleset(name, domains, prefixes) {
    name = as_string(name);
    if (name == "") return false;

    let loaded = false;
    let srs_file = RULESETS_DIR + "/community-" + name + ".srs";
    let json_file = RULESETS_DIR + "/community-" + name + ".json";
    let subnets_file = RULESETS_DIR + "/community-subnets-" + name + ".lst";

    if (file_exists(srs_file)) {
        common.ensure_dir(CACHE_LISTS_DIR);
        let c_dom = CACHE_LISTS_DIR + "/" + name + ".domains";
        let c_pfx = CACHE_LISTS_DIR + "/" + name + ".prefixes";
        let c_meta = CACHE_LISTS_DIR + "/" + name + ".meta";

        if (!file_exists(c_dom) || !file_exists(c_pfx)) {
            system(sprintf("steer srs-read %s --out %s --prefixes-out %s --meta-out %s >/dev/null 2>&1",
                srs_file, c_dom, c_pfx, c_meta));
        }

        let d_content = fs.readfile(c_dom);
        if (d_content != null) {
            for (let line in split(as_string(d_content), "\n")) {
                line = trim(line);
                if (line != "" && substr(line, 0, 1) != "#") {
                    domains[line] = true;
                    loaded = true;
                }
            }
        }

        let p_content = fs.readfile(c_pfx);
        if (p_content != null) {
            for (let line in split(as_string(p_content), "\n")) {
                line = trim(line);
                if (line != "" && substr(line, 0, 1) != "#" && looks_like_prefix(line)) {
                    prefixes[line] = true;
                    loaded = true;
                }
            }
        }
    }
    if (!loaded && file_exists(json_file)) {
        try {
            let j_data = json(as_string(fs.readfile(json_file)));
            if (type(j_data) == "object" && type(j_data.rules) == "array") {
                for (let rule in j_data.rules) {
                    if (type(rule) != "object") continue;
                    for (let d in (rule.domain_suffix || [])) {
                        d = trim(as_string(d));
                        if (d != "") domains[d] = true;
                    }
                    for (let d in (rule.domain || [])) {
                        d = trim(as_string(d));
                        if (d != "") domains[d] = true;
                    }
                    let pfx_list = rule.ip_cidr;
                    if (type(pfx_list) == "string") pfx_list = [ pfx_list ];
                    for (let p in (pfx_list || [])) {
                        p = trim(as_string(p));
                        if (looks_like_prefix(p)) prefixes[p] = true;
                    }
                }
                loaded = true;
            }
        } catch (e) {}
    }

    if (file_exists(subnets_file)) {
        let s_content = fs.readfile(subnets_file);
        if (s_content != null) {
            for (let line in split(as_string(s_content), "\n")) {
                line = trim(line);
                if (line != "" && substr(line, 0, 1) != "#" && looks_like_prefix(line))
                    prefixes[line] = true;
            }
            loaded = true;
        }
    }

    return loaded;
}

function materialize_section_lists(section, catalog) {
    catalog = type(catalog) == "object" ? catalog : {};
    // section_name is used for the channel list directory (stable, matches spec channels).
    let section_name = as_string(section[".name"] || section.label || "channel");
    // label_name mirrors generator.uc: label first, then .name — used for opts files so
    // the path matches what the spec generator embeds in spec.json.
    let label_name = as_string(section.label || section[".name"] || "channel");
    let name = section_name;
    let dir = section_dir(section_name);
    common.ensure_dir(dir);

    let domains = {};
    let prefixes = {};

    // User custom domains (option domain / list domain)
    for (let line in parse_raw_lines(section.domain)) {
        let clean = replace(line, /^(full:|domain:|domain_suffix:)/, "");
        if (looks_like_prefix(clean)) {
            prefixes[clean] = true;
        } else if (match(line, /^keyword:/) != null) {
            let kw = trim(replace(line, /^keyword:/, ""));
            if (kw != "") domains["*" + kw + "*"] = true;
        } else if (looks_like_domain(clean)) {
            domains[clean] = true;
        }
    }

    // User domain suffixes
    for (let line in parse_raw_lines(section.domain_suffix)) {
        let clean = replace(line, /^(full:|domain:|domain_suffix:)/, "");
        if (looks_like_domain(clean))
            domains[clean] = true;
    }

    // User domain keywords
    for (let line in parse_raw_lines(section.domain_keyword)) {
        let kw = trim(replace(line, /^keyword:/, ""));
        if (kw != "")
            domains["*" + kw + "*"] = true;
    }

    // User IP CIDRs (option ip_cidr / list ip_cidr)
    for (let line in parse_raw_lines(section.ip_cidr)) {
        if (looks_like_prefix(line))
            prefixes[line] = true;
    }

    // Inline user domains and subnets
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

    // Community ids: prefer local compiled rulesets (.srs / .json / .lst),
    // then explicit catalog file, otherwise fetch upstream plain-text.
    for (let value in list_option(section, "community_lists")) {
        if (load_local_ruleset(value, domains, prefixes))
            continue;

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

    let subnets_enabled = option(section, "community_subnets", null);
    if (subnets_enabled == "1" || subnets_enabled == 1 || subnets_enabled == true) {
        for (let value in list_option(section, "community_lists")) {
            let subnets_file = RULESETS_DIR + "/community-subnets-" + as_string(value) + ".lst";
            if (file_exists(subnets_file)) {
                let s_content = fs.readfile(subnets_file);
                if (s_content != null) {
                    for (let line in split(as_string(s_content), "\n")) {
                        line = trim(line);
                        if (line != "" && substr(line, 0, 1) != "#" && looks_like_prefix(line))
                            prefixes[line] = true;
                    }
                }
            }
        }
    }

    // Write zapret options if applicable.
    // Use label_name (= label || .name) so the filename matches what generator.uc
    // embeds in spec.json (generator also prefers label over .name).
    // The file carries the full effective command line (lua runtime, blobs,
    // filters, strategy) — steer-nfqws reads it fresh on every start.
    if (is_zapret_section(section)) {
        let lines = zapret_opts_lines(section);
        if (length(lines) > 0) {
            let zapret_dir = engine.STEER_ZAPRET_DIR;
            common.ensure_dir(zapret_dir);
            let opts_path = zapret_dir + "/" + label_name + ".opts";
            common.write_file(opts_path, join("\n", lines) + "\n");
        }
    }

    // Inject the diagnostics FakeIP test domain into proxy-section channel lists
    // so that steer dnsd returns a 198.18.x.x fake address during health checks.
    // This only applies to proxy sections (connection/subscription/provider) —
    // bypass/direct/zapret sections should not leak this domain into their lists.
    let section_action = as_string(option(section, "action", ""));
    if (section_action == "connection" || section_action == "subscription" || section_action == "provider") {
        domains["fakeip.podkop.fyi"] = true;
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
        write_subscription_file,
        STEER_SUBS_DIR,
        SECTION_LISTS_DIR,
        download_list,
        sync
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/lists.uc (library module, no CLI)\n");
exit(1);
