#!/usr/bin/env ucode
//
// Unified Transaction Engine for Tachyon.
//
// Provides robust, multi-phase transactional execution with automatic rollback
// and compensation stacks for critical system operations:
//   - Component installs/updates and Tachyon self-updates
//   - Routing engine variant switches (sing-box <-> steer)
//   - Configuration changes and candidate state applications
//   - Firewall and routing table modifications
//
// Lifecycle:
//   PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT
//
// Rollback Lifecycle (triggered on any failure, exception, or health check drop):
//   FAIL -> ROLLBACK (LIFO compensations) -> VERIFY_ROLLBACK -> ROLLED_BACK (or FAILED)
//
// Key Features:
//   - LIFO compensation stack (last change reverted first)
//   - File and UCI config snapshotting with mode/permission preservation
//   - Crash resilience: serialized state in /var/run/tachyon/tx/<tx_id>/tx.json
//   - Process identity integration (protects against PID recycling & detects stale executors)
//   - Structured audit logging via core.logging
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;

let proc = null;
try { proc = require("core.process"); } catch (e) {}

let logging = null;
try { logging = require("core.logging"); } catch (e) {}

// ---------------------------------------------------------------------------
// Constants & Lifecycle Phases
// ---------------------------------------------------------------------------

const PHASE_PLAN = "plan";
const PHASE_PREFLIGHT = "preflight";
const PHASE_SNAPSHOT = "snapshot";
const PHASE_MUTATE = "mutate";
const PHASE_VALIDATE = "validate";
const PHASE_ACTIVATE = "activate";
const PHASE_VERIFY = "verify";
const PHASE_COMMIT = "commit";

const PHASE_FAIL = "fail";
const PHASE_ROLLBACK = "rollback";
const PHASE_VERIFY_ROLLBACK = "verify_rollback";
const PHASE_ROLLED_BACK = "rolled_back";
const PHASE_FAILED = "failed";

const STATUS_IN_PROGRESS = "in_progress";
const STATUS_COMMITTED = "committed";
const STATUS_ROLLED_BACK = "rolled_back";
const STATUS_FAILED = "failed";

const VALID_TRANSITIONS = {
    [PHASE_PLAN]:            [PHASE_PREFLIGHT, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_PREFLIGHT]:       [PHASE_SNAPSHOT, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_SNAPSHOT]:        [PHASE_MUTATE, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_MUTATE]:          [PHASE_VALIDATE, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_VALIDATE]:        [PHASE_ACTIVATE, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_ACTIVATE]:        [PHASE_VERIFY, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_VERIFY]:          [PHASE_COMMIT, PHASE_FAIL, PHASE_ROLLBACK],
    [PHASE_COMMIT]:          [],
    [PHASE_FAIL]:            [PHASE_ROLLBACK, PHASE_FAILED],
    [PHASE_ROLLBACK]:        [PHASE_VERIFY_ROLLBACK, PHASE_FAILED],
    [PHASE_VERIFY_ROLLBACK]: [PHASE_ROLLED_BACK, PHASE_FAILED],
    [PHASE_ROLLED_BACK]:     [],
    [PHASE_FAILED]:          []
};

function get_state_dir() {
    let s = getenv("TACHYON_RUNTIME_STATE_DIR");
    if (s != null && s != "")
        return s;
    if (fs.access("/var/run", "w"))
        return "/var/run/tachyon";
    return "/tmp/tachyon";
}

const GC_MAX_AGE_SECONDS = int(getenv("TACHYON_TX_GC_MAX_AGE") || "86400"); // 24h
const STALE_TTL_SECONDS = int(getenv("TACHYON_TX_STALE_TTL") || "1800");   // 30m

// ---------------------------------------------------------------------------
// Low-level Utilities
// ---------------------------------------------------------------------------

function now_seconds() {
    return time();
}

