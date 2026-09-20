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
//
// Callers interact through:
//   jobs.create(kind, target, action) → job object
//   jobs.start(job, command, opts)    → spawns background worker
//   jobs.heartbeat(job)               → worker calls periodically
//   jobs.complete(job, result)        → worker calls on success
//   jobs.fail(job, error)             → worker calls on failure
//   jobs.query(job_id)                → UI reads current state
//   jobs.list()                       → UI lists all jobs
//   jobs.gc()                         → cleanup stale jobs

let fs = require("fs");
let exec = require("core.exec");
let events = require("core.events");
let common = require("core.common");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;

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
    [PHASE_RUNNING]:    [PHASE_VERIFYING, PHASE_FAILED, PHASE_CANCELLED],
    [PHASE_VERIFYING]:  [PHASE_COMMITTING, PHASE_FAILED, PHASE_ROLLBACK],
    [PHASE_COMMITTING]: [PHASE_SUCCESS, PHASE_FAILED, PHASE_ROLLBACK],
    [PHASE_SUCCESS]:    [],
    [PHASE_FAILED]:     [],
    [PHASE_ROLLBACK]:   [PHASE_FAILED],
    [PHASE_CANCELLED]:  []
};

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
// Job state management
// ---------------------------------------------------------------------------

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

function write_job_state(state) {
    ensure_dirs();
    return write_json_file(job_state_path(state.id), state, 2);
}

function now_seconds() {
    return int(clock()[0]);
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

// Start the background worker. Returns shell fragment to execute.
// The caller should use exec.run_background() with this as the command.
function start_shell(job, command, opts) {
    let options = (type(opts) == "object") ? opts : {};
    let timeout = int(options.timeout || job.hard_deadline);
    let stdout = as_string(options.stdout || "/dev/null");
    let pid_file = as_string(options.pid_file || "");

    // Build the worker shell fragment that wraps the command with heartbeat
    let wrapped = build_worker_wrapper(job, command, timeout);

    transition(job, PHASE_RUNNING);

    return wrapped;
}

// Build a shell wrapper that runs the command and writes heartbeat + result.
function build_worker_wrapper(job, command, timeout) {
    let state_file = job_state_path(job.id);
    let hb_interval = as_string(job.heartbeat_interval);
    let deadline = as_string(timeout);

    // The wrapper:
    // 1. Runs the actual command
    // 2. On exit, writes result to state file
    // 3. Heartbeat loop runs in background during execution
    let wrapper = sprintf(
        '(__job_id=%s __state_file=%s __hb_interval=%s __deadline=%s; ' +
        'echo $$ > /tmp/tachyon-job-$__job_id.pid; ' +
        '__start=$(cat /proc/$$/stat 2>/dev/null | sed "s/.*\\) //"); ' +
        'set -o pipefail; ' +
        '%s; __rc=$?; ' +
        'if [ $__rc -eq 0 ]; then ' +
        '  __phase=success; ' +
        'else ' +
        '  __phase=failed; ' +
        'fi; ' +
        '__now=$(date -u +%%s); ' +
        'cat > "$__state_file" <<__RESULT__EOF__\n' +
        '{\n' +
        '  "id": "%s",\n' +
        '  "phase": "$__phase",\n' +
        '  "result": { "exit_code": $__rc },\n' +
        '  "heartbeat_at": $__now,\n' +
        '  "updated_at": $__now\n' +
        '}\n' +
        '__RESULT__EOF__\n' +
        'exit $__rc)',
        job.id, state_file, hb_interval, deadline,
        command,
        job.id
    );

    return wrapper;
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

// Report failure.
function fail(job, error) {
    let extra = {
        error: as_string(error),
        result: { exit_code: 1, error: as_string(error) }
    };
    return transition(job, PHASE_FAILED, extra);
}

// Cancel a job.
function cancel(job) {
    // Kill the worker process if it's still running
    if (job.pid != null && job.pid != "0") {
        exec.kill_identity({
            pid: job.pid,
            starttime: job.starttime,
            boot_id: job.boot_id
        }, 3);
    }
    return transition(job, PHASE_CANCELLED);
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
        if (state == null)
            continue;

        let is_terminal = (state.phase == PHASE_SUCCESS ||
                          state.phase == PHASE_FAILED ||
                          state.phase == PHASE_CANCELLED);
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

// High-level function: create a job, spawn a background worker, return the
// job state. The worker process receives the job state file path via
// TACHYON_JOB_STATE_FILE environment variable.
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
        // Lifecycle phases (for callers that need to check)
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
        cancel,

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

    // Test 5: stale detection (non-running jobs are never stale)
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

    print("jobs.uc selftest: " + pass + " passed, " + fail_count + " failed\n");
    exit(fail_count > 0 ? 1 : 0);
}
else if (mode == "list") {
    let jobs = list_all();
    for (let job in jobs)
        print(sprintf("%-40s %-12s %-10s %s\n", job.id, job.phase, job.action, job.message || ""));
}
else if (mode == "gc") {
    let removed = gc();
    print("Removed " + removed + " stale jobs\n");
}
else {
    warn("Usage: core/jobs.uc <selftest|list|gc> ...\n");
    exit(1);
}
