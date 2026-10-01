#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let url = require("core.url");
let ip = require("core.ip");
let dns = require("singbox.dns");
let as_string = common.as_string;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = (getenv("TACHYON_UI_STATE_DIR") || "/var/run/tachyon") + "/dns-speed-test";
const TIMEOUT_MS = 5000;
const MAX_SERVERS = 8;
const MAX_DOMAINS = 32;

function valid_domain(value) {
    if (type(value) != "string" || length(value) > 253 ||
        match(value, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/) == null)
        return false;
    for (let label in split(value, ".")) {
        if (length(label) > 63 || substr(label, 0, 1) == "-" || substr(label, length(label) - 1) == "-")
            return false;
    }
    return !ip.valid_ip(value);
}

function endpoint(value) {
    if (type(value) != "string" || length(value) > 2048 || value == "" ||
        match(value, /[[:space:][:cntrl:]]/) || index(value, "#") >= 0 || index(value, "@") >= 0 ||
        (index(value, "://") >= 0 && substr(value, 0, 8) != "https://"))
        return null;
    let host = url.host(value);
    let port = url.port(value);
    if (!ip.valid_ip(host) && !valid_domain(lc(host)))
        return null;
    if (port != "" && (match(port, /^[0-9]+$/) == null || int(port) < 1 || int(port) > 65535))
        return null;
    let server = dns.server_from_options("speed-test", "doh", value, "");
    let tls_host = server.tls.server_name || server.server;
    let authority = index(tls_host, ":") >= 0 ? "[" + tls_host + "]" : tls_host;
    let result = { value, address: "https://" + authority + ":" + server.server_port + server.path, resolve: null };
    if (tls_host != server.server && ip.valid_ip(server.server))
        result.resolve = tls_host + ":" + server.server_port + ":" + server.server;
    // Match Tachyon's DoH path/default and TLS server name; do not log profile URLs.
    return result;
}

function validate_request(request) {
    if (type(request) != "object" || request.protocol != "doh" ||
        type(request.servers) != "array" || type(request.domains) != "array" ||
        length(request.servers) < 1 || length(request.servers) > MAX_SERVERS ||
        length(request.domains) < 1 || length(request.domains) > MAX_DOMAINS)
        return null;
    let servers = [], domains = [], seen = {};
    for (let value in request.servers) {
        let normalized = endpoint(value);
        if (normalized == null) return null;
        if (!seen[value]) push(servers, normalized);
        seen[value] = true;
    }
    seen = {};
    for (let value in request.domains) {
        if (!valid_domain(value)) return null;
        if (!seen[value]) push(domains, value);
        seen[value] = true;
    }
    return { servers, domains };
}

function dns_query(domain) {
    let query = hexdec("000001000001000000000000");
    for (let label in split(domain, "."))
        query += sprintf("%c", length(label)) + label;
    return query + hexdec("0000010001");
}

function u16(data, offset) {
    return ord(data, offset) * 256 + ord(data, offset + 1);
}

function name_end(data, offset) {
    for (let count = 0; count < 128 && offset < length(data); count++) {
        let size = ord(data, offset++);
        if (size == 0) return offset;
        if ((size & 192) == 192) {
            if (offset >= length(data)) return -1;
            let target = (size & 63) * 256 + ord(data, offset);
            return target < offset - 1 ? offset + 1 : -1;
        }
        if (size > 63 || offset + size > length(data)) return -1;
        offset += size;
    }
    return -1;
}

function valid_answer(data, query) {
    if (type(data) != "string" || length(data) < length(query) ||
        substr(data, 0, 2) != substr(query, 0, 2) ||
        (ord(data, 2) & 250) != 128 || (ord(data, 3) & 15) != 0 ||
        u16(data, 4) != 1 || u16(data, 6) < 1 ||
        substr(data, 12, length(query) - 12) != substr(query, 12))
        return false;
    let records = u16(data, 6) + u16(data, 8) + u16(data, 10);
    if (records > 512) return false;
    let offset = length(query);
    for (let i = 0; i < records; i++) {
        offset = name_end(data, offset);
        if (offset < 0 || offset + 10 > length(data)) return false;
        offset += 10 + u16(data, offset + 8);
        if (offset > length(data)) return false;
    }
    return offset == length(data);
}

function summarize(samples) {
    let values = [], success = 0, total = length(samples);
    for (let sample in samples) {
        let ok = sample.ok === true && (type(sample.ms) == "int" || type(sample.ms) == "double") && sample.ms >= 0;
        push(values, ok ? sample.ms : TIMEOUT_MS);
        if (ok) success++;
    }
    sort(values, (a, b) => a - b);
    let sum = 0;
    for (let value in values) sum += value;
    let mid = int(total / 2);
    return {
        success, total, status: success == 0 ? "failed" : success == total ? "healthy" : "partial",
        min: success > 0 ? values[0] : null,
        median: success > 0 ? (total % 2 ? values[mid] : (values[mid - 1] + values[mid]) / 2.0) : null,
        avg: success > 0 ? sum / total : null,
        max: success > 0 ? values[total - 1] : null
    };
}