function file_sha256(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null)
        return "";
    let p = fs.popen("sha256sum " + shell_quote(path) + " 2>/dev/null", "r");
    if (!p)
        return "";
    let line = p.read("line");
    p.close();
    if (!line)
        return "";
    let fields = split(trim(line), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) != null)
        return true;
    let rc = system("mkdir -p " + shell_quote(path) + " 2>/dev/null");
    return rc == 0;
}

function ensure_base_dirs() {
    let state = get_state_dir();
    let tx_base = state + "/tx";
    ensure_dir(tx_base);
}

function copy_file(src, dst) {
    src = as_string(src);
    dst = as_string(dst);
    if (src == "" || dst == "")
        return false;

    // Use cp -f -p to preserve permissions and avoid buffering huge binaries in memory
    let rc = system("cp -f -p " + shell_quote(src) + " " + shell_quote(dst) + " 2>/dev/null");
    if (rc == 0 && fs.stat(dst) != null)
        return true;

    // Fallback via ucode fs
    try {
        let content = fs.readfile(src);
        if (content == null)
            return false;
        let tmp = dst + ".tmp." + int(clock()[1]);
        if (fs.writefile(tmp, content) == null) {
            try { fs.unlink(tmp); } catch (e) {}
            return false;
        }
        let st = fs.stat(src);
        if (st && st.mode) {
            try { fs.chmod(tmp, st.mode); } catch (e) {}
        }
        if (!fs.rename(tmp, dst)) {
            try { fs.unlink(tmp); } catch (e) {}
            return false;
        }
        return true;
    } catch (e) {
        return false;
    }
}

function tx_log(tx, level, msg) {
    let tx_name = (type(tx) == "object" && tx.name) ? tx.name : "tx";
    let tx_id = (type(tx) == "object" && tx.id) ? tx.id : "";
    let full_msg = sprintf("[%s:%s] %s", tx_name, tx_id, msg);

    if (logging && type(logging.write) == "function") {
        logging.write({
            level: level || "info",
            subsystem: "core.transaction",
            operation: tx_name,
            job_id: (type(tx) == "object") ? tx.job_id : null,
            correlation_id: tx_id,
            message: full_msg
        });
    } else {
        let syslog_level = level == "error" ? "err" : (level == "warn" ? "warning" : "info");
        system(sprintf("logger -t tachyon-tx -p user.%s %s 2>/dev/null",
            syslog_level, shell_quote(full_msg)));
    }
}

function get_executor_identity() {
    let my_pid = null;
    try {
        let stat = fs.readfile("/proc/self/stat");
        if (stat != null) {
            let m = match(stat, /^([0-9]+)/);
            if (m)
                my_pid = int(m[1]);
        }
    } catch (e) {}

    if (proc && type(proc.make_identity) == "function") {
        return proc.make_identity(my_pid || int(clock()[0]), "transaction");
    }

    return {
        pid: as_string(my_pid || clock()[0]),
        boot_id: "unknown",
        created_at: now_seconds()
    };
}

function is_executor_alive(tx) {
    if (type(tx) != "object" || type(tx.executor) != "object")
        return false;
    if (proc && type(proc.identity_alive) == "function") {
        return proc.identity_alive(tx.executor);
    }
    let pid = tx.executor.pid;
    if (pid == null)
        return false;
    return system("kill -0 " + shell_quote(as_string(pid)) + " 2>/dev/null") == 0;
}

function is_stale(tx) {
    if (type(tx) != "object")
        return false;
    if (tx.status != STATUS_IN_PROGRESS)
        return false;
    if (!is_executor_alive(tx))
        return true;
    let updated = tx.updated_at || tx.created_at || 0;
    if (now_seconds() - updated > STALE_TTL_SECONDS)
        return true;
    return false;
}

let _tx_id_seq = 0;

function generate_tx_id(name) {
    _tx_id_seq++;
    let t = now_seconds();
    let safe_name = replace(as_string(name || "tx"), /[^a-zA-Z0-9_-]/g, "_");
    let rnd = int(clock()[1] % 10000);
    return sprintf("tx-%d-%s-%04d-%d", t, safe_name, rnd, _tx_id_seq);
}

