#!/usr/bin/env ucode
//
// diagnostics/hysteresis.uc - problem state tracker for health checks.
//
// One bad sample is not a problem: it is a timeout, a rate limit, a DPI hiccup
// or a probe that ran while a reload was tearing the proxy down. Publishing
// every raw observation as a fault makes the status swing with each sample and
// teaches whoever reads it to ignore the signal.
//
// Each check therefore feeds its observations to a tracker with four states
// and asymmetric confirmation:
//
//     clear --fail--> pending --fail xN--> active --ok xM--> recovering
//       ^                                                          |
//       +------------------------ ok xM ---------------------------+
//
//   clear        nothing to report
//   pending      a failure nobody believes yet; the next success drops it
//   active       confirmed: fail_threshold consecutive failures
//   recovering   left active on the first success, but only recover_threshold
//                consecutive successes make it forget
//
// A blip in either direction therefore costs nothing, while both entering and
// leaving active need a run of consistent observations. The thresholds are
// per check because the checks sample at different rates: a check that already
// counts consecutive misses before it publishes anything (WAN needs three)
// wants fail_threshold 1 here, since the confirmation already happened
// upstream and this tracker only has to hold the recovery.
//
// In-memory only: a watchdog restart legitimately starts every tracker over at
// clear, and nothing here writes to flash.

const STATE_CLEAR = "clear";
const STATE_PENDING = "pending";
const STATE_ACTIVE = "active";
const STATE_RECOVERING = "recovering";

function positive_int(value, fallback) {
    let number = int(value);
    if (type(number) != "int" || number < 1)
        return fallback;
    return number;
}

function create(fail_threshold, recover_threshold) {
    return {
        state: STATE_CLEAR,
        fail_threshold: positive_int(fail_threshold, 3),
        recover_threshold: positive_int(recover_threshold, 2),
        fail_streak: 0,
        ok_streak: 0,
        since: time()
    };
}

// Feeds one observation and returns the new state.
function observe(tracker, ok) {
    if (type(tracker) != "object")
        return STATE_CLEAR;

    if (ok) {
        tracker.fail_streak = 0;
        tracker.ok_streak++;

        if (tracker.state == STATE_PENDING) {
            // Never confirmed, so the blip is swallowed whole.
            tracker.state = STATE_CLEAR;
        } else if (tracker.state == STATE_ACTIVE) {
            tracker.state = STATE_RECOVERING;
        } else if (tracker.state == STATE_RECOVERING) {
            if (tracker.ok_streak < tracker.recover_threshold)
                return tracker.state;
            tracker.state = STATE_CLEAR;
        } else {
            return tracker.state;
        }
        tracker.since = time();
        return tracker.state;
    }

    tracker.ok_streak = 0;
    tracker.fail_streak++;

    if (tracker.state == STATE_ACTIVE)
        return tracker.state;

    if (tracker.state == STATE_RECOVERING) {
        // Still being watched when the fault comes back, so the recovery
        // streak it had built is spent and it drops straight back to active.
        tracker.state = STATE_ACTIVE;
    } else if (tracker.fail_streak >= tracker.fail_threshold) {
        tracker.state = STATE_ACTIVE;
    } else {
        tracker.state = STATE_PENDING;
    }
    tracker.since = time();
    return tracker.state;
}

function snapshot(tracker) {
    if (type(tracker) != "object")
        return { state: STATE_CLEAR, fail_streak: 0, ok_streak: 0, since: 0 };
    return {
        state: tracker.state != null ? tracker.state : STATE_CLEAR,
        fail_streak: int(tracker.fail_streak) || 0,
        ok_streak: int(tracker.ok_streak) || 0,
        since: int(tracker.since) || 0
    };
}

// How bad a state is, for picking the worst of several checks.
function rank(state) {
    if (state == STATE_ACTIVE) return 3;
    if (state == STATE_RECOVERING) return 2;
    if (state == STATE_PENDING) return 1;
    return 0;
}

function worst(states) {
    if (states == null)
        return STATE_CLEAR;
    let answer = STATE_CLEAR;
    for (let state in states) {
        if (type(state) == "string" && rank(state) > rank(answer))
            answer = state;
    }
    return answer;
}

// Turns a confirmed state into the watchdog status label.
//
// A pending blip deliberately does not move the label - that is the flap being
// removed - while an active check, or one that has not yet confirmed its
// recovery, must never be reported as healthy whatever the incident clock says.
function status_label(health_state, repaired_recently, emergency) {
    if (emergency == true)
        return "emergency_failsafe";
    if (health_state == STATE_ACTIVE || health_state == STATE_RECOVERING)
        return "degraded";
    if (repaired_recently == true)
        return "repaired";
    return "healthy";
}

return {
    STATE_CLEAR,
    STATE_PENDING,
    STATE_ACTIVE,
    STATE_RECOVERING,
    create,
    observe,
    snapshot,
    rank,
    worst,
    status_label
};
