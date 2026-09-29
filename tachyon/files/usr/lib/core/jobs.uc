#!/usr/bin/env ucode
//
// Unified Job Engine.
//
// Every background operation in Tachyon — component updates, subscription
// updates, fuzzer runs, DNS benchmarks, diagnostics — currently manages its
// own PID file, stale detection, phase tracking, and cleanup independently.
// This creates ~12 different implementations of the same lifecycle, each with
// its own edge cases and failure modes.
//
// This module provides a single lifecycle:
//
//   created → queued → preflight → running → verifying → committing → success
//                                     ↘ failed
//                                     ↘ rollback
//                                     ↘ cancelled
//
// Job state is persisted to a JSON file so that:
//   - UI can query progress without polling the process
//   - Stale detection survives process crashes
//   - Phase transitions are atomic (tmp+rename)
//   - Process identity (PID + starttime + boot_id) prevents PID recycling bugs
//   - Cooperative cancellation is supported with critical section protection
//   - Rollback compensations execute in LIFO order on cancel/failure
//
// Callers interact through:
//   jobs.create(kind, target, action)        → job object
//   jobs.start_shell(job, command, opts)     → returns wrapped shell command
//   jobs.run_job(kind, target, action, cmd)  → spawns background worker
//   jobs.heartbeat(job)                      → worker calls periodically
//   jobs.complete(job, result)               → worker calls on success
//   jobs.fail(job, error)                    → worker calls on failure
//   jobs.request_cancel(job_id, reason)      → signals cancel_requested=true
//   jobs.check_cancellation(job)             → worker safe-point check
//   jobs.with_critical_section(job, name, fn)→ protected execution block
//   jobs.cancel(job_id, opts)                → cooperative/forced cancel
//   jobs.query(job_id)                       → reads current state
//   jobs.list_active() / jobs.list_all()     → lists active/all jobs
//   jobs.gc()                                → cleanup stale jobs

let fs = require("fs");
let exec = require("core.exec");
let events = require("core.events");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;
try { logging = require("core.logging"); } catch (e) {}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const JOBS_DIR = STATE_DIR + "/jobs";
const JOB_STATE_FILE_FORMAT = JOBS_DIR + "/%s.json";
const JOB_LOG_DIR = STATE_DIR + "/job-logs";
const JOB_LOG_FILE_FORMAT = JOB_LOG_DIR + "/%s.log";

const DEFAULT_HEARTBEAT_INTERVAL = int(getenv("TACHYON_JOB_HEARTBEAT_INTERVAL") || "5");
const DEFAULT_HARD_DEADLINE = int(getenv("TACHYON_JOB_HARD_DEADLINE_SECONDS") || "900");
const STALE_TTL_MINUTES = int(getenv("TACHYON_JOB_STALE_TTL_MINUTES") || "60");
const GC_MAX_AGE_SECONDS = int(getenv("TACHYON_JOB_GC_MAX_AGE") || "86400");

// ---------------------------------------------------------------------------
// Job lifecycle phases
// ---------------------------------------------------------------------------

const PHASE_CREATED = "created";
const PHASE_QUEUED = "queued";
const PHASE_PREFLIGHT = "preflight";
const PHASE_RUNNING = "running";
const PHASE_VERIFYING = "verifying";
const PHASE_COMMITTING = "committing";
const PHASE_SUCCESS = "success";
const PHASE_FAILED = "failed";
const PHASE_ROLLBACK = "rollback";
const PHASE_CANCELLED = "cancelled";

const VALID_TRANSITIONS = {
    [PHASE_CREATED]:    [PHASE_QUEUED, PHASE_CANCELLED],
    [PHASE_QUEUED]:     [PHASE_PREFLIGHT, PHASE_RUNNING, PHASE_CANCELLED],
    [PHASE_PREFLIGHT]:  [PHASE_RUNNING, PHASE_FAILED, PHASE_CANCELLED],
    [PHASE_RUNNING]:    [PHASE_VERIFYING, PHASE_FAILED, PHASE_CANCELLED, PHASE_ROLLBACK],
    [PHASE_VERIFYING]:  [PHASE_COMMITTING, PHASE_FAILED, PHASE_ROLLBACK, PHASE_CANCELLED],
    [PHASE_COMMITTING]: [PHASE_SUCCESS, PHASE_FAILED, PHASE_ROLLBACK],
    [PHASE_SUCCESS]:    [],
    [PHASE_FAILED]:     [],
    [PHASE_ROLLBACK]:   [PHASE_FAILED, PHASE_CANCELLED],
    [PHASE_CANCELLED]:  []
};

// ---------------------------------------------------------------------------
// Helper functions (defined before first use)
// ---------------------------------------------------------------------------

function now_seconds() {
    return int(clock()[0]);
}

function ensure_dirs() {
    let state = getenv("TACHYON_RUNTIME_STATE_DIR") || STATE_DIR;
    let jobs_d = state + "/jobs";
    let logs_d = state + "/job-logs";
    exec.run({ argv: ["mkdir", "-p", jobs_d], capture: false, timeout: 5 });
    exec.run({ argv: ["mkdir", "-p", logs_d], capture: false, timeout: 5 });
}

function job_state_path(job_id) {
    return sprintf(JOB_STATE_FILE_FORMAT, job_id);
}

function job_log_path(job_id) {
    return sprintf(JOB_LOG_FILE_FORMAT, job_id);
}

function read_job_state(job_id) {
    return read_json_file(job_state_path(job_id));
}