// ---------------------------------------------------------------------------
// Transaction State & Persistence
// ---------------------------------------------------------------------------

function serialize_tx(tx) {
    return {
        id: tx.id,
        name: tx.name,
        created_at: tx.created_at,
        updated_at: tx.updated_at,
        completed_at: tx.completed_at,
        status: tx.status,
        phase: tx.phase,
        failure_reason: tx.failure_reason,
        executor: tx.executor,
        job_id: tx.job_id,
        opts: tx.opts,
        history: tx.history || [],
        snapshots: tx.snapshots || [],
        compensations: tx.compensations || [],
        rollback_errors: tx.rollback_errors || [],
        result: tx.result
    };
}

function save(tx) {
    if (type(tx) != "object" || !tx.dir)
        return false;
    tx.updated_at = now_seconds();
    ensure_dir(tx.dir);
    let manifest_path = tx.dir + "/tx.json";
    return write_json_file(manifest_path, serialize_tx(tx), 2);
}

function read_tx(tx_id) {
    tx_id = as_string(tx_id);
    if (tx_id == "")
        return null;
    let state = get_state_dir();
    let manifest_path = state + "/tx/" + tx_id + "/tx.json";
    let data = read_json_file(manifest_path);
    if (!data || type(data) != "object")
        return null;
    data.dir = state + "/tx/" + tx_id;
    return data;
}

function cleanup_snapshots(tx) {
    if (type(tx) != "object" || !tx.dir)
        return;
    let snap_dir = tx.dir + "/snapshots";
    if (fs.stat(snap_dir) != null) {
        system("rm -rf " + shell_quote(snap_dir) + " 2>/dev/null");
        ensure_dir(snap_dir);
    }
}

// ---------------------------------------------------------------------------
// Compensations & Snapshot Management
// ---------------------------------------------------------------------------

function execute_compensation(tx, comp) {
    comp.executed = true;
    let ctype = comp.type;
    let data = comp.data || {};

    // 1. In-memory closure / callback if present
    if (type(tx._callbacks) == "object" && type(tx._callbacks[as_string(comp.id)]) == "function") {
        try {
            let res = tx._callbacks[as_string(comp.id)](tx, data);
            if (res === false || (type(res) == "object" && res.ok === false)) {
                comp.success = false;
                comp.error = (type(res) == "object" && res.error) ? res.error : "Callback returned false";
                return false;
            }
            comp.success = true;
            return true;
        } catch (e) {
            comp.success = false;
            comp.error = "Callback exception: " + as_string(e);
            return false;
        }
    }

    // 2. Built-in: restore file from snapshot
    if (ctype == "restore_file") {
        let target = data.target_path;
        let snap = data.snapshot_file;
        if (!target || !snap || fs.stat(snap) == null) {
            comp.success = false;
            comp.error = "Snapshot missing for " + as_string(target);
            return false;
        }
        if (!copy_file(snap, target)) {
            comp.success = false;
            comp.error = "Failed to copy snapshot to " + as_string(target);
            return false;
        }
        if (data.mode != null) {
            try { fs.chmod(target, data.mode); } catch (e) {}
        }
        comp.success = true;
        return true;
    }

    // 3. Built-in: remove newly created file
    if (ctype == "remove_file") {
        let target = data.target_path;
        if (target && fs.stat(target) != null) {
            try {
                fs.unlink(target);
                comp.success = true;
                return true;
            } catch (e) {
                comp.success = false;
                comp.error = "Failed to unlink " + as_string(target) + ": " + as_string(e);
                return false;
            }
        }
        comp.success = true;
        return true;
    }

    // 4. Built-in: restore UCI configuration
    if (ctype == "restore_uci") {
        let config_name = data.config_name || "tachyon";
        let target = data.target_path || ("/etc/config/" + config_name);
        let snap = data.snapshot_file;
        if (!snap || fs.stat(snap) == null) {
            comp.success = false;
            comp.error = "UCI snapshot missing for " + as_string(config_name);
            return false;
        }
        if (!copy_file(snap, target)) {
            comp.success = false;
            comp.error = "Failed to copy UCI snapshot to " + as_string(target);
            return false;
        }
        try { fs.chmod(target, 384); } catch (e) {} // 0600
        system("uci revert " + shell_quote(config_name) + " 2>/dev/null");
        comp.success = true;
        return true;
    }

    // 5. Built-in: shell command
    if (ctype == "command") {
        let cmd = data.command;
        if (cmd == null || cmd == "") {
            comp.success = true;
            return true;
        }
        let rc = system(cmd);
        if (rc != 0) {
            comp.success = false;
            comp.error = "Rollback command exited with code " + as_string(rc);
            return false;
        }
        comp.success = true;
        return true;
    }

    // Unknown or no-op compensation
    comp.success = true;
    return true;
}

