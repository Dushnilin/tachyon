// Optional extended detector. Default uses the unmodified 1.4.4 helper.
let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;

function mode(cfg) { return cfg?.smart_detect_mode == "plus" ? "plus" : "default"; }
function capture_enabled(cfg) { return cfg?.smart_detect == "1" && mode(cfg) == "plus"; }

function smart_detect_normalize_domain(value) {
    let domain = lc(trim(as_string(value)));
    if (length(domain) > 253 || match(domain, /^[a-z0-9.-]+\.[a-z][a-z0-9-]*$/) == null)
        return null;
    for (let label in split(domain, ".")) {
        if (length(label) == 0 || length(label) > 63 ||
            substr(label, 0, 1) == "-" || substr(label, -1) == "-") return null;
    }
    return domain;
}

function smart_detect_extract_domain(line) {
    if (line == null) return null;
    let text = as_string(line);
    // Explicit destination wins over unrelated quoted names in a TLS error.
    let plain = match(lc(text), /(open connection to|connect to|dial tcp) ([a-z0-9][a-z0-9.-]*):[0-9]+/);
    if (plain) return smart_detect_normalize_domain(plain[2]);
    let m = match(text, /"([a-zA-Z0-9][a-zA-Z0-9.-]*)(:[0-9]+)?"/);
    if (!m) m = match(text, /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]*)(:[0-9]+)?([ \t,;]|$)/);
    if (!m || !m[1]) return null;
    return smart_detect_normalize_domain(m[1]);
}

