#!/usr/bin/env ucode
//
// Tachyon Server & Outbound Health & Latency Statistics Module:
//   1. Aggregates and tracks metrics (latency, success/failure rate, jitter,
//      last checked time, last error) for all proxy servers across sections
//      and subscriptions.
//   2. Works seamlessly across both sing-box and steer engines.
//   3. Provides best-candidate ranking for auto-tuning and routing failover.
//   4. Persists collected statistics to bounded JSON runtime storage.
//

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

let as_string = common.as_string;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;

function safe_json_parse(text) {
    if (text == null || text == "") return null;
    try {
        return json(text);
    } catch (e) {
        return null;
    }
}

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const STATS_STORAGE_PATH = getenv("TACHYON_SERVER_STATS_PATH") || "/var/run/tachyon/server_stats.json";
const TACHYON_BIN = getenv("TACHYON_BIN") || "/usr/bin/tachyon";

// --- Monotonic & Wall Time Helpers ---

function get_now_ts() {
    let t = time();
    return int(t) || 0;
}

function get_now_iso() {
    let t = time();
    // Return approximate ISO timestamp
    return sprintf("%d", t);
}

// --- Storage Management ---

function ensure_stats_dir() {
    if (!fs.stat("/var/run/tachyon"))
        fs.mkdir("/var/run/tachyon", 0755);
}

function load_stats_db() {
    let data = read_json_file(STATS_STORAGE_PATH);
    if (type(data) != "object") {
        data = {
            version: 1,
            last_updated: 0,
            servers: {}
        };
    }
    if (type(data.servers) != "object")
        data.servers = {};
    return data;
}

function save_stats_db(data) {
    if (type(data) != "object") return false;
    ensure_stats_dir();
    data.last_updated = get_now_ts();
    return write_json_file(STATS_STORAGE_PATH, data);
}

// --- Active Engine and Proxies Inspection ---

function fetch_runtime_proxies() {
    let out = trim(command_output_from_args([ TACHYON_BIN, "clash_api", "get_proxies" ]));
    let parsed = safe_json_parse(out);
    if (type(parsed) == "object" && type(parsed.proxies) == "object")
        return parsed.proxies;
    return {};
}

function is_real_proxy_type(raw_type) {
    let t = lc(as_string(raw_type || ""));
    // Exclude virtual/meta types
    if (t == "urltest" || t == "selector" || t == "direct" || t == "block" ||
        t == "reject" || t == "compatible" || t == "dns" || t == "mixed")
        return false;
    return true;
}

// Map each proxy tag to its owning section and subscription
function build_proxy_topology_map() {
    let topology = {};
    let sections = uci_core.section_objects(CONFIG_NAME, "section");
    for (let sec in sections) {
        let sname = as_string(sec[".name"]);
        if (sname == "") continue;
        let prefix = "";
        let subs = uci_core.section_objects(CONFIG_NAME, "subscription_url");
        for (let sub in subs) {
            if (as_string(sub.section) == sname) {
                prefix = as_string(sub.node_prefix || "");
                break;
            }
        }
        topology[sname] = {
            section: sname,
            node_prefix: prefix
        };
    }
    return topology;
}

function guess_section_for_tag(tag, topology) {
    let s_tag = as_string(tag);
    for (let sname, meta in topology) {
        if (meta.node_prefix != "" && index(s_tag, meta.node_prefix + " ") == 0)
            return sname;
    }
    for (let sname, meta in topology) {
        if (index(s_tag, sname + "-") == 0 || index(s_tag, sname + " ") == 0)
            return sname;
    }
    return "Main";
}

// --- Stats Record & Update ---