function register_compensation(tx, comp_type, data, fn) {
    if (type(tx) != "object")
        return null;
    if (type(tx.compensations) != "array")
        tx.compensations = [];

    let comp = {
        id: length(tx.compensations) + 1,
        type: as_string(comp_type),
        data: (type(data) == "object") ? data : {},
        created_at: now_seconds(),
        executed: false,
        success: null,
        error: null
    };

    push(tx.compensations, comp);

    if (type(fn) == "function") {
        if (type(tx._callbacks) != "object")
            tx._callbacks = {};
        tx._callbacks[as_string(comp.id)] = fn;
    }

    save(tx);
    return comp.id;
}

function snapshot_file(tx, path) {
    if (type(tx) != "object")
        return null;
    path = as_string(path);
    if (path == "")
        return null;

    if (type(tx.snapshots) != "array")
        tx.snapshots = [];
    let snap_id = length(tx.snapshots) + 1;

    let st = fs.stat(path);
    if (st != null) {
        let basename = path;
        let slash = rindex(path, "/");
        if (slash >= 0)
            basename = substr(path, slash + 1);
        let safe_name = replace(basename, /[^a-zA-Z0-9._-]/g, "_");
        let snap_file = sprintf("%s/snapshots/snap_%03d_%s", tx.dir, snap_id, safe_name);

        if (!copy_file(path, snap_file)) {
            tx_log(tx, "error", "Failed to create snapshot of " + path);
            return null;
        }

        let snap_rec = {
            id: snap_id,
            path: path,
            snapshot_file: snap_file,
            existed: true,
            mode: st.mode,
            size: st.size,
            sha256: file_sha256(path)
        };
        push(tx.snapshots, snap_rec);

        register_compensation(tx, "restore_file", {
            target_path: path,
            snapshot_file: snap_file,
            mode: st.mode,
            sha256: snap_rec.sha256
        });

        save(tx);
        return snap_rec;
    } else {
        let snap_rec = {
            id: snap_id,
            path: path,
            snapshot_file: null,
            existed: false
        };
        push(tx.snapshots, snap_rec);

        register_compensation(tx, "remove_file", {
            target_path: path
        });

        save(tx);
        return snap_rec;
    }
}

function snapshot_uci(tx, config_name) {
    config_name = as_string(config_name || "tachyon");
    let config_path = "/etc/config/" + config_name;
    let snap = snapshot_file(tx, config_path);
    if (snap && snap.existed) {
        register_compensation(tx, "restore_uci", {
            config_name: config_name,
            target_path: config_path,
            snapshot_file: snap.snapshot_file
        });
    }
    return snap;
}

// ---------------------------------------------------------------------------
// Lifecycle Transitions
// ---------------------------------------------------------------------------

function is_valid_transition(from_phase, to_phase) {
    let allowed = VALID_TRANSITIONS[as_string(from_phase)] || [];
    for (let p in allowed) {
        if (p == to_phase)
            return true;
    }
    return false;
}