function sanitize_state_for_json(state) {
    if (type(state) != "object")
        return state;

    let copy = {};
    for (let k in keys(state)) {
        if (k == "rollback_stack") {
            let safe_stack = [];
            for (let item in (state.rollback_stack || [])) {
                if (type(item) == "function") {
                    push(safe_stack, { type: "callback", description: "Function callback" });
                } else if (type(item) == "object") {
                    let safe_item = {};
                    for (let prop in keys(item)) {
                        if (type(item[prop]) != "function")
                            safe_item[prop] = item[prop];
                    }
                    push(safe_stack, safe_item);
                } else {
                    push(safe_stack, item);
                }
            }
            copy[k] = safe_stack;
        } else {
            copy[k] = state[k];
        }
    }
    return copy;
}

function write_job_state(state) {
    ensure_dirs();
    let safe = sanitize_state_for_json(state);
    return write_json_file(job_state_path(state.id), safe, 2);
}

// ---------------------------------------------------------------------------
// Job ID generation
// ---------------------------------------------------------------------------

let _id_counter = 0;

function generate_id(kind, target, action) {
    _id_counter++;
    let ts = time();
    let short_ts = substr(as_string(ts), length(as_string(ts)) - 6);
    return sprintf("%s-%s-%s-%s-%d", as_string(kind), as_string(target), as_string(action), short_ts, _id_counter);
}

// ---------------------------------------------------------------------------
// Job creation
// ---------------------------------------------------------------------------

function create(kind, target, action, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let job_id = as_string(options.id || generate_id(kind, target, action));

    let state = {
        id: job_id,
        kind: as_string(kind),
        target: as_string(target),
        action: as_string(action),

        phase: PHASE_CREATED,
        phase_started_at: now_seconds(),
        created_at: now_seconds(),
        updated_at: now_seconds(),

        // Process identity (replaces bare PID)
        pid: null,
        starttime: null,
        boot_id: exec.boot_id(),

        // Progress tracking
        progress: 0,
        message: as_string(options.message || ""),

        // Version tracking (for component updates)
        from_version: as_string(options.from_version || ""),
        to_version: as_string(options.to_version || ""),

        // Heartbeat
        heartbeat_at: null,
        heartbeat_interval: int(options.heartbeat_interval || DEFAULT_HEARTBEAT_INTERVAL),

        // Hard deadline
        hard_deadline: int(options.hard_deadline || DEFAULT_HARD_DEADLINE),
        deadline_at: null,

        // Cancellation state
        cancel_requested: false,
        cancel_reason: null,
        cancel_requested_at: null,
        cancelled_at: null,
        cancel_forced: false,

        // Critical section / safe point tracking
        in_critical_section: false,
        critical_section_name: null,
        critical_section_entered_at: null,
        safe_point_reached: true,

        // Rollback / Compensations
        rollback_stack: [],
        rolled_back: false,
        rollback_error: null,
        tx_id: as_string(options.tx_id || ""),

        // Result
        result: null,
        error: null
    };

    write_job_state(state);
    return state;
}

// ---------------------------------------------------------------------------
// Phase transitions
// ---------------------------------------------------------------------------

function transition(job, new_phase, extra) {
    let current = job.phase;
    let allowed = VALID_TRANSITIONS[current];
    if (type(allowed) != "array") {
        job.error = sprintf("Invalid current phase: %s", current);
        return job;
    }

    let found = false;
    for (let p in allowed) {
        if (p == new_phase) { found = true; break; }
    }

    if (!found) {
        job.error = sprintf("Invalid transition: %s → %s", current, new_phase);
        return job;
    }

    job.phase = new_phase;
    job.phase_started_at = now_seconds();
    job.updated_at = now_seconds();

    if (new_phase == PHASE_RUNNING) {
        job.deadline_at = now_seconds() + job.hard_deadline;
    }

    if (type(extra) == "object") {
        for (let key in keys(extra))
            job[key] = extra[key];
    }

    write_job_state(job);
    return job;
}

// ---------------------------------------------------------------------------
// Worker API (called from the background process)
// ---------------------------------------------------------------------------

// Mark a job as queued (ready for execution).
function queue(job) {
    return transition(job, PHASE_QUEUED);
}

// Move to preflight (validation phase before actual work).
function preflight(job) {
    return transition(job, PHASE_PREFLIGHT);
}

// Report failure.
function fail(job, error) {
    let extra = {
        error: as_string(error),
        result: { exit_code: 1, error: as_string(error) }
    };
    return transition(job, PHASE_FAILED, extra);
}

// Update heartbeat from within the worker process.
function heartbeat(job) {
    let now = now_seconds();

    // Check hard deadline
    if (job.deadline_at != null && now > job.deadline_at) {
        job.error = sprintf("Hard deadline exceeded (limit: %ds)", job.hard_deadline);
        return fail(job, job.error);
    }

    job.heartbeat_at = now;
    job.updated_at = now;
    write_job_state(job);
    return job;
}

// Report success.
function complete(job, result) {
    let extra = {
        result: result || { exit_code: 0 },
        progress: 100
    };
    return transition(job, PHASE_SUCCESS, extra);
}

