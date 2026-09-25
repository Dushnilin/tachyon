#!/usr/bin/env ucode
//
// Event bus & Bounded Event Journal:
//   1. Event bus: publish/subscribe with per-subscriber cooldown, publish-side
//      deduplication, deterministic priority ordering and handler error isolation.
//   2. Bounded ring journal: append-only JSONL (/var/run/tachyon/events.jsonl)
//      with strict size/line bounds to avoid RAM/disk exhaustion on routers.
//   3. Secret redaction: automatic stripping/masking of sensitive credentials
//      (tokens, passwords, API keys, Telegram bot tokens, proxy URIs).
//   4. Structured event schema: ts, ms, event, severity, source, job_id,
//      correlation_id, message, data.
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let write_json_file = common.write_json_file;

// ---------------------------------------------------------------------------
// Timing & Environment
// ---------------------------------------------------------------------------

// Monotonic milliseconds. Independent of wall-clock jumps.
function now_ms() {
    let c = clock(true);
    if (type(c) != "array" || length(c) < 2)
        return 0;
    return c[0] * 1000 + int(c[1] / 1000000);
}

function get_journal_dir() {
    let d = getenv("TACHYON_EVENT_JOURNAL_DIR") || getenv("TACHYON_RUNTIME_STATE_DIR");
    if (d != null && d != "")
        return d;
    if (fs.access("/var/run", "w"))
        return "/var/run/tachyon";
    return "/tmp/tachyon";
}

function get_journal_path() {
    let p = getenv("TACHYON_EVENT_JOURNAL_PATH");
    if (p != null && p != "")
        return p;
    return get_journal_dir() + "/events.jsonl";
}

const DEFAULT_JOURNAL_MAX_ENTRIES = int(getenv("TACHYON_JOURNAL_MAX_ENTRIES") || "500");
const DEFAULT_JOURNAL_MAX_BYTES   = int(getenv("TACHYON_JOURNAL_MAX_BYTES") || "262144"); // 256 KB

// ---------------------------------------------------------------------------
// Secret Redaction Engine
// ---------------------------------------------------------------------------

const SENSITIVE_KEY_REGEX = /^(token|secret|password|passwd|key|auth|credential|credentials|api_key|bot_token|private_key|private|cert|cookie|access_token|refresh_token)$/i;
const SENSITIVE_KEY_SUBSTR_REGEX = /(token|secret|password|passwd|bot_token|api_key|private_key)/i;

function is_sensitive_key(key) {
    if (key == null || key == "")
        return false;
    let k = as_string(key);
    return match(k, SENSITIVE_KEY_REGEX) != null || match(k, SENSITIVE_KEY_SUBSTR_REGEX) != null;
}

function redact_string(str) {
    if (str == null || str == "")
        return "";
    let s = as_string(str);

    // 1. Telegram bot tokens: e.g. 123456789:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567
    s = replace(s, /[0-9]{8,12}:[-_a-zA-Z0-9]{35}/g, "[REDACTED_TELEGRAM_TOKEN]");

    // 2. Bearer tokens: e.g. Bearer eyJhbGci...
    s = replace(s, /Bearer[ \t]+[-_a-zA-Z0-9.+=]{16,}/gi, "Bearer [REDACTED_TOKEN]");

    // 3. Proxy & HTTP URLs with credentials:
    //    e.g. https://user:pass@host:port -> https://[REDACTED]@host:port
    s = replace(s, /:\/\/([^:@ \t\r\n]+)(:[^@ \t\r\n]+)?@/g, "://[REDACTED]@");

    // 4. VLESS / Trojan UUIDs in links: e.g. vless://12345678-1234-1234-1234-1234567890ab@
    s = replace(s, /vless:\/\/([-a-fA-F0-9]{36})@/g, "vless://[REDACTED_UUID]@");
    s = replace(s, /trojan:\/\/([^@ \t\r\n]+)@/g, "trojan://[REDACTED_PASS]@");

    // 5. Standalone UUID / Hex secret patterns in query parameters: e.g. ?secret=... or &key=...
    s = replace(s, /([?&](password|secret|key|token|auth)=)[^& \t\r\n]+/gi, "$1[REDACTED]");

    return s;
}