function update_server_entry(entry, latency_ms, ok, error_msg) {
    let now = get_now_ts();
    latency_ms = int(latency_ms) || 0;
    ok = (ok == true && latency_ms > 0);

    entry.total_probes = (int(entry.total_probes) || 0) + 1;
    entry.last_checked = now;

    if (ok) {
        entry.successful_probes = (int(entry.successful_probes) || 0) + 1;
        entry.consecutive_failures = 0;
        entry.last_status = "ok";
        entry.last_error = "";
        entry.last_latency = latency_ms;

        // Min & Max
        if (entry.min_latency == null || latency_ms < entry.min_latency)
            entry.min_latency = latency_ms;
        if (entry.max_latency == null || latency_ms > entry.max_latency)
            entry.max_latency = latency_ms;

        // Exponential moving average (weight 0.3 for new sample)
        if (entry.avg_latency == null || entry.avg_latency == 0) {
            entry.avg_latency = latency_ms;
            entry.jitter = 0;
        } else {
            let diff = (latency_ms > entry.avg_latency) ? (latency_ms - entry.avg_latency) : (entry.avg_latency - latency_ms);
            entry.jitter = int(0.7 * (int(entry.jitter) || 0) + 0.3 * diff);
            entry.avg_latency = int(0.7 * entry.avg_latency + 0.3 * latency_ms);
        }
    } else {
        entry.failed_probes = (int(entry.failed_probes) || 0) + 1;
        entry.consecutive_failures = (int(entry.consecutive_failures) || 0) + 1;
        entry.last_status = "error";
        entry.last_error = as_string(error_msg || "timeout or connection refused");
        entry.last_latency = 0;
    }

    if (entry.total_probes > 0)
        entry.success_rate = int(((int(entry.successful_probes) || 0) * 100) / entry.total_probes);
    else
        entry.success_rate = 0;

    return entry;
}

// --- Sync Runtime Cache ---

function sync_runtime_proxies_to_db(db) {
    let proxies = fetch_runtime_proxies();
    let topology = build_proxy_topology_map();
    let count = 0;

    for (let tag, pdata in proxies) {
        if (!is_real_proxy_type(pdata.type))
            continue;

        let sec = guess_section_for_tag(tag, topology);
        if (db.servers[tag] == null) {
            db.servers[tag] = {
                tag: tag,
                name: as_string(pdata.name || tag),
                type: as_string(pdata.type || "unknown"),
                section: sec,
                last_status: "untested",
                last_latency: 0,
                last_checked: 0,
                last_error: "",
                total_probes: 0,
                successful_probes: 0,
                failed_probes: 0,
                consecutive_failures: 0,
                avg_latency: 0,
                min_latency: null,
                max_latency: null,
                jitter: 0,
                success_rate: 0
            };
            count++;
        } else {
            // Update static metadata
            db.servers[tag].type = as_string(pdata.type || db.servers[tag].type);
            db.servers[tag].section = sec;
        }

        // Incorporate existing history if we are untested but clash_api already had samples
        if (db.servers[tag].total_probes == 0 && type(pdata.history) == "array" && length(pdata.history) > 0) {
            let last_hist = pdata.history[length(pdata.history) - 1];
            if (last_hist && last_hist.delay > 0) {
                update_server_entry(db.servers[tag], last_hist.delay, true, "");
            }
        }
    }
    return count;
}

// --- Probing Functions ---

function probe_single_server(tag, timeout_ms) {
    timeout_ms = int(timeout_ms) || 3000;
    let out = trim(command_output_from_args([ TACHYON_BIN, "clash_api", "get_proxy_latency", tag, as_string(timeout_ms) ]));
    let parsed = safe_json_parse(out);
    let delay = 0;
    let ok = false;
    let err = "";

    if (type(parsed) == "object") {
        if (parsed.delay != null && int(parsed.delay) > 0) {
            delay = int(parsed.delay);
            ok = true;
        } else if (parsed.message) {
            err = as_string(parsed.message);
        } else {
            err = "no latency returned";
        }
    } else {
        err = "invalid json from probe";
    }

    return { tag, delay, ok, error: err };
}