// Start the background worker. Returns shell fragment to execute.
function build_worker_wrapper(job, command, timeout) {
    let state_file = job_state_path(job.id);
    let hb_interval = as_string(job.heartbeat_interval);
    let deadline = as_string(timeout);

    // Shell wrapper traps signals and handles graceful exit
    let wrapper = sprintf(
        '(__job_id=%s __state_file=%s __hb_interval=%s __deadline=%s; ' +
        'echo $$ > /tmp/tachyon-job-$__job_id.pid; ' +
        '__start=$(cat /proc/$$/stat 2>/dev/null | sed "s/.*\\) //"); ' +
        'set -o pipefail; ' +
        'trap \'__on_term\' TERM INT; ' +
        '__on_term() { ' +
        '  __now=$(date -u +%%s); ' +
        '  if grep -q \'"cancel_requested"[[:space:]]*:[[:space:]]*true\' "$__state_file" 2>/dev/null; then ' +
        '    __phase=cancelled; ' +
        '  else ' +
        '    __phase=failed; ' +
        '  fi; ' +
        '  sed -i -e "s/\\"phase\\"[[:space:]]*:[[:space:]]*\\"[^\\"]*\\"/\\"phase\\": \\"$__phase\\"/" ' +
        '         -e "s/\\"updated_at\\"[[:space:]]*:[[:space:]]*[0-9]*/\\"updated_at\\": $__now/" ' +
        '         "$__state_file" 2>/dev/null; ' +
        '  exit 143; ' +
        '}; ' +
        '%s; __rc=$?; ' +
        '__now=$(date -u +%%s); ' +
        'if grep -q \'"cancel_requested"[[:space:]]*:[[:space:]]*true\' "$__state_file" 2>/dev/null; then ' +
        '  __phase=cancelled; ' +
        'elif [ $__rc -eq 0 ]; then ' +
        '  __phase=success; ' +
        'else ' +
        '  __phase=failed; ' +
        'fi; ' +
        'sed -i -e "s/\\"phase\\"[[:space:]]*:[[:space:]]*\\"[^\\"]*\\"/\\"phase\\": \\"$__phase\\"/" ' +
        '       -e "s/\\"updated_at\\"[[:space:]]*:[[:space:]]*[0-9]*/\\"updated_at\\": $__now/" ' +
        '       "$__state_file" 2>/dev/null; ' +
        'exit $__rc)',
        job.id, state_file, hb_interval, deadline,
        command
    );

    return wrapper;
}

function start_shell(job, command, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let timeout = int(options.timeout || job.hard_deadline);

    let wrapped = build_worker_wrapper(job, command, timeout);
    transition(job, PHASE_RUNNING);
    return wrapped;
}

// ---------------------------------------------------------------------------
// Rollback & Compensation management
// ---------------------------------------------------------------------------

function register_rollback(job, compensation) {
    if (type(job.rollback_stack) != "array")
        job.rollback_stack = [];

    push(job.rollback_stack, compensation);
    write_job_state(job);
    return job;
}

function execute_rollback(job, reason) {
    if (job.rolled_back)
        return { ok: true, compensations_run: 0 };

    job.phase = PHASE_ROLLBACK;
    job.phase_started_at = now_seconds();
    job.updated_at = now_seconds();
    write_job_state(job);

    let stack = job.rollback_stack || [];
    let count = 0;
    let errors = [];

    // LIFO order: last registered compensation executes first
    for (let i = length(stack) - 1; i >= 0; i--) {
        let comp = stack[i];
        if (type(comp) == "function") {
            try {
                comp(job, reason);
                count++;
            } catch (e) {
                push(errors, as_string(e));
            }
        } else if (type(comp) == "object") {
            if (comp.executed)
                continue;
            let ok = true;
            let err = null;
            try {
                if (comp.type == "callback" && type(comp.fn) == "function") {
                    comp.fn(job, reason);
                } else if (comp.type == "command" && comp.cmd != null) {
                    let res = exec.run({ command: comp.cmd, timeout: int(comp.timeout || 10) });
                    if (res.exit_code != 0) {
                        ok = false;
                        err = sprintf("Command exited with code %d", res.exit_code);
                    }
                } else if (comp.type == "remove_file" && comp.path != null) {
                    try { fs.unlink(comp.path); } catch (e) {}
                } else if (comp.type == "restore_file" && comp.path != null && comp.content != null) {
                    let f = fs.open(comp.path, "w");
                    if (f != null) {
                        f.write(comp.content);
                        f.close();
                        if (comp.mode != null) {
                            try { fs.chmod(comp.path, int(comp.mode)); } catch (e) {}
                        }
                    } else {
                        ok = false;
                        err = "Failed to open file for restoration: " + comp.path;
                    }
                } else if (type(comp.fn) == "function") {
                    comp.fn(job, reason);
                }
            } catch (e) {
                ok = false;
                err = as_string(e);
            }
            comp.executed = true;
            if (!ok && err != null) {
                push(errors, err);
            } else {
                count++;
            }
        }
    }

    // Linked transaction rollback if specified
    if (job.tx_id != null && job.tx_id != "") {
        try {
            let tx_mod = require("core.transaction");
            let tx = tx_mod.query(job.tx_id);
            if (tx != null) {
                tx_mod.rollback(tx, reason || "job cancelled");
            }
        } catch (e) {
            push(errors, "Linked transaction rollback failed: " + as_string(e));
        }
    }

    job.rolled_back = true;
    if (length(errors) > 0) {
        job.rollback_error = join("; ", errors);
    }
    write_job_state(job);

    return { ok: length(errors) == 0, compensations_run: count, errors: errors };
}

// ---------------------------------------------------------------------------
// Cancellation & Critical Section Protection
// ---------------------------------------------------------------------------