function transition(tx, next_phase, meta) {
    if (type(tx) != "object")
        return false;
    let current = tx.phase || PHASE_PLAN;

    // Allow idempotency
    if (current == next_phase)
        return true;

    // Allow direct transition to FAIL or ROLLBACK from any in-progress state
    let valid = is_valid_transition(current, next_phase);
    if (!valid && (next_phase == PHASE_FAIL || next_phase == PHASE_ROLLBACK) && tx.status == STATUS_IN_PROGRESS) {
        valid = true;
    }

    if (!valid) {
        tx_log(tx, "error", sprintf("Invalid phase transition requested: %s -> %s", current, next_phase));
        return false;
    }

    let t = now_seconds();
    let transition_entry = {
        from: current,
        to: next_phase,
        ts: t,
        meta: (type(meta) == "object") ? meta : {}
    };

    if (type(tx.history) != "array")
        tx.history = [];
    push(tx.history, transition_entry);

    tx.phase = next_phase;
    tx_log(tx, "info", sprintf("Phase %s -> %s", current, next_phase));
    save(tx);
    return true;
}

// ---------------------------------------------------------------------------
// Rollback & Commit
// ---------------------------------------------------------------------------

function rollback(tx, reason) {
    if (type(tx) != "object")
        return { ok: false, error: "Invalid transaction" };

    reason = as_string(reason || "Unspecified rollback reason");
    tx.failure_reason = reason;
    tx_log(tx, "warn", "Initiating rollback: " + reason);

    // Transition to fail then rollback
    transition(tx, PHASE_FAIL, { reason: reason });
    transition(tx, PHASE_ROLLBACK, { reason: reason });

    if (type(tx.rollback_errors) != "array")
        tx.rollback_errors = [];

    // LIFO execution of registered compensations
    let comps = tx.compensations || [];
    for (let i = length(comps) - 1; i >= 0; i--) {
        let comp = comps[i];
        if (!comp.executed) {
            let ok = execute_compensation(tx, comp);
            if (!ok) {
                push(tx.rollback_errors, {
                    comp_id: comp.id,
                    type: comp.type,
                    error: comp.error
                });
                tx_log(tx, "error", sprintf("Compensation %d (%s) failed: %s", comp.id, comp.type, comp.error));
            }
        }
    }

    // Transition to verify_rollback
    transition(tx, PHASE_VERIFY_ROLLBACK);

    let verify_ok = true;
    for (let s in (tx.snapshots || [])) {
        if (s.existed && fs.stat(s.path) == null) {
            verify_ok = false;
            push(tx.rollback_errors, {
                error: "Restored file missing: " + s.path
            });
        }
    }

    if (verify_ok && length(tx.rollback_errors) == 0) {
        transition(tx, PHASE_ROLLED_BACK);
        tx.status = STATUS_ROLLED_BACK;
        tx.completed_at = now_seconds();
        save(tx);
        tx_log(tx, "info", "Rollback completed successfully");
        return { ok: false, rolled_back: true, reason: reason };
    } else {
        transition(tx, PHASE_FAILED);
        tx.status = STATUS_FAILED;
        tx.completed_at = now_seconds();
        save(tx);
        tx_log(tx, "error", "Rollback finished with errors");
        return { ok: false, rolled_back: false, reason: reason, rollback_errors: tx.rollback_errors };
    }
}

function commit(tx) {
    if (type(tx) != "object")
        return { ok: false, error: "Invalid transaction" };

    if (!transition(tx, PHASE_COMMIT)) {
        let err = sprintf("Cannot commit from phase %s", tx.phase);
        rollback(tx, err);
        return { ok: false, error: err };
    }

    tx.status = STATUS_COMMITTED;
    tx.completed_at = now_seconds();

    // Clean up temporary snapshot copies to reclaim RAM/tmpfs storage
    if (!tx.opts || !tx.opts.keep_snapshots) {
        cleanup_snapshots(tx);
    }

    save(tx);
    tx_log(tx, "info", "Transaction committed successfully");
    return { ok: true, tx_id: tx.id };
}