function redact_value(val) {
    let t = type(val);
    if (t == "string") {
        return redact_string(val);
    }
    if (t == "array") {
        let out = [];
        for (let item in val)
            push(out, redact_value(item));
        return out;
    }
    if (t == "object") {
        let out = {};
        for (let k, v in val) {
            if (is_sensitive_key(k)) {
                out[k] = "[REDACTED]";
            } else {
                out[k] = redact_value(v);
            }
        }
        return out;
    }
    return val;
}

function redact(data) {
    return redact_value(data);
}

// ---------------------------------------------------------------------------
// Bounded Ring Event Journal
// ---------------------------------------------------------------------------

function ensure_dir(path) {
    if (path == "" || fs.stat(path) != null)
        return true;
    return system("mkdir -p " + shell_quote(path) + " 2>/dev/null") == 0;
}

function journal(opts) {
    opts = type(opts) == "object" ? opts : {};
    let file_path = as_string(opts.path || get_journal_path());
    let max_entries = (opts.max_entries != null) ? int(opts.max_entries) : DEFAULT_JOURNAL_MAX_ENTRIES;
    let max_bytes   = (opts.max_bytes != null)   ? int(opts.max_bytes)   : DEFAULT_JOURNAL_MAX_BYTES;
    let self = {};

    function get_dir() {
        let slash = rindex(file_path, "/");
        return slash >= 0 ? substr(file_path, 0, slash) : "/tmp";
    }

    self.path = () => file_path;

    // Compacts the journal file keeping the newest records within line and byte limits
    self.compact = function() {
        let content = fs.readfile(file_path);
        if (content == null || content == "")
            return 0;

        let raw_lines = split(trim(content), "\n");
        let lines = [];
        for (let line in raw_lines) {
            line = trim(line);
            if (line != "") push(lines, line);
        }

        let total_lines = length(lines);
        let target_keep = int(max_entries * 0.75);
        if (target_keep < 1) target_keep = 1;

        let start_idx = 0;
        if (total_lines > target_keep) {
            start_idx = total_lines - target_keep;
        }

        let kept = [];
        for (let i = start_idx; i < total_lines; i++) {
            push(kept, lines[i]);
        }

        // Also ensure byte size fits max_bytes
        let compact_text = join("\n", kept) + "\n";
        while (length(compact_text) > max_bytes && length(kept) > 1) {
            shift(kept);
            compact_text = join("\n", kept) + "\n";
        }

        let tmp_file = sprintf("%s.tmp.%d", file_path, now_ms());
        let res = fs.writefile(tmp_file, compact_text);
        if (res != null && res !== false) {
            fs.rename(tmp_file, file_path);
        } else {
            try { fs.unlink(tmp_file); } catch (e) {}
        }

        return length(kept);
    };

    // Appends a structured event
    self.record = function(event_name, payload, meta) {
        event_name = as_string(event_name);
        if (event_name == "")
            return null;

        meta = type(meta) == "object" ? meta : {};
        let severity = as_string(meta.severity || "info");
        let source   = as_string(meta.source || "tachyon");
        let message  = as_string(meta.message || "");
        let job_id   = (meta.job_id != null && meta.job_id != "") ? as_string(meta.job_id) : null;
        let corr_id  = (meta.correlation_id != null && meta.correlation_id != "") ? as_string(meta.correlation_id) : null;

        // Sanitize and redact payload data and message
        let safe_data = redact(payload);
        let safe_msg  = redact_string(message);

        let entry = {
            ts: time(),
            ms: now_ms(),
            event: event_name,
            severity: severity,
            source: source,
            job_id: job_id,
            correlation_id: corr_id,
            message: safe_msg,
            data: (safe_data != null) ? safe_data : {}
        };

        let line = sprintf("%J\n", entry);

        ensure_dir(get_dir());

        let fh = fs.open(file_path, "a");
        if (fh) {
            fh.write(line);
            fh.close();
        } else {
            // Fallback: write to file if open failed
            let existing = fs.readfile(file_path) || "";
            fs.writefile(file_path, existing + line);
        }

        // Check if compaction is needed
        let st = fs.stat(file_path);
        if (st && st.size > max_bytes) {
            self.compact();
        }

        return entry;
    };

    // Query entries matching filter criteria
    self.query = function(filter_opts) {
        filter_opts = type(filter_opts) == "object" ? filter_opts : {};
        let content = fs.readfile(file_path);
        if (content == null || content == "")
            return [];

        let lines = split(trim(content), "\n");
        let results = [];
        let limit = (filter_opts.limit != null) ? int(filter_opts.limit) : 50;
        let reverse_order = (filter_opts.reverse != null) ? (filter_opts.reverse == true) : true;

        let filter_event    = filter_opts.event != null ? as_string(filter_opts.event) : null;
        let filter_severity = filter_opts.severity != null ? as_string(filter_opts.severity) : null;
        let filter_source   = filter_opts.source != null ? as_string(filter_opts.source) : null;
        let filter_job_id   = filter_opts.job_id != null ? as_string(filter_opts.job_id) : null;
        let filter_corr_id  = filter_opts.correlation_id != null ? as_string(filter_opts.correlation_id) : null;
        let filter_since    = filter_opts.since != null ? int(filter_opts.since) : null;
        let filter_search   = filter_opts.search != null ? lc(as_string(filter_opts.search)) : null;

        // Iterate either from newest to oldest or chronological
        let start = reverse_order ? (length(lines) - 1) : 0;
        let step  = reverse_order ? -1 : 1;
        let count = 0;

        for (let i = start; reverse_order ? (i >= 0) : (i < length(lines)); i += step) {
            let line = trim(lines[i]);
            if (line == "") continue;

            let entry = null;
            try { entry = json(line); } catch (e) { continue; }
            if (type(entry) != "object") continue;

            if (filter_event != null && entry.event != filter_event)
                continue;
            if (filter_severity != null && entry.severity != filter_severity)
                continue;
            if (filter_source != null && entry.source != filter_source)
                continue;
            if (filter_job_id != null && entry.job_id != filter_job_id)
                continue;
            if (filter_corr_id != null && entry.correlation_id != filter_corr_id)
                continue;
            if (filter_since != null && entry.ts < filter_since)
                continue;
            if (filter_search != null) {
                let msg_lower = lc(as_string(entry.message));
                let ev_lower  = lc(as_string(entry.event));
                if (index(msg_lower, filter_search) < 0 && index(ev_lower, filter_search) < 0)
                    continue;
            }

            push(results, entry);
            count++;
            if (limit > 0 && count >= limit)
                break;
        }

        return results;
    };

    // Return the last n records
    self.tail = function(n) {
        let count = (n != null) ? int(n) : 10;
        return self.query({ limit: count, reverse: true });
    };

    // Clears the journal file
    self.clear = function() {
        let res = fs.writefile(file_path, "");
        return (res != null && res !== false);
    };

    // Returns journal statistics
    self.stats = function() {
        let st = fs.stat(file_path);
        let size = (st && st.size) ? st.size : 0;
        let count = 0;
        let content = fs.readfile(file_path);
        if (content != null && content != "") {
            for (let line in split(trim(content), "\n")) {
                if (trim(line) != "") count++;
            }
        }
        return {
            path: file_path,
            count: count,
            size_bytes: size,
            max_entries: max_entries,
            max_bytes: max_bytes
        };
    };

    return self;
}