function cancel_force(job_or_id, reason) {
    let job = null;
    if (type(job_or_id) == "string") {
        job = read_job_state(job_or_id);
        if (job == null)
            return { ok: false, error: sprintf("Job %s not found", job_or_id) };
    } else if (type(job_or_id) == "object") {
        job = job_or_id;
    } else {
        return { ok: false, error: "Invalid job identifier" };
    }

    if (job.pid != null && job.pid != "0") {
        exec.kill_identity({
            pid: job.pid,
            starttime: job.starttime,
            boot_id: job.boot_id
        }, 3);
    }

    job.cancel_forced = true;
    job.cancel_requested = true;
    job.cancel_reason = as_string(reason || "Force cancelled");
    job.cancelled_at = now_seconds();
    job.safe_point_reached = true;
    job.in_critical_section = false;

    let extra = {
        cancel_forced: true,
        cancel_reason: job.cancel_reason,
        cancelled_at: job.cancelled_at,
        result: { cancelled: true, forced: true, reason: job.cancel_reason }
    };

    transition(job, PHASE_CANCELLED, extra);
    return { ok: true, cancelled: true, forced: true, job: job };
}

function handle_cancellation(job, opts) {
    let options = (type(opts) == "object") ? opts : {};

    // 1. If rollback stack has entries (or tx_id is set) and not yet rolled back:
    if (!job.rolled_back && ((type(job.rollback_stack) == "array" && length(job.rollback_stack) > 0) || (job.tx_id != null && job.tx_id != ""))) {
        execute_rollback(job, job.cancel_reason || "Cancellation requested");
    }

    // 2. Transition to cancelled
    job.cancelled_at = now_seconds();
    job.safe_point_reached = true;
    job.in_critical_section = false;
    let extra = {
        cancelled_at: job.cancelled_at,
        rolled_back: job.rolled_back,
        result: {
            cancelled: true,
            reason: job.cancel_reason,
            rolled_back: job.rolled_back
        }
    };

    transition(job, PHASE_CANCELLED, extra);

    try {
        events.publish("job.cancelled", {
            job_id: job.id,
            reason: job.cancel_reason,
            rolled_back: job.rolled_back
        });
    } catch (e) {}

    return { safe_point: true, cancelled: true, rolled_back: job.rolled_back, job: job };
}

function is_cancel_requested(job_or_id) {
    let job = null;
    if (type(job_or_id) == "string") {
        job = read_job_state(job_or_id);
    } else if (type(job_or_id) == "object") {
        if (job_or_id.id != null) {
            let disk_state = read_job_state(job_or_id.id);
            if (disk_state != null && disk_state.cancel_requested) {
                job_or_id.cancel_requested = true;
                job_or_id.cancel_reason = disk_state.cancel_reason;
                job_or_id.cancel_requested_at = disk_state.cancel_requested_at;
            }
        }
        job = job_or_id;
    }
    return (job != null && job.cancel_requested == true);
}

function check_cancellation(job, opts) {
    if (!is_cancel_requested(job))
        return { cancelled: false, deferred: false };

    // If currently inside a critical section, do not cancel yet; defer until safe point
    if (job.in_critical_section) {
        return {
            cancelled: false,
            deferred: true,
            critical_section: job.critical_section_name
        };
    }

    // Safe point reached! Perform cancellation lifecycle:
    // finish safe point -> rollback -> cancel
    return handle_cancellation(job, opts);
}

function enter_critical_section(job, name) {
    is_cancel_requested(job);
    job.in_critical_section = true;
    job.critical_section_name = as_string(name || "unnamed");
    job.critical_section_entered_at = now_seconds();
    job.safe_point_reached = false;
    job.updated_at = now_seconds();
    write_job_state(job);
    return job;
}

function leave_critical_section(job, opts) {
    // Check and sync cancellation state from disk before writing
    let cancel_pending = is_cancel_requested(job);

    job.in_critical_section = false;
    job.critical_section_name = null;
    job.safe_point_reached = true;
    job.updated_at = now_seconds();
    write_job_state(job);

    // Safe point reached: handle cancellation if requested
    if (cancel_pending) {
        return handle_cancellation(job, opts);
    }

    return { safe_point: true, cancelled: false, job: job };
}

function with_critical_section(job, name, fn) {
    enter_critical_section(job, name);
    let result = null;
    let ok = true;
    let err = null;
    try {
        result = fn();
    } catch (e) {
        ok = false;
        err = e;
    }
    let exit_res = leave_critical_section(job);
    if (!ok)
        die(err);
    return {
        result: result,
        cancelled: (exit_res != null && exit_res.cancelled == true),
        job: job
    };
}

function request_cancel(job_or_id, reason, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let job = null;

    if (type(job_or_id) == "string") {
        job = read_job_state(job_or_id);
        if (job == null)
            return { ok: false, error: sprintf("Job %s not found", job_or_id) };
    } else if (type(job_or_id) == "object") {
        job = job_or_id;
    } else {
        return { ok: false, error: "Invalid job identifier" };
    }

    // Check if job is already in a terminal state
    if (job.phase == PHASE_SUCCESS || job.phase == PHASE_FAILED || job.phase == PHASE_CANCELLED) {
        return {
            ok: false,
            error: sprintf("Job %s already finished in phase '%s'", job.id, job.phase),
            job: job
        };
    }

    job.cancel_requested = true;
    job.cancel_reason = as_string(reason || "Cancellation requested");
    job.cancel_requested_at = now_seconds();
    job.updated_at = now_seconds();

    write_job_state(job);

    try {
        events.publish("job.cancel_requested", {
            job_id: job.id,
            reason: job.cancel_reason
        });
    } catch (e) {}

    if (options.force == true) {
        return cancel_force(job, job.cancel_reason);
    }

    return { ok: true, job: job };
}