// ---------------------------------------------------------------------------
// Step Execution & Declarative Runner
// ---------------------------------------------------------------------------

function step(tx, phase, fn) {
    if (type(tx) != "object")
        return { ok: false, error: "Invalid transaction" };

    if (!transition(tx, phase)) {
        let err = sprintf("Cannot transition to %s from %s", phase, tx.phase);
        let rb = rollback(tx, err);
        return { ok: false, rolled_back: rb.rolled_back, error: err };
    }

    let res = null;
    try {
        res = fn(tx);
    } catch (e) {
        let err = sprintf("Exception in %s: %s", phase, as_string(e));
        let rb = rollback(tx, err);
        return { ok: false, rolled_back: rb.rolled_back, error: err, exception: e };
    }

    if (res === false || (type(res) == "object" && res.ok === false)) {
        let err = (type(res) == "object" && res.error) ? res.error : sprintf("Step %s failed", phase);
        let rb = rollback(tx, err);
        return { ok: false, rolled_back: rb.rolled_back, error: err, result: res };
    }

    save(tx);
    return { ok: true, result: res };
}

function attach_tx_methods(tx) {
    if (type(tx) != "object")
        return tx;
    tx.step = (phase, fn) => step(tx, phase, fn);
    tx.transition = (phase, meta) => transition(tx, phase, meta);
    tx.snapshot_file = (path) => snapshot_file(tx, path);
    tx.snapshot_uci = (config_name) => snapshot_uci(tx, config_name);
    tx.register_compensation = (type, data, fn) => register_compensation(tx, type, data, fn);
    tx.rollback = (reason) => rollback(tx, reason);
    tx.commit = () => commit(tx);
    return tx;
}

function create(name, opts) {
    ensure_base_dirs();
    let options = (type(opts) == "object") ? opts : {};
    let tx_id = as_string(options.id || generate_tx_id(name));

    let state_dir = get_state_dir();
    let tx_dir = state_dir + "/tx/" + tx_id;
    ensure_dir(tx_dir + "/snapshots");

    let tx = {
        id: tx_id,
        name: as_string(name || "unnamed"),
        dir: tx_dir,
        created_at: now_seconds(),
        updated_at: now_seconds(),
        completed_at: null,
        status: STATUS_IN_PROGRESS,
        phase: PHASE_PLAN,
        failure_reason: null,
        executor: get_executor_identity(),
        job_id: as_string(options.job_id || ""),
        opts: options,
        history: [
            { from: null, to: PHASE_PLAN, ts: now_seconds(), meta: {} }
        ],
        snapshots: [],
        compensations: [],
        rollback_errors: [],
        result: null,
        _callbacks: {}
    };

    attach_tx_methods(tx);
    save(tx);
    tx_log(tx, "info", sprintf("Created transaction %s", tx_id));
    return tx;
}

function run(name, steps, opts) {
    let tx = create(name, opts);
    if (!tx)
        return { ok: false, error: "Failed to create transaction" };

    let phases = [
        PHASE_PLAN,
        PHASE_PREFLIGHT,
        PHASE_SNAPSHOT,
        PHASE_MUTATE,
        PHASE_VALIDATE,
        PHASE_ACTIVATE,
        PHASE_VERIFY
    ];

    for (let phase in phases) {
        let fn = steps ? steps[phase] : null;
        if (type(fn) == "function") {
            let res = step(tx, phase, fn);
            if (!res || res.ok === false) {
                return res;
            }
        } else {
            transition(tx, phase);
        }
    }

    return commit(tx);
}

// ---------------------------------------------------------------------------
// Query, List, GC & Recovery
// ---------------------------------------------------------------------------

function query(tx_id) {
    tx_id = as_string(tx_id);
    if (tx_id == "")
        return null;
    let state = read_tx(tx_id);
    if (!state)
        return null;
    state.is_stale = is_stale(state);
    state.executor_alive = is_executor_alive(state);
    attach_tx_methods(state);
    return state;
}