function measure(server, domains) {
    let args = [ "curl", "--disable" ];
    let count = length(domains);
    // One curl process keeps its connection cache for warm-up and measured requests.
    // Unlike the browser's concurrent fetches, transfers are serial to limit router load.
    for (let i = 0; i < count * 2; i++) {
        if (i > 0) push(args, "--next");
        let query = replace(replace(replace(b64enc(dns_query(domains[i % count])), /\+/g, "-"), /\//g, "_"), /=+$/, "");
        push(args, "--silent", "--globoff", "--noproxy", "*", "--proto", "=https",
            "--connect-timeout", "5", "--max-time", "5", "--max-filesize", "65535",
            "--header", "accept: application/dns-message", "--header", "cache-control: no-cache",
            "--output", STATE_DIR + "/answer-" + i,
            "--write-out", sprintf("%d|%%{http_code}|%%{time_total}|%%{content_type}|%%{size_download}|%%{exitcode}\n", i));
        if (server.resolve != null) push(args, "--resolve", server.resolve);
        push(args, "--url", server.address + "?dns=" + query);
    }
    let output = exec.run({ argv: args, timeout: count * 10 + 10 }).output;
    let reports = {};
    for (let line in split(as_string(output), "\n")) {
        let parts = split(line, "|");
        if (length(parts) == 6 && match(parts[0], /^[0-9]+$/)) reports[int(parts[0])] = parts;
    }
    let samples = [];
    for (let i = 0; i < count * 2; i++) {
        let path = STATE_DIR + "/answer-" + i;
        let body = fs.readfile(path);
        let report = reports[i];
        if (i >= count) {
            let ok = report != null && report[1] == "200" && report[5] == "0" &&
                lc(trim(split(report[3], ";")[0])) == "application/dns-message" &&
                int(report[4]) == length(body) && valid_answer(body, dns_query(domains[i - count]));
            let error = null;
            if (!ok) {
                error = report == null ? { kind: "probe", code: null } :
                    report[5] != "0" ? { kind: "transport", code: int(report[5]) } :
                    report[1] != "200" ? { kind: "http", code: int(report[1]) } :
                    { kind: "dns", code: length(body) >= 12 ? ord(body, 3) & 15 : null };
            }
            push(samples, { domain: domains[i - count], ok, ms: ok ? double(report[2]) * 1000 : null, error });
        }
        fs.unlink(path);
    }
    return { server: server.value, samples, stats: summarize(samples) };
}

function read_state() {
    return common.read_json_file(STATE_DIR + "/state.json") || { running: false, results: [] };
}

function write_state(state) {
    if (!common.write_json_file(STATE_DIR + "/state.json", state)) die("Cannot save DNS speed test state");
}

function status() {
    let state = read_state();
    let identity = common.read_json_file(STATE_DIR + "/identity.json");
    if (state.running && time() - state.started_at > 5 &&
        (identity == null || !exec.identity_matches(identity, identity.pid) || !exec.is_alive(identity.pid))) {
        state.running = false;
        state.error = "DNS speed test worker stopped";
        write_state(state);
    }
    return state;
}

function start(request) {
    let normalized = validate_request(request);
    if (normalized == null) return { success: false, error: "Invalid DNS speed test request" };
    common.command_success_from_args([ "mkdir", "-p", STATE_DIR ]);
    fs.chmod(STATE_DIR, 0700);
    let previous = status();
    if (previous.running) return { success: false, error: "DNS speed test is already running" };
    // Atomic mkdir also protects concurrent starts while the worker PID is being recorded.
    if (!fs.mkdir(STATE_DIR + "/lock", 0700)) {
        let lock = fs.stat(STATE_DIR + "/lock");
        if (lock == null || time() - lock.mtime < 5)
            return { success: false, error: "DNS speed test is already starting" };
        fs.rmdir(STATE_DIR + "/lock");
        if (!fs.mkdir(STATE_DIR + "/lock", 0700))
            return { success: false, error: "Cannot lock DNS speed test" };
    }
    let stamp = clock();
    let state = { id: sprintf("%d-%d", stamp[0], stamp[1]), running: true, progress: 0,
        started_at: time(), domains: normalized.domains, servers: request.servers, results: [], error: null };
    try {
        if (!common.write_json_file(STATE_DIR + "/request.json", normalized)) die("Cannot save DNS speed test request");
        fs.unlink(STATE_DIR + "/identity.json");
        write_state(state);
        let worker = exec.run_background({
            argv: [ "ucode", "-L", LIB_DIR, LIB_DIR + "/dns/speed_test.uc", "worker", state.id ],
            env: { TACHYON_LIB: LIB_DIR, TACHYON_UI_STATE_DIR: getenv("TACHYON_UI_STATE_DIR") || "/var/run/tachyon" }
        });
        if (worker.identity == null || int(worker.pid) < 1) die("Cannot start DNS speed test worker");
        common.write_json_file(STATE_DIR + "/identity.json", worker.identity);
        return { success: true, id: state.id };
    } catch (e) {
        state.running = false;
        state.error = as_string(e);
        write_state(state);
        fs.rmdir(STATE_DIR + "/lock");
        return { success: false, error: state.error };
    }
}

function worker(id) {
    let state = read_state();
    if (!state.running || state.id != id) return 1;
    try {
        let request = common.read_json_file(STATE_DIR + "/request.json");
        for (let server in request.servers) {
            push(state.results, measure(server, request.domains));
            state.progress = int(length(state.results) * 100 / length(request.servers));
            write_state(state);
        }
    } catch (e) {
        state.error = "DNS speed test failed";
    }
    state.running = false;
    state.finished_at = time();
    write_state(state);
    fs.unlink(STATE_DIR + "/request.json");
    fs.rmdir(STATE_DIR + "/lock");
    return state.error ? 1 : 0;
}

let mode = ARGV[0] || "";
if (mode == "start") {
    let request;
    try { request = json(ARGV[1] || "{}"); } catch (e) { request = null; }
    let result = start(request);
    common.write_json(result);
    exit(result.success ? 0 : 1);
} else if (mode == "status") {
    common.write_json(status());
    exit(0);
} else if (mode == "worker") {
    exit(worker(ARGV[1]));
}

return { valid_domain, endpoint, validate_request, dns_query, valid_answer, summarize, measure, start, status };