function cancel(job_or_id, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let force = (options.force == true);
    let reason = as_string(options.reason || (type(opts) == "string" ? opts : "Cancelled"));

    if (force) {
        return cancel_force(job_or_id, reason);
    }

    let req = request_cancel(job_or_id, reason, options);
    if (!req.ok)
        return req;

    let job = req.job;
    let timeout = int(options.timeout || (options.wait ? 10 : 0));
    if (timeout > 0) {
        let deadline = now_seconds() + timeout;
        while (now_seconds() < deadline) {
            let st = read_job_state(job.id);
            if (st != null && (st.phase == PHASE_CANCELLED || st.phase == PHASE_SUCCESS || st.phase == PHASE_FAILED)) {
                return { ok: true, cancelled: st.phase == PHASE_CANCELLED, job: st };
            }
            exec.sleep_ms(200);
        }

        if (options.force_on_timeout == true) {
            return cancel_force(job, "Timeout waiting for cooperative cancellation (" + timeout + "s)");
        }
    }

    return req;
}

// ---------------------------------------------------------------------------
// Step Runner (cooperative multi-step execution)
// ---------------------------------------------------------------------------

function run_steps(job, steps, opts) {
    if (type(steps) != "array" || length(steps) == 0)
        return { ok: true, job: job };

    let total = length(steps);
    for (let idx = 0; idx < total; idx++) {
        let step = steps[idx];
        if (type(step) != "object")
            continue;

        // Check cancellation before step execution
        let cancel_chk = check_cancellation(job);
        if (cancel_chk.cancelled) {
            return { ok: false, cancelled: true, step: step.name, job: job };
        }

        job.progress = int((idx / total) * 100);
        job.message = as_string(step.message || sprintf("Running step: %s", step.name || as_string(idx + 1)));
        heartbeat(job);

        // Register rollback handler for this step if provided
        if (step.rollback != null) {
            register_rollback(job, step.rollback);
        }

        // Run step (with critical section if flagged)
        let step_res = null;
        let step_ok = true;
        let step_err = null;

        if (step.critical) {
            try {
                let cs = with_critical_section(job, step.name || "step_" + idx, step.run);
                step_res = cs.result;
                if (cs.cancelled) {
                    return { ok: false, cancelled: true, step: step.name, job: job };
                }
            } catch (e) {
                step_ok = false;
                step_err = e;
            }
        } else {
            try {
                if (type(step.run) == "function") {
                    step_res = step.run(job);
                }
            } catch (e) {
                step_ok = false;
                step_err = e;
            }
        }

        if (!step_ok) {
            fail(job, sprintf("Step '%s' failed: %s", step.name || as_string(idx), as_string(step_err)));
            execute_rollback(job, job.error);
            return { ok: false, error: job.error, step: step.name, job: job };
        }

        // Check cancellation after step execution
        cancel_chk = check_cancellation(job);
        if (cancel_chk.cancelled) {
            return { ok: false, cancelled: true, step: step.name, job: job };
        }
    }

    job.progress = 100;
    job.message = "All steps completed successfully";
    complete(job);
    return { ok: true, cancelled: false, job: job };
}

// ---------------------------------------------------------------------------
// Stale detection
// ---------------------------------------------------------------------------