function list(filter_opts) {
    ensure_base_dirs();
    let opts = (type(filter_opts) == "object") ? filter_opts : {};
    let state_dir = get_state_dir();
    let tx_base = state_dir + "/tx";
    let entries = fs.lsdir(tx_base) || [];
    let result = [];

    for (let entry in entries) {
        if (entry == "." || entry == "..")
            continue;
        let manifest_path = tx_base + "/" + entry + "/tx.json";
        let state = read_json_file(manifest_path);
        if (state && type(state) == "object") {
            if (opts.status != null && state.status != opts.status)
                continue;
            if (opts.name != null && state.name != opts.name)
                continue;
            push(result, state);
        }
    }

    sort(result, (a, b) => (b.created_at || 0) - (a.created_at || 0));
    return result;
}

function recover(tx_id) {
    let tx = read_tx(tx_id);
    if (!tx)
        return { ok: false, error: "Transaction not found: " + as_string(tx_id) };

    if (tx.status != STATUS_IN_PROGRESS) {
        return { ok: true, message: "Transaction already finalized: " + tx.status };
    }

    tx_log(tx, "warn", "Executing external recovery/rollback for " + tx.id);
    return rollback(tx, "External recovery initiated for abandoned or failed transaction");
}

function gc(max_age_seconds) {
    ensure_base_dirs();
    let max_age = (max_age_seconds != null) ? int(max_age_seconds) : GC_MAX_AGE_SECONDS;
    let now = now_seconds();
    let cleaned = 0;
    let recovered = 0;

    let state_dir = get_state_dir();
    let tx_base = state_dir + "/tx";
    let entries = fs.lsdir(tx_base) || [];

    for (let entry in entries) {
        if (entry == "." || entry == "..")
            continue;
        let tx_dir = tx_base + "/" + entry;
        let manifest_path = tx_dir + "/tx.json";
        let state = read_json_file(manifest_path);
        if (!state) {
            system("rm -rf " + shell_quote(tx_dir) + " 2>/dev/null");
            cleaned++;
            continue;
        }

        let age = now - (state.updated_at || state.created_at || now);

        if (state.status == STATUS_IN_PROGRESS && is_stale(state)) {
            tx_log(state, "warn", "GC found stale transaction " + state.id + ", recovering");
            recover(state.id);
            recovered++;
            continue;
        }

        if (state.status != STATUS_IN_PROGRESS && age >= max_age) {
            system("rm -rf " + shell_quote(tx_dir) + " 2>/dev/null");
            cleaned++;
        }
    }

    return { ok: true, cleaned: cleaned, recovered: recovered };
}

// ---------------------------------------------------------------------------
// Module Exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Lifecycle phase constants
        PHASE_PLAN,
        PHASE_PREFLIGHT,
        PHASE_SNAPSHOT,
        PHASE_MUTATE,
        PHASE_VALIDATE,
        PHASE_ACTIVATE,
        PHASE_VERIFY,
        PHASE_COMMIT,
        PHASE_FAIL,
        PHASE_ROLLBACK,
        PHASE_VERIFY_ROLLBACK,
        PHASE_ROLLED_BACK,
        PHASE_FAILED,

        // Status constants
        STATUS_IN_PROGRESS,
        STATUS_COMMITTED,
        STATUS_ROLLED_BACK,
        STATUS_FAILED,

        // Core API
        create,
        step,
        transition,
        snapshot_file,
        snapshot_uci,
        register_compensation,
        rollback,
        commit,
        run,

        // Queries & Maintenance
        query,
        list,
        recover,
        gc,
        is_stale,
        is_executor_alive,
        save
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ---------------------------------------------------------------------------
// CLI & Selftest
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

let _test_pass = 0;
let _test_fail = 0;

function _assert(cond, msg) {
    if (cond) {
        _test_pass++;
    } else {
        _test_fail++;
        print("FAIL: " + msg + "\n");
    }
}