function record_probe_result(tag, latency, ok, error_msg, section) {
    let db = load_stats_db();
    sync_runtime_proxies_to_db(db);

    if (db.servers[tag] == null) {
        db.servers[tag] = {
            tag: tag,
            name: tag,
            type: "unknown",
            section: section || "Main",
            last_status: "untested",
            last_latency: 0,
            last_checked: 0,
            last_error: "",
            total_probes: 0,
            successful_probes: 0,
            failed_probes: 0,
            consecutive_failures: 0,
            avg_latency: 0,
            min_latency: null,
            max_latency: null,
            jitter: 0,
            success_rate: 0
        };
    }

    update_server_entry(db.servers[tag], latency, ok, error_msg);
    save_stats_db(db);
    return db.servers[tag];
}

function probe_and_record(tag, timeout_ms) {
    let res = probe_single_server(tag, timeout_ms);
    let rec = record_probe_result(tag, res.delay, res.ok, res.error, null);
    return {
        tag: rec.tag,
        status: rec.last_status,
        latency_ms: rec.last_latency,
        avg_latency_ms: rec.avg_latency,
        success_rate: rec.success_rate,
        error: rec.last_error
    };
}

function probe_all_servers(target_section, timeout_ms) {
    let db = load_stats_db();
    sync_runtime_proxies_to_db(db);

    timeout_ms = int(timeout_ms) || 3000;
    target_section = as_string(target_section || "");

    let tested = 0;
    let successful = 0;
    let results = [];

    for (let tag, entry in db.servers) {
        if (target_section != "" && target_section != "all" && entry.section != target_section)
            continue;

        let res = probe_single_server(tag, timeout_ms);
        update_server_entry(entry, res.delay, res.ok, res.error);
        tested++;
        if (res.ok) successful++;

        push(results, {
            tag: tag,
            section: entry.section,
            type: entry.type,
            ok: res.ok,
            latency_ms: res.delay,
            error: res.error
        });
    }

    save_stats_db(db);

    return {
        total_probed: tested,
        successful: successful,
        failed: tested - successful,
        results: results
    };
}

// --- Query, Summary and Best Candidate Ranking ---

function get_summary() {
    let db = load_stats_db();
    sync_runtime_proxies_to_db(db);

    let total = 0;
    let healthy = 0;
    let unhealthy = 0;
    let untested = 0;
    let lat_sum = 0;
    let lat_count = 0;

    let best_node = null;
    let worst_node = null;

    let section_counts = {};
    let protocol_counts = {};
    let server_list = [];

    for (let tag, entry in db.servers) {
        total++;
        let st = entry.last_status;
        if (st == "ok") {
            healthy++;
            if (entry.last_latency > 0) {
                lat_sum += entry.last_latency;
                lat_count++;
                if (best_node == null || entry.last_latency < best_node.latency_ms) {
                    best_node = {
                        tag: tag,
                        latency_ms: entry.last_latency,
                        section: entry.section,
                        type: entry.type
                    };
                }
                if (worst_node == null || entry.last_latency > worst_node.latency_ms) {
                    worst_node = {
                        tag: tag,
                        latency_ms: entry.last_latency,
                        section: entry.section,
                        type: entry.type
                    };
                }
            }
        } else if (st == "error") {
            unhealthy++;
        } else {
            untested++;
        }

        let sec = entry.section || "Main";
        section_counts[sec] = (section_counts[sec] || 0) + 1;

        let pr = entry.type || "Other";
        protocol_counts[pr] = (protocol_counts[pr] || 0) + 1;

        push(server_list, entry);
    }

    return {
        total_servers: total,
        healthy_count: healthy,
        unhealthy_count: unhealthy,
        untested_count: untested,
        avg_latency_ms: lat_count > 0 ? int(lat_sum / lat_count) : 0,
        best_server: best_node,
        worst_server: worst_node,
        sections: section_counts,
        protocols: protocol_counts,
        last_updated: db.last_updated,
        servers: server_list
    };
}