function smart_detect_log_candidate(line, correlated) {
    let text = lc(as_string(line));
    let outbound = match(text, /outbound\/[a-z0-9_-]+\[([a-z0-9_-]+)\]/);
    // Preserve explicitly selected VPN, bypass and DPI-provider routes.
    if (outbound ? outbound[1] != "direct-out" : index(text, "direct") < 0) return null;
    if (match(text, /dial udp|udp connection|packet connection|network[=: ]+udp|inbound\/[^ ]*udp/)) return null;
    let destination = match(text, /(open connection to|connect to|dial tcp) ([a-z0-9][a-z0-9.-]*):([0-9]+)/);
    let port = destination ? destination[3] : null;
    if (port == null) {
        let legacy = match(text, /(target[= ]|")([a-z0-9][a-z0-9.-]*):([0-9]+)/);
        if (legacy) port = legacy[3];
    }
    if (port == null && correlated) port = as_string(correlated.port);
    if (port != null && port != "80" && port != "443") return null;
    if (!match(text, /failed|timeout|timed out|reset|connection refused|network is unreachable|no route to host|unexpected eof|broken pipe|: eof([ \t]|$)|tls: (handshake failure|internal error|unexpected message)/)) return null;
    let domain = smart_detect_extract_domain(line);
    if (domain == null && correlated) domain = smart_detect_normalize_domain(correlated.domain);
    return domain == null ? null : { domain, scheme: port == "80" ? "http" : "https", priority: 3 };
}

let smart_detect_suffixes = null;
function smart_detect_main_domain(value) {
    let domain = smart_detect_normalize_domain(value);
    if (domain == null) return null;
    if (smart_detect_suffixes == null) {
        let data = fs.readfile(getenv("TACHYON_PSL_FILE") || "/usr/share/tachyon/public-suffix-list.dat");
        // Missing list: retain the narrower host instead of guessing its owner.
        if (!data) return domain;
        smart_detect_suffixes = {};
        for (let line in split(data, "\n")) {
            line = trim(line);
            if (line == "" || index(line, "//") == 0) continue;
            smart_detect_suffixes[line] = true;
        }
    }
    let labels = split(domain, ".");
    let count = length(labels);
    let suffix_size = 1;
    for (let i = 0; i < count; i++) {
        let suffix = join(".", slice(labels, i));
        if (smart_detect_suffixes["!" + suffix]) {
            suffix_size = count - i - 1;
            break;
        }
        if (smart_detect_suffixes[suffix] && count - i > suffix_size)
            suffix_size = count - i;
        if (i > 0 && smart_detect_suffixes["*." + suffix] && count - i + 1 > suffix_size)
            suffix_size = count - i + 1;
    }
    // A public/private suffix itself is never an automatic VPN wildcard.
    if (count <= suffix_size) return null;
    return join(".", slice(labels, count - suffix_size - 1));
}

// LuCI TextValue stores a multiline string; older releases used a UCI list.
// Split both (including multiline list items), keeping comments and prefixed
// conditions intact. Only exact equivalent entries are removed.
function smart_detect_domain_values(value) {
    let result = [];
    let seen = {};
    let raw = type(value) == "array" ? value : [value];
    for (let item in raw) {
        for (let line in split(as_string(item), /[\r\n]+/)) {
            line = trim(line);
            let parts = match(line, /^(full|keyword|regex):/i) || match(line, /^(#|\/\/)/)
                ? [line] : split(line, /[ \t,]+/);
            for (let part in parts) {
                part = trim(part);
                if (part == "") continue;
                let key = smart_detect_normalize_domain(part) || part;
                if (seen[key]) continue;
                seen[key] = true;
                push(result, part);
            }
        }
    }
    return result;
}

// Progress, rather than connection age: active downloads never become candidates.
// Keep only the current bounded set and let the healer confirm Direct vs proxy.
function smart_detect_stalled_candidates(previous, connections, now) {
    let tracked = {};
    let domains = {};
    let priorities = {};
    for (let conn in connections) {
        let meta = conn.metadata || {};
        let port = as_string(meta.destinationPort);
        if (meta.network != "tcp" || (port != "443" && port != "80") ||
            index(as_string(meta.type), "tproxy/") != 0 ||
            index(conn.chains || [], "direct-out") < 0 || !conn.id) continue;
        let domain = smart_detect_normalize_domain(meta.host);
        if (domain == null || length(tracked) >= 512) continue;
        let old = previous[conn.id];
        let download = int(conn.download || 0);
        if (download == 0 && int(conn.upload || 0) == 0) continue;
        let item = { domain, download, last_progress: now, emitted: false, last_emit: 0 };
        if (old && old.domain == domain && old.download == download) {
            item.last_progress = old.last_progress;
            item.emitted = old.emitted;
            item.last_emit = old.last_emit || 0;
        }
        // Revisit a persistent stall after the negative-probe cooldown: a
        // successful root page once must not suppress a later outage forever.
        if ((!item.emitted || now - item.last_emit >= 300) && now - item.last_progress >= (download == 0 ? 5 : 15)) {
            domains[domain] = (port == "80") ? "http" : "https";
            // A request with no reply outranks an idle established connection.
            priorities[domain] = max(priorities[domain] || 0, download == 0 ? 3 : 2);
            item.emitted = true;
            item.last_emit = now;
        }
        tracked[conn.id] = item;
    }
    return { tracked, domains, priorities };
}

// Merge observations without resetting FIFO age. A full queue keeps stronger
// evidence by replacing the newest candidate at the lowest priority.
function smart_detect_queue_candidate(pending, payload, now, limit) {
    let domain = smart_detect_normalize_domain(payload.domain);
    if (domain == null) return false;
    let priority = max(1, min(3, int(payload.priority || 1)));
    let old = pending[domain];
    if (old) {
        if (priority > int(old.priority || 1)) {
            old.priority = priority;
            old.scheme = payload.scheme == "http" ? "http" : "https";
        }
        return true;
    }
    if (length(pending) >= limit) {
        let victim = null;
        for (let key in keys(pending)) {
            let item = pending[key];
            if (victim == null || int(item.priority || 1) < int(pending[victim].priority || 1) ||
                (int(item.priority || 1) == int(pending[victim].priority || 1) && item.queued > pending[victim].queued))
                victim = key;
        }
        if (victim == null || int(pending[victim].priority || 1) >= priority) return false;
        delete pending[victim];
    }
    pending[domain] = { queued: now, priority, scheme: payload.scheme == "http" ? "http" : "https" };
    return true;
}

function smart_detect_queue_order(pending, domains) {
    return sort(domains, function(a, b) {
        let priority = int(pending[b].priority || 1) - int(pending[a].priority || 1);
        if (priority != 0) return priority;
        let age = pending[a].queued - pending[b].queued;
        return age != 0 ? age : (a < b ? -1 : (a > b ? 1 : 0));
    });
}


function probe_kind(status) {
    if (status == 0) return "ok";
    if (status == 5 || status == 6) return "dns";
    if (index([7, 16, 18, 28, 35, 52, 55, 56, 92], status) >= 0) return "transport";
    return "local";
}

// Inject the runner in tests; production still uses argv and verified Direct flags.
function probe(domain, item, proxy_addr, direct_flags, run) {
    let url = (item.scheme == "http" ? "http://" : "https://") + domain;
    let argv = ["curl", "-s", "-o", "/dev/null", "--connect-timeout", "3", "--max-time", "8"];
    for (let flag in direct_flags) push(argv, flag);
    push(argv, url);
    let direct = probe_kind(run(argv));
    if (direct == "ok") return { act: false, seen: true, defer: false };
    if (direct != "transport") return { act: false, seen: false, defer: true, dns_error: direct == "dns" };
    direct = probe_kind(run(argv));
    if (direct == "ok") return { act: false, seen: true, defer: false };
    if (direct != "transport") return { act: false, seen: false, defer: true, dns_error: direct == "dns" };
    let proxy = probe_kind(run([
        "curl", "-s", "-o", "/dev/null", "--connect-timeout", "5", "--max-time", "10",
        "--proxy", "http://" + proxy_addr, url
    ]));
    return { act: proxy == "ok", seen: proxy == "ok", defer: proxy != "ok" };
}

return {
    mode, capture_enabled, probe, probe_kind,
    normalize_domain: smart_detect_normalize_domain,
    extract_domain: smart_detect_extract_domain,
    log_candidate: smart_detect_log_candidate,
    main_domain: smart_detect_main_domain,
    domain_values: smart_detect_domain_values,
    stalled_candidates: smart_detect_stalled_candidates,
    queue_candidate: smart_detect_queue_candidate,
    queue_order: smart_detect_queue_order
};
