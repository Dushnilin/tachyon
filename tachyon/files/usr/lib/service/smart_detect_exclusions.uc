// Smart Detect exclusions are domain policies, not routing/DIRECT rules.
// Decode selected presets outside the watchdog; the hot path only reads an
// atomic, persistent domain snapshot and checks suffixes in memory.
let fs = require("fs");
let common = require("core.common");
let presets = require("tachyon_core.rulesets");
let smart_plus = require("service.smart_detect_plus");
let cache_dir = getenv("TACHYON_SMART_EXCLUSIONS_DIR") || "/etc/tachyon/smart-detect-exclusions";
let memo = null;
let memo_signature = null;

function values(raw) {
    return type(raw) == "array" ? raw : (raw ? split(trim(common.as_string(raw)), /[ \t\r\n,]+/) : []);
}

function supported(name) {
    // Discord is classified as subnets for DNS response matching, but its
    // preset also contains domain_suffix. Pure provider/GeoIP sets do not.
    return presets.is_community(name) &&
        (presets.community_kind(name) != "subnets" || name == "discord");
}

function selected_lists(cfg) {
    let seen = {};
    let result = [];
    for (let name in values(cfg?.smart_detect_exclude_lists)) {
        name = trim(common.as_string(name));
        if (name != "" && !seen[name]) { seen[name] = true; push(result, name); }
    }
    sort(result);
    return result;
}

function cache_path(name) {
    return supported(name) ? cache_dir + "/" + name + ".json" : null;
}

function normalize(value, suffix) {
    let domain = lc(trim(common.as_string(value)));
    domain = replace(domain, /^\*\./, "");
    domain = replace(domain, /^\./, "");
    domain = replace(domain, /\.$/, "");
    // Presets may exclude an entire TLD, e.g. Russia inside includes .ua.
    if (suffix && length(domain) <= 63 && match(domain, /^[a-z][a-z0-9-]*$/) != null && substr(domain, -1) != "-")
        return domain;
    return smart_plus.normalize_domain(domain);
}

function collect_domains(rules) {
    if (type(rules) != "array") return null;
    let domains = {};
    for (let rule in rules) {
        if (type(rule) != "object" || rule.invert || rule.rules ||
            rule.domain_regex || rule.domain_keyword) return null;
        let has_domains = rule.domain != null || rule.domain_suffix != null;
        // Destination domain and IP criteria are alternatives in SRS. Ignore
        // the IP part of mixed presets, but reject other compound conditions.
        if (has_domains) {
            for (let key in keys(rule))
                if (index(["domain", "domain_suffix", "ip_cidr", "invert", "type"], key) < 0) return null;
        }
        for (let key in ["domain", "domain_suffix"])
            for (let value in values(rule[key])) {
                let domain = normalize(value, true);
                if (domain == null) return null;
                domains[domain] = true;
            }
    }
    let result = keys(domains);
    sort(result);
    return length(result) ? result : null;
}

function prepare_list(name, source) {
    let path = cache_path(name);
    if (path == null || !presets.is_populated_srs_file(source)) return false;
    if (!common.command_success_from_args(["mkdir", "-p", cache_dir])) return false;
    let stamp = clock();
    let temporary = sprintf("%s.%d.%d.decode", path, stamp[0], stamp[1]);
    let bin = getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/tachyon-core";
    let ok = common.command_success_from_args([bin, "rule-set", "decompile", "--output", temporary, source]);
    let data = ok ? common.read_json_file(temporary) : null;
    try { fs.unlink(temporary); } catch (e) {}
    let domains = data ? collect_domains(data.rules) : null;
    // A failed download/decode never replaces the previous good exclusions.
    if (domains == null) return false;
    return common.write_json_file(path, { version: 1, service: name, domains });
}

function add_domain(indexes, domain) {
    indexes.suffixes[domain] = true;
    let labels = split(domain, ".");
    while (length(labels) > 2) {
        shift(labels);
        indexes.parents[join(".", labels)] = true;
    }
}

function state(cfg) {
    let names = selected_lists(cfg);
    let stamps = [];
    for (let name in names) {
        let path = cache_path(name);
        let st = path ? fs.stat(path) : null;
        push(stamps, st ? {name, size: st.size, mtime: st.mtime, inode: st.inode} : {name});
    }
    let signature = sprintf("%J", {manual: cfg?.smart_detect_exclude, stamps});
    if (signature == memo_signature) return memo;
    let result = {suffixes: {}, parents: {}, missing: [], ready: true};
    for (let value in values(cfg?.smart_detect_exclude)) {
        let domain = normalize(value, true);
        if (domain != null) add_domain(result, domain);
    }
    for (let name in names) {
        let path = cache_path(name);
        let data = path ? common.read_json_file(path) : null;
        if (data?.version != 1 || data?.service != name || type(data?.domains) != "array" || !length(data.domains)) {
            push(result.missing, name);
            continue;
        }
        let valid = true;
        for (let value in data.domains) {
            let domain = normalize(value, true);
            if (domain == null) { valid = false; break; }
            add_domain(result, domain);
        }
        if (!valid) push(result.missing, name);
    }
    result.ready = !length(result.missing);
    memo_signature = signature;
    memo = result;
    return result;
}

function excluded(domain, cfg) {
    domain = normalize(domain);
    if (domain == null) return true;
    let indexes = state(cfg);
    let labels = split(domain, ".");
    while (length(labels)) {
        if (indexes.suffixes[join(".", labels)]) return true;
        shift(labels);
    }
    return false;
}

function target(domain, cfg, root) {
    domain = normalize(domain);
    let indexes = state(cfg);
    if (!indexes.ready || excluded(domain, cfg)) return null;
    root = normalize(root);
    if (cfg?.smart_detect_expand_to_root == "0" || root == null) return domain;
    // Expanding a sibling to example.com would also proxy an excluded
    // cdn.example.com. Keep the detected hostname instead.
    if (excluded(root, cfg) || indexes.parents[root]) return domain;
    return root;
}

return { supported, selected_lists, cache_path, collect_domains, prepare_list, state, excluded, target };