// ---------------------------------------------------------------------------
// Event Bus with Journal Integration
// ---------------------------------------------------------------------------

function bus(opts) {
    opts = type(opts) == "object" ? opts : {};
    let handlers = {};        // type -> array of subscriber records
    let last_emit = {};       // dedup key -> monotonic ms of last accepted emit
    let counters = {
        emitted: 0,           // events accepted onto the bus
        suppressed: 0,        // emit_once calls dropped as duplicates
        delivered: 0,         // handler invocations that ran to completion
        skipped: 0,           // handler invocations skipped by cooldown
        failed: 0             // handler invocations that threw
    };
    let error_sink = null;    // optional function(name, type, err)
    let attached_journal = null;

    if (opts.journal != null) {
        attached_journal = opts.journal;
    }

    let self = {};

    self.attach_journal = function(j) {
        attached_journal = j;
    };

    self.get_journal = function() {
        return attached_journal;
    };

    self.on = function(event_type, handler, handler_opts) {
        event_type = as_string(event_type);
        if (event_type == "" || type(handler) != "function")
            return false;

        let options = (type(handler_opts) == "object") ? handler_opts : {};
        let record = {
            handler: handler,
            name: as_string(options.name || event_type),
            cooldown: options.cooldown != null ? int(options.cooldown) : 0,
            priority: options.priority != null ? int(options.priority) : 50,
            last_run: -1,
            runs: 0
        };

        if (type(handlers[event_type]) != "array")
            handlers[event_type] = [];
        push(handlers[event_type], record);

        sort(handlers[event_type], function(a, b) { return a.priority - b.priority; });
        return true;
    };

    function report_error(name, event_type, err) {
        counters.failed++;
        if (type(error_sink) == "function") {
            try {
                error_sink(name, event_type, err);
            }
            catch (nested) {
            }
        }
    }

    self.on_error = function(sink) {
        error_sink = (type(sink) == "function") ? sink : null;
    };

    function dispatch(event_type, event) {
        let subscribers = handlers[event_type];
        if (type(subscribers) != "array")
            return 0;

        let ran = 0;
        let stamp = now_ms();

        for (let record in subscribers) {
            if (record.cooldown > 0 && record.last_run >= 0 &&
                (stamp - record.last_run) < record.cooldown * 1000) {
                counters.skipped++;
                continue;
            }

            record.last_run = stamp;
            record.runs++;
            try {
                record.handler(event);
                counters.delivered++;
                ran++;
            }
            catch (err) {
                report_error(record.name, event_type, err);
            }
        }
        return ran;
    }

    self.emit = function(event_type, payload) {
        event_type = as_string(event_type);
        if (event_type == "")
            return 0;

        counters.emitted++;

        let payload_obj = (type(payload) == "object") ? payload : {};

        // If journal attached, record event to persistent journal
        if (attached_journal != null && type(attached_journal.record) == "function") {
            let meta = {
                severity: payload_obj.severity || "info",
                source: payload_obj.source || "bus",
                message: payload_obj.message || "",
                job_id: payload_obj.job_id,
                correlation_id: payload_obj.correlation_id
            };
            try {
                attached_journal.record(event_type, payload_obj, meta);
            } catch (je) {}
        }

        return dispatch(event_type, {
            type: event_type,
            payload: payload_obj,
            ts: time(),
            ms: now_ms()
        });
    };

    self.emit_once = function(event_type, payload, window_seconds, key) {
        event_type = as_string(event_type);
        if (event_type == "")
            return -1;

        let window = window_seconds != null ? int(window_seconds) : 0;
        let dedup_key = event_type + " " + as_string(key);
        let stamp = now_ms();

        if (window > 0) {
            let previous = last_emit[dedup_key];
            if (previous != null && (stamp - int(previous)) < window * 1000) {
                counters.suppressed++;
                return -1;
            }
        }
        last_emit[dedup_key] = stamp;

        return self.emit(event_type, payload);
    };

    self.has = function(event_type) {
        let subscribers = handlers[as_string(event_type)];
        return type(subscribers) == "array" && length(subscribers) > 0;
    };

    self.reset_timers = function() {
        last_emit = {};
        for (let event_type in keys(handlers)) {
            for (let record in handlers[event_type])
                record.last_run = -1;
        }
    };

    self.stats = function() {
        let subscriber_count = 0;
        for (let event_type in keys(handlers))
            subscriber_count += length(handlers[event_type]);

        return {
            emitted: counters.emitted,
            suppressed: counters.suppressed,
            delivered: counters.delivered,
            skipped: counters.skipped,
            failed: counters.failed,
            types: length(keys(handlers)),
            subscribers: subscriber_count
        };
    };

    self.subscriber_runs = function() {
        let out = {};
        for (let event_type in keys(handlers)) {
            for (let record in handlers[event_type])
                out[record.name] = record.runs;
        }
        return out;
    };

    return self;
}