// Check if a job is stale: either its worker process is dead, or it has not
// received a heartbeat within 3x the heartbeat interval, or it has exceeded
// its hard deadline.
function is_stale(job) {
    if (job.phase != PHASE_RUNNING && job.phase != PHASE_PREFLIGHT)
        return false;

    // Hard deadline check
    if (job.deadline_at != null && now_seconds() > job.deadline_at)
        return true;

    // PID-based check using process identity (prevents PID recycling)
    if (job.pid != null && job.pid != "0" && job.starttime != null) {
        let identity = {
            pid: job.pid,
            starttime: job.starttime,
            boot_id: job.boot_id
        };
        if (!exec.identity_alive(identity))
            return true;
    } else if (job.pid != null && job.pid != "0") {
        // Fallback: just check if PID is alive (no starttime protection)
        if (!exec.is_alive(job.pid))
            return true;
    }

    // Heartbeat timeout: 3x the interval
    if (job.heartbeat_at != null && job.hard_deadline != null) {
        let hb_timeout = int(job.hard_deadline / 3);
        if (hb_timeout < 30) hb_timeout = 30;
        if (now_seconds() - job.heartbeat_at > hb_timeout)
            return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// Query API (for UI and watchdog)
// ---------------------------------------------------------------------------

// Get current state of a job.
function query(job_id) {
    return read_job_state(job_id);
}

// List all active jobs (not in terminal state).
function list_active() {
    ensure_dirs();
    let jobs = [];
    let entries = fs.glob(JOBS_DIR + "/*.json");
    if (type(entries) != "array")
        return jobs;

    for (let full_path in entries) {
        let basename = full_path;
        let slash = rindex(full_path, "/");
        if (slash >= 0) basename = substr(full_path, slash + 1);
        let job_id = substr(basename, 0, length(basename) - 5);
        let state = read_job_state(job_id);
        if (state == null)
            continue;
        if (state.phase != PHASE_SUCCESS && state.phase != PHASE_FAILED &&
            state.phase != PHASE_CANCELLED) {
            push(jobs, state);
        }
    }
    return jobs;
}

// List all jobs (including completed).
function list_all() {
    ensure_dirs();
    let jobs = [];
    let entries = fs.glob(JOBS_DIR + "/*.json");
    if (type(entries) != "array")
        return jobs;

    for (let full_path in entries) {
        let basename = full_path;
        let slash = rindex(full_path, "/");
        if (slash >= 0) basename = substr(full_path, slash + 1);
        let job_id = substr(basename, 0, length(basename) - 5);
        let state = read_job_state(job_id);
        if (state != null)
            push(jobs, state);
    }

    // Sort by creation time, newest first
    sort(jobs, function(a, b) {
        return (b.created_at || 0) - (a.created_at || 0);
    });

    return jobs;
}

// ---------------------------------------------------------------------------
// Garbage collection
// ---------------------------------------------------------------------------

// Remove jobs that are in terminal state and older than GC_MAX_AGE_SECONDS.
// Announced separately so the destructive branches have one place to report
// through, and routed through core.logging rather than shelling out.
// Declared above its callers because ucode binds the name when the statement
// runs, not when the function is called.
function jobs_gc_log(message) {
    if (logging && type(logging.write) == "function") {
        logging.write({ level: "warn", subsystem: "core.jobs", operation: "gc", message: message });
    }
}

// A worker that dies - OOM, a manual kill, a crash - never reaches fail() or
// complete(), so nothing else moves the job out of running. Left alone it shows
// as running forever and its compensations never run, which is the whole thing
// the rollback stack exists to prevent. Reaped on sight, like a stale
// transaction, rather than left to be deleted.
function reap_stale_job(state) {
    let reason = "worker disappeared before reporting a result";
    // Only compensations that were written to the state file can run now: a
    // callback was held in the dead worker's memory, and sanitize_state_for_json
    // persisted it as a placeholder with nothing executable in it. Marking the
    // job rolled back without saying so would be the worst outcome - it looks
    // handled, and the system is left half-applied.
    let stack = state.rollback_stack || [];
    let unrunnable = 0;
    for (let comp in stack)
        if (type(comp) != "function" && (type(comp) != "object" || comp.fn == null))
            if (!(type(comp) == "object" &&
                 (comp.type == "command" || comp.type == "remove_file" || comp.type == "restore_file")))
                unrunnable++;
    if (unrunnable > 0)
        reason += sprintf("; %d in-process compensation(s) could not be run because they died with the worker - check whether the system is left half-applied", unrunnable);
    jobs_gc_log("reaping stale job " + state.id + ": " + reason);
    if (length(stack) > 0)
        execute_rollback(state, reason);
    fail(state, reason);
}

function gc() {
    ensure_dirs();
    let entries = fs.glob(JOBS_DIR + "/*.json");
    if (type(entries) != "array")
        return 0;

    let now = now_seconds();
    let removed = 0;

    for (let full_path in entries) {
        let basename = full_path;
        let slash = rindex(full_path, "/");
        if (slash >= 0) basename = substr(full_path, slash + 1);
        let job_id = substr(basename, 0, length(basename) - 5);
        let state = read_job_state(job_id);
        if (state == null) {
            // A state file that will not parse is the ordinary result of a
            // full disk or a power cut mid-write. It is already invisible to
            // list_all(), so nothing else will ever reclaim it - skipping it
            // here would leave it on disk across reboots forever. Say so before
            // removing it, since the job it described can no longer be
            // cancelled or rolled back once it is gone.
            jobs_gc_log("removing unreadable job state " + job_id);
            try { fs.unlink(job_state_path(job_id)); } catch (e) {}
            try { fs.unlink(job_log_path(job_id)); } catch (e) {}
            removed++;
            continue;
        }

        let is_terminal = (state.phase == PHASE_SUCCESS ||
                          state.phase == PHASE_FAILED ||
                          state.phase == PHASE_CANCELLED);

        if (!is_terminal && is_stale(state)) {
            reap_stale_job(state);
            continue;
        }

        let age = now - (state.updated_at || state.created_at || 0);

        if (is_terminal && age > GC_MAX_AGE_SECONDS) {
            try { fs.unlink(job_state_path(job_id)); } catch (e) {}
            try { fs.unlink(job_log_path(job_id)); } catch (e) {}
            removed++;
        }
    }
    return removed;
}

// ---------------------------------------------------------------------------
// Convenience: run a job as a background process
// ---------------------------------------------------------------------------

function run_job(kind, target, action, command, opts) {
    let options = (type(opts) == "object") ? opts : {};

    let job = create(kind, target, action, opts);
    job = queue(job);
    job = preflight(job);

    // Set up process environment
    let state_file = job_state_path(job.id);
    let env = {
        TACHYON_JOB_ID: job.id,
        TACHYON_JOB_STATE_FILE: state_file,
        TACHYON_JOB_LOG: job_log_path(job.id),
        TACHYON_JOB_HEARTBEAT_INTERVAL: as_string(job.heartbeat_interval),
        TACHYON_JOB_HARD_DEADLINE_SECONDS: as_string(job.hard_deadline)
    };

    // Merge with caller-provided env
    let caller_env = options.env;
    if (type(caller_env) == "object") {
        for (let key in keys(caller_env))
            env[key] = caller_env[key];
    }

    let bg = exec.run_background({
        command: command,
        stdout: as_string(options.stdout || "/dev/null"),
        env: env,
        name: sprintf("%s/%s/%s", kind, target, action)
    });

    job.pid = bg.pid;
    job.starttime = bg.identity ? bg.identity.starttime : null;
    job.boot_id = bg.identity ? bg.identity.boot_id : exec.boot_id();
    job = transition(job, PHASE_RUNNING);

    return job;
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Lifecycle phases
        PHASE_CREATED,
        PHASE_QUEUED,
        PHASE_PREFLIGHT,
        PHASE_RUNNING,
        PHASE_VERIFYING,
        PHASE_COMMITTING,
        PHASE_SUCCESS,
        PHASE_FAILED,
        PHASE_ROLLBACK,
        PHASE_CANCELLED,

        // Job management
        create,
        queue,
        preflight,
        transition,
        start_shell,
        heartbeat,
        complete,
        fail,

        // Cancellation & Critical section
        cancel,
        cancel_force,
        request_cancel,
        is_cancel_requested,
        check_cancellation,
        enter_critical_section,
        leave_critical_section,
        with_critical_section,
        register_rollback,
        execute_rollback,
        handle_cancellation,
        run_steps,

        // Query
        query,
        list_active,
        list_all,

        // Stale detection
        is_stale,

        // Garbage collection
        gc,

        // Convenience
        run_job,
        generate_id,

        // Paths (for UI/introspection)
        job_state_path,
        job_log_path
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "selftest") {
    let pass = 0;
    let fail_count = 0;

    function assert(cond, msg) {
        if (cond) { pass++; }
        else { fail_count++; print("FAIL: " + msg + "\n"); }
    }

    // Test 1: create a job
    let job = create("test", "unit", "echo");
    assert(job.id != null, "job should have an id");
    assert(job.phase == PHASE_CREATED, "new job should be in created phase");
    assert(job.kind == "test", "kind should match");
    assert(job.target == "unit", "target should match");
    assert(job.action == "echo", "action should match");
    assert(job.cancel_requested == false, "cancel_requested should default to false");
    assert(job.in_critical_section == false, "in_critical_section should default to false");
    assert(job.safe_point_reached == true, "safe_point_reached should default to true");

    // Test 2: valid transitions
    let q = queue(job);
    assert(q.phase == PHASE_QUEUED, "queue should transition to queued");

    let pf = preflight(q);
    assert(pf.phase == PHASE_PREFLIGHT, "preflight should transition to preflight");

    // Test 3: invalid transition
    let bad = transition(pf, PHASE_SUCCESS);
    assert(bad.error != null, "direct preflight→success should fail");
    assert(pf.phase == PHASE_PREFLIGHT, "phase should remain preflight on error");

    // Test 4: full lifecycle
    let job2 = create("test", "unit", "lifecycle");
    job2 = queue(job2);
    job2 = preflight(job2);
    job2 = transition(job2, PHASE_RUNNING, { pid: "99999" });
    assert(job2.phase == PHASE_RUNNING, "should be running");
    job2 = transition(job2, PHASE_VERIFYING);
    assert(job2.phase == PHASE_VERIFYING, "should be verifying");
    job2 = transition(job2, PHASE_COMMITTING);
    assert(job2.phase == PHASE_COMMITTING, "should be committing");
    job2 = complete(job2, { exit_code: 0 });
    assert(job2.phase == PHASE_SUCCESS, "should be success");

    // Test 5: stale detection
    let stale_job = create("test", "unit", "stale");
    assert(!is_stale(stale_job), "created job should not be stale");

    // Test 6: list_all
    let all = list_all();
    assert(type(all) == "array", "list_all should return array");

    // Test 7: generate_id
    let id1 = generate_id("cmp", "sing_box", "update");
    let id2 = generate_id("cmp", "sing_box", "update");
    assert(id1 != id2, "IDs should be unique");
    assert(match(id1, /^cmp-sing_box-update-/), "ID should have expected prefix");

    // Test 8: request_cancel sets flags
    let cjob = create("test", "cancel", "cooperative");
    cjob = queue(cjob);
    cjob = preflight(cjob);
    cjob = transition(cjob, PHASE_RUNNING);
    let req_res = request_cancel(cjob.id, "User requested cancel");
    assert(req_res.ok == true, "request_cancel should succeed");
    let q_cjob = query(cjob.id);
    assert(q_cjob.cancel_requested == true, "persisted state should have cancel_requested=true");
    assert(q_cjob.cancel_reason == "User requested cancel", "persisted reason should match");
    assert(is_cancel_requested(cjob) == true, "is_cancel_requested should return true");

    // Test 9: check_cancellation at safe point handles cancel and transitions to cancelled
    let chk = check_cancellation(cjob);
    assert(chk.cancelled == true, "check_cancellation should report cancelled");
    assert(cjob.phase == PHASE_CANCELLED, "job phase should now be cancelled");

    // Test 10: critical section protection defers cancellation until safe point
    let cs_job = create("test", "cs", "protect");
    cs_job = queue(cs_job);
    cs_job = transition(cs_job, PHASE_RUNNING);
    enter_critical_section(cs_job, "flashing_firmware");
    assert(cs_job.in_critical_section == true, "job should be in critical section");
    assert(cs_job.safe_point_reached == false, "safe_point_reached should be false");

    // Request cancel while in critical section
    request_cancel(cs_job.id, "Abort now");
    let def_chk = check_cancellation(cs_job);
    assert(def_chk.cancelled == false, "cancellation should be deferred inside critical section");
    assert(def_chk.deferred == true, "deferred flag should be true");
    assert(cs_job.phase == PHASE_RUNNING, "phase must remain running inside critical section");

    // Leave critical section -> safe point reached -> automatic cancellation!
    let leave_res = leave_critical_section(cs_job);
    assert(leave_res.safe_point == true, "safe_point should be reached");
    assert(leave_res.cancelled == true, "cancellation should trigger on leaving critical section");
    assert(cs_job.phase == PHASE_CANCELLED, "job phase should be cancelled after safe point");

    // Test 11: LIFO rollback on cancellation
    let rb_job = create("test", "rb", "lifo");
    rb_job = queue(rb_job);
    rb_job = transition(rb_job, PHASE_RUNNING);
    let order = [];
    register_rollback(rb_job, function() { push(order, 1); });
    register_rollback(rb_job, function() { push(order, 2); });
    register_rollback(rb_job, function() { push(order, 3); });
    request_cancel(rb_job.id, "Rollback test");
    check_cancellation(rb_job);
    assert(rb_job.phase == PHASE_CANCELLED, "rb_job should be cancelled");
    assert(rb_job.rolled_back == true, "rb_job should be marked rolled_back");
    assert(length(order) == 3, "all 3 compensations should run");
    assert(order[0] == 3 && order[1] == 2 && order[2] == 1, "compensations must run in LIFO order (3, 2, 1)");

    // Test 12: run_steps runner with cancellation check
    let step_job = create("test", "steps", "runner");
    step_job = queue(step_job);
    step_job = transition(step_job, PHASE_RUNNING);
    let step_executed = [];
    let steps = [
        {
            name: "step1",
            run: function(j) { push(step_executed, "step1"); }
        },
        {
            name: "step2",
            run: function(j) {
                push(step_executed, "step2");
                request_cancel(j.id, "Cancel during step2");
            }
        },
        {
            name: "step3",
            run: function(j) { push(step_executed, "step3"); }
        }
    ];
    let step_result = run_steps(step_job, steps);
    assert(step_result.cancelled == true, "step runner should report cancelled");
    assert(step_job.phase == PHASE_CANCELLED, "step_job phase should be cancelled");
    assert(length(step_executed) == 2, "step3 should NOT have executed");

    // Test 13: cancel_force immediate kill
    let fjob = create("test", "force", "kill");
    fjob = queue(fjob);
    fjob = transition(fjob, PHASE_RUNNING);
    let f_res = cancel_force(fjob.id, "Emergency stop");
    assert(f_res.ok == true, "cancel_force should succeed");
    assert(f_res.forced == true, "cancel_force forced flag should be true");
    let q_fjob = query(fjob.id);
    assert(q_fjob.phase == PHASE_CANCELLED, "phase should be cancelled immediately");
    assert(q_fjob.cancel_forced == true, "cancel_forced should be true");

    print("jobs.uc selftest: " + pass + " passed, " + fail_count + " failed\n");
    exit(fail_count > 0 ? 1 : 0);
}
else if (mode == "list") {
    let show_all = false;
    let as_json = false;
    for (let i = 1; i < length(ARGV); i++) {
        if (ARGV[i] == "--all") show_all = true;
        if (ARGV[i] == "--json") as_json = true;
    }
    let jobs = show_all ? list_all() : list_active();
    if (as_json) {
        print(sprintf("%J\n", jobs));
    } else {
        if (length(jobs) == 0) {
            print("No " + (show_all ? "" : "active ") + "jobs found\n");
        } else {
            print(sprintf("%-36s %-12s %-12s %-6s %s\n", "JOB ID", "PHASE", "KIND", "PROG", "MESSAGE / STATUS"));
            print(sprintf("%-36s %-12s %-12s %-6s %s\n", "------", "-----", "----", "----", "----------------"));
            for (let j in jobs) {
                let prog = (j.progress != null) ? sprintf("%d%%", j.progress) : "-";
                let msg = j.message || "";
                if (j.cancel_requested) msg = "[CANCEL_REQ] " + (j.cancel_reason || msg);
                print(sprintf("%-36s %-12s %-12s %-6s %s\n", j.id, j.phase, j.kind, prog, msg));
            }
        }
    }
}
else if (mode == "query" || mode == "status") {
    let job_id = ARGV[1];
    if (!job_id) {
        warn("Usage: core/jobs.uc query <job_id>\n");
        exit(1);
    }
    let j = query(job_id);
    if (!j) {
        warn(sprintf("Job '%s' not found\n", job_id));
        exit(1);
    }
    print(sprintf("%J\n", j));
}
else if (mode == "cancel") {
    let job_id = ARGV[1];
    if (!job_id) {
        warn("Usage: core/jobs.uc cancel <job_id> [--force] [reason]\n");
        exit(1);
    }
    let force = false;
    let reason = "CLI cancel";
    for (let i = 2; i < length(ARGV); i++) {
        if (ARGV[i] == "--force") force = true;
        else reason = ARGV[i];
    }
    let res = cancel(job_id, { force: force, reason: reason, wait: true, timeout: 5 });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "request-cancel") {
    let job_id = ARGV[1];
    let reason = ARGV[2] || "CLI cancellation requested";
    if (!job_id) {
        warn("Usage: core/jobs.uc request-cancel <job_id> [reason]\n");
        exit(1);
    }
    let res = request_cancel(job_id, reason);
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "gc") {
    let removed = gc();
    print("Removed " + removed + " stale jobs\n");
}
else {
    warn("Usage: core/jobs.uc <selftest|list|query|status|cancel|request-cancel|gc> ...\n");
    exit(1);
}
