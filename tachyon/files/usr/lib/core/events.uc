#!/usr/bin/env ucode
//
// Event bus: publish/subscribe with per-subscriber cooldown, publish-side
// deduplication, deterministic priority ordering and handler error isolation.
//
// The bus is deliberately domain-agnostic: it knows nothing about sing-box,
// UCI or reload locks. Observation belongs to service/event_controller.uc,
// remediation to service/watchdog.uc. Keeping this file free of I/O is what
// makes it directly unit-testable (see tests/event_bus.sh).
//
// Timing uses clock(true) (CLOCK_MONOTONIC) rather than time(): cooldown and
// dedup windows must not be skewed by an NTP step, which is a real event on
// routers that boot before the network is up.

// Monotonic milliseconds. Independent of wall-clock jumps.
function now_ms() {
    let c = clock(true);
    if (type(c) != "array" || length(c) < 2)
        return 0;
    return c[0] * 1000 + int(c[1] / 1000000);
}

let common = require("core.common");
let as_string = common.as_string;

// Creates an isolated bus. Each instance owns its subscriber table, dedup
// state and counters, so tests can build a fresh bus per assertion.
function bus() {
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

    let self = {};

    // Registers a handler. Options:
    //   name     — label used in error reports and stats (defaults to type)
    //   cooldown — minimum seconds between two invocations of THIS handler.
    //              Replaces the hand-rolled last_*_time globals.
    //   priority — lower runs first; ties keep registration order.
    self.on = function(event_type, handler, opts) {
        event_type = as_string(event_type);
        if (event_type == "" || type(handler) != "function")
            return false;

        let options = (type(opts) == "object") ? opts : {};
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

        // Stable sort keeps registration order within one priority level, so
        // subscriber ordering stays reproducible across runs.
        sort(handlers[event_type], function(a, b) { return a.priority - b.priority; });
        return true;
    };

    // Reports a handler failure without letting it abort the remaining
    // subscribers. This is the isolation that safe_call() used to provide
    // around every individual check in the old watchdog loop.
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

    // Installs the sink used to log handler failures. Kept injectable so the
    // bus itself never depends on a logging backend.
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
            // Cooldown is per subscriber, not per event type: two handlers on
            // the same fact may legitimately want different pacing.
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

    // Publishes a fact. Returns the number of handlers that completed.
    self.emit = function(event_type, payload) {
        event_type = as_string(event_type);
        if (event_type == "")
            return 0;

        counters.emitted++;
        return dispatch(event_type, {
            type: event_type,
            payload: (type(payload) == "object") ? payload : {},
            ts: time(),
            ms: now_ms()
        });
    };

    // Publishes a fact at most once per window_seconds. The dedup key is the
    // event type plus an optional caller-supplied discriminator, so
    // "same problem" can be defined per source (e.g. one key per domain).
    // Returns -1 when the emit was suppressed as a duplicate.
    self.emit_once = function(event_type, payload, window_seconds, key) {
        event_type = as_string(event_type);
        if (event_type == "")
            return -1;

        let window = window_seconds != null ? int(window_seconds) : 0;
        let dedup_key = event_type + "" + as_string(key);
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

    // True when at least one handler is registered for the type. Lets sources
    // skip an expensive probe nobody is listening to.
    self.has = function(event_type) {
        let subscribers = handlers[as_string(event_type)];
        return type(subscribers) == "array" && length(subscribers) > 0;
    };

    // Drops dedup and cooldown state without unsubscribing. Used when the
    // world changed under us (config reload) and past timing is meaningless.
    self.reset_timers = function() {
        last_emit = {};
        for (let event_type in keys(handlers)) {
            for (let record in handlers[event_type])
                record.last_run = -1;
        }
    };

    // Counter snapshot for ai-status-full.
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

    // Per-handler run counts, ordered by event type. Diagnostic aid: shows at
    // a glance which subscriber is actually firing in production.
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

function module_exports() {
    return {
        bus,
        now_ms
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

// CLI surface exists for the shell test suite, which has no way to import a
// ucode module directly.
let mode = ARGV[0] || "";

if (mode == "selftest") {
    let b = bus();
    let seen = [];
    b.on("t", function(ev) { push(seen, ev.type); }, { name: "probe" });
    b.emit("t", {});
    print(length(seen) == 1 && seen[0] == "t" ? "ok\n" : "fail\n");
    exit(length(seen) == 1 ? 0 : 1);
}
else {
    warn("Usage: core/events.uc <selftest>\n");
    exit(1);
}