function get_best_candidates(target_section, limit) {
    let db = load_stats_db();
    sync_runtime_proxies_to_db(db);

    limit = int(limit) || 5;
    if (limit < 1) limit = 1;
    target_section = as_string(target_section || "");

    let pool = [];
    for (let tag, entry in db.servers) {
        if (target_section != "" && target_section != "all" && entry.section != target_section)
            continue;
        if (entry.last_status == "ok" && entry.last_latency > 0) {
            push(pool, entry);
        }
    }

    // Sort by composite score: lowest latency with penalty for consecutive failures and low success rate
    sort(pool, function(a, b) {
        let score_a = (a.avg_latency || a.last_latency || 9999) + (a.consecutive_failures * 100) - (a.success_rate * 2);
        let score_b = (b.avg_latency || b.last_latency || 9999) + (b.consecutive_failures * 100) - (b.success_rate * 2);
        return score_a - score_b;
    });

    let result = [];
    for (let i = 0; i < length(pool) && i < limit; i++) {
        push(result, pool[i]);
    }
    return result;
}

function query_servers(filter_json) {
    let db = load_stats_db();
    sync_runtime_proxies_to_db(db);

    let filter = safe_json_parse(filter_json);
    if (type(filter) != "object") filter = {};

    let target_section = as_string(filter.section || "");
    let target_status = as_string(filter.status || "");
    let target_type = as_string(filter.type || "");
    let max_latency = int(filter.max_latency || 0);

    let matched = [];
    for (let tag, entry in db.servers) {
        if (target_section != "" && entry.section != target_section)
            continue;
        if (target_status != "" && entry.last_status != target_status)
            continue;
        if (target_type != "" && lc(entry.type) != lc(target_type))
            continue;
        if (max_latency > 0 && (entry.last_latency <= 0 || entry.last_latency > max_latency))
            continue;

        push(matched, entry);
    }
    return matched;
}

function reset_stats() {
    let db = {
        version: 1,
        last_updated: get_now_ts(),
        servers: {}
    };
    save_stats_db(db);
    sync_runtime_proxies_to_db(db);
    save_stats_db(db);
    return { ok: true, message: "Server statistics reset successfully" };
}

function module_exports() {
    return {
        get_summary,
        probe_and_record,
        probe_all_servers,
        get_best_candidates,
        query_servers,
        record_probe_result,
        reset_stats
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// --- CLI Dispatcher ---

let mode = ARGV[0];
if (mode == "summary" || mode == "status" || mode == "" || mode == null) {
    print(sprintf("%J\n", get_summary()));
    exit(0);
} else if (mode == "probe") {
    let tag = ARGV[1];
    let timeout = ARGV[2];
    if (!tag || tag == "") {
        warn("Usage: server_stats.uc probe <server_tag> [timeout_ms]\n");
        exit(1);
    }
    print(sprintf("%J\n", probe_and_record(tag, timeout)));
    exit(0);
} else if (mode == "probe_all" || mode == "probe-all") {
    let sec = ARGV[1];
    let timeout = ARGV[2];
    print(sprintf("%J\n", probe_all_servers(sec, timeout)));
    exit(0);
} else if (mode == "best" || mode == "best_candidates") {
    let sec = ARGV[1];
    let limit = ARGV[2];
    print(sprintf("%J\n", get_best_candidates(sec, limit)));
    exit(0);
} else if (mode == "query") {
    print(sprintf("%J\n", query_servers(ARGV[1])));
    exit(0);
} else if (mode == "record") {
    let tag = ARGV[1];
    let lat = int(ARGV[2]);
    let ok = (ARGV[3] == "1" || ARGV[3] == "true");
    let err = ARGV[4];
    let sec = ARGV[5];
    print(sprintf("%J\n", record_probe_result(tag, lat, ok, err, sec)));
    exit(0);
} else if (mode == "reset") {
    print(sprintf("%J\n", reset_stats()));
    exit(0);
} else {
    warn("Usage: server_stats.uc <summary|probe|probe_all|best|query|record|reset> ...\n");
    exit(1);
}