if (mode == "selftest") {
    _test_pass = 0;
    _test_fail = 0;

    let tmp_test_dir = "/tmp/tachyon_tx_selftest_" + int(clock()[1]);
    system("mkdir -p " + tmp_test_dir);

    // Test 1: Happy path run() through all phases
    let test_file = tmp_test_dir + "/config.txt";
    fs.writefile(test_file, "initial_value\n");

    let res = run("selftest_happy", {
        plan: function(tx) { return { target: "test" }; },
        preflight: function(tx) { return true; },
        snapshot: function(tx) {
            let snap = tx.snapshot_file(test_file);
            _assert(snap != null && snap.existed == true, "snapshot_file should capture existing file");
            return true;
        },
        mutate: function(tx) {
            fs.writefile(test_file, "mutated_value\n");
            return true;
        },
        validate: function(tx) {
            let content = trim(fs.readfile(test_file) || "");
            return content == "mutated_value";
        },
        activate: function(tx) { return true; },
        verify: function(tx) { return true; }
    }, {
        create_test: true
    });

    _assert(res.ok == true, "Happy path transaction should commit");
    let q = query(res.tx_id);
    _assert(q != null && q.status == STATUS_COMMITTED, "Committed transaction should be queryable");

    // Test 2: Rollback on validate failure
    let roll_file = tmp_test_dir + "/rollback_test.txt";
    fs.writefile(roll_file, "original_content\n");

    let fail_res = run("selftest_rollback", {
        snapshot: function(tx) {
            tx.snapshot_file(roll_file);
            return true;
        },
        mutate: function(tx) {
            fs.writefile(roll_file, "corrupted_content\n");
            return true;
        },
        validate: function(tx) {
            // Intentionally fail validation
            return { ok: false, error: "Validation intentionally failed" };
        }
    });

    _assert(fail_res.ok == false, "Failing transaction should return ok: false");
    _assert(fail_res.rolled_back == true, "Failing transaction should roll back");
    let restored_content = trim(fs.readfile(roll_file) || "");
    _assert(restored_content == "original_content", "Rollback should restore original file content");

    // Test 3: Remove file created during mutate on rollback
    let new_file = tmp_test_dir + "/newly_created.txt";
    try { fs.unlink(new_file); } catch (e) {}

    let fail_new = run("selftest_new_file_rollback", {
        snapshot: function(tx) {
            tx.snapshot_file(new_file); // did not exist
            return true;
        },
        mutate: function(tx) {
            fs.writefile(new_file, "should_be_deleted_on_rollback\n");
            return true;
        },
        validate: function(tx) {
            return false;
        }
    });

    _assert(fail_new.rolled_back == true, "Rollback for new file should succeed");
    _assert(fs.stat(new_file) == null, "File created during mutate should be removed on rollback");

    // Clean up
    system("rm -rf " + tmp_test_dir);

    print(sprintf("Selftest complete: %d passed, %d failed\n", _test_pass, _test_fail));
    exit(_test_fail == 0 ? 0 : 1);
}
else if (mode == "list") {
    let txs = list();
    print(sprintf("%J\n", txs));
    exit(0);
}
else if (mode == "query") {
    if (!ARGV[1]) {
        warn("Usage: transaction.uc query <tx_id>\n");
        exit(1);
    }
    let tx = query(ARGV[1]);
    if (!tx) {
        warn("Transaction not found\n");
        exit(1);
    }
    print(sprintf("%J\n", tx));
    exit(0);
}
else if (mode == "rollback") {
    if (!ARGV[1]) {
        warn("Usage: transaction.uc rollback <tx_id>\n");
        exit(1);
    }
    let res = recover(ARGV[1]);
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "gc") {
    let res = gc();
    print(sprintf("%J\n", res));
    exit(0);
}
else {
    print("Usage: core/transaction.uc <selftest|list|query|rollback|gc> ...\n");
    exit(1);
}