// ---------------------------------------------------------------------------
// Module Exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        bus,
        journal,
        redact,
        redact_string,
        is_sensitive_key,
        now_ms,
        get_journal_dir,
        get_journal_path,
        DEFAULT_JOURNAL_MAX_ENTRIES,
        DEFAULT_JOURNAL_MAX_BYTES
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ---------------------------------------------------------------------------
// CLI Interface
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

if (mode == "selftest") {
    let pass = 0;
    let fail = 0;

    function assert(cond, name) {
        if (cond) {
            pass++;
        } else {
            fail++;
            warn("FAIL: " + name + "\n");
        }
    }

    // 1. Bus selftest
    let b = bus();
    let seen = [];
    b.on("t", function(ev) { push(seen, ev.type); }, { name: "probe" });
    b.emit("t", {});
    assert(length(seen) == 1 && seen[0] == "t", "bus publish/subscribe");

    // 2. Secret redaction
    let test_obj = {
        password: "super_secret_password_123",
        token: "bearer_secret_token",
        api_key: "ai_api_key_xyz",
        nested: {
            telegram_token: "1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi",
            user: "admin",
            proxy_url: "vless://12345678-1234-1234-1234-1234567890ab@myserver.com:443"
        },
        public_info: "safe_value"
    };
    let clean = redact(test_obj);
    assert(clean.password == "[REDACTED]", "redact password field");
    assert(clean.token == "[REDACTED]", "redact token field");
    assert(clean.api_key == "[REDACTED]", "redact api_key field");
    assert(clean.nested.telegram_token == "[REDACTED]", "redact nested telegram_token key");
    assert(clean.public_info == "safe_value", "preserve non-sensitive key");
    assert(index(clean.nested.proxy_url, "12345678-1234") < 0, "redact UUID from proxy URL");

    // 3. String redaction
    let s_with_token = "Connecting using Telegram bot token 9876543210:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567 to send alert";
    let s_redacted = redact_string(s_with_token);
    assert(index(s_redacted, "9876543210:") < 0, "redact raw telegram bot token in string");
    assert(index(s_redacted, "[REDACTED_TELEGRAM_TOKEN]") >= 0, "insert REDACTED_TELEGRAM_TOKEN marker");

    // 4. Bounded journal recording & querying
    let tmp_journal_file = sprintf("/tmp/tachyon_journal_test_%d.jsonl", now_ms());
    let j = journal({ path: tmp_journal_file, max_entries: 5, max_bytes: 4096 });
    j.clear();

    j.record("service.start", { bot_token: "123456:secret", mode: "standard" }, { severity: "info", source: "core.service", message: "Service started" });
    j.record("dns.failure", { domain: "example.com" }, { severity: "error", source: "watchdog", message: "DNS resolution failed" });

    let entries = j.query();
    assert(length(entries) == 2, "query returns all entries");
    assert(entries[0].event == "dns.failure", "query defaults to newest first");
    assert(entries[1].data.bot_token == "[REDACTED]", "recorded data is automatically redacted");

    // Filter by severity
    let error_entries = j.query({ severity: "error" });
    assert(length(error_entries) == 1 && error_entries[0].event == "dns.failure", "filter by severity");

    // Compaction on bounding
    for (let i = 0; i < 10; i++) {
        j.record("flood.event", { idx: i }, { message: "flood " + i });
    }
    j.compact();
    let stats = j.stats();
    assert(stats.count <= 5, "compact enforces max_entries limit");

    j.clear();
    try { fs.unlink(tmp_journal_file); } catch (e) {}

    if (fail == 0) {
        print("ok\n");
        exit(0);
    } else {
        warn(sprintf("events.uc selftest: %d passed, %d failed\n", pass, fail));
        print("fail\n");
        exit(1);
    }
}
else if (mode == "record") {
    let ev_name = ARGV[1] || "";
    let raw_data = ARGV[2] || "{}";
    let sev = ARGV[3] || "info";
    let src = ARGV[4] || "tachyon";
    let msg = ARGV[5] || "";

    let data = {};
    try { data = json(raw_data); } catch (e) { data = { raw: raw_data }; }

    let j = journal();
    let entry = j.record(ev_name, data, { severity: sev, source: src, message: msg });
    print(sprintf("%J\n", entry));
    exit(entry != null ? 0 : 1);
}
else if (mode == "query") {
    let raw_filter = ARGV[1] || "{}";
    let filter = {};
    try { filter = json(raw_filter); } catch (e) { filter = {}; }

    let j = journal();
    let entries = j.query(filter);
    print(sprintf("%J\n", entries));
    exit(0);
}
else if (mode == "tail") {
    let count = ARGV[1] != null ? int(ARGV[1]) : 10;
    let j = journal();
    let entries = j.tail(count);
    print(sprintf("%J\n", entries));
    exit(0);
}
else if (mode == "stats") {
    let j = journal();
    print(sprintf("%J\n", j.stats()));
    exit(0);
}
else if (mode == "clear") {
    let j = journal();
    exit(j.clear() ? 0 : 1);
}
else if (mode == "redact") {
    let raw = ARGV[1] || "";
    let parsed = null;
    try { parsed = json(raw); } catch (e) {}
    if (parsed != null) {
        print(sprintf("%J\n", redact(parsed)));
    } else {
        print(redact_string(raw), "\n");
    }
    exit(0);
}
else {
    warn("Usage: core/events.uc <selftest|record|query|tail|stats|clear|redact> ...\n");
    exit(1);
}
