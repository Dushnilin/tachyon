#!/usr/bin/env ucode
//
// diagnostics/reachability_guard.uc - three-signal reachability classifier and
// asymmetric escalation tracker for priority-level switching.
//
// A single failed foreign probe does not tell us whether the active tunnel died,
// the ISP blocked direct foreign traffic, or the router lost its WAN uplink:
//
//   direct_domestic=false, direct_foreign=false, tunnel_foreign=false -> wan_down
//   direct_domestic=true,  tunnel_foreign=false                       -> tunnel_broken
//   direct_domestic=true,  direct_foreign=false, tunnel_foreign=true  -> foreign_blocked
//   direct_foreign=true,   tunnel_foreign=true                        -> normal
//
// Acting on a WAN outage as if the tunnel died churns priority levels while no
// packet can leave the router anyway. Returning to the primary level on the
// very first successful probe after an escalation causes the group to ping-pong
// whenever a DPI/TSPU filter drops packets intermittently.
//
// This guard therefore combines:
//   - fail_threshold consecutive anomalous samples (default 3) before escalating
//   - minimum dwell window in escalated state (default 120s)
//   - recover_threshold consecutive normal samples (default 8) before returning
//   - anti-flap penalty (+5 extra normal samples when >3 transitions occur
//     inside a 600s rolling window)
//
// In-memory only: nothing here touches UCI or flash.

const MODE_NORMAL = "normal";
const MODE_FOREIGN_BLOCKED = "foreign_blocked";
const MODE_TUNNEL_BROKEN = "tunnel_broken";
const MODE_WAN_DOWN = "wan_down";

const DEFAULT_FAIL_THRESHOLD = 3;
const DEFAULT_RECOVER_THRESHOLD = 8;
const DEFAULT_DWELL_SECONDS = 120;
const DEFAULT_FLAP_WINDOW = 600;
const DEFAULT_FLAP_LIMIT = 3;
const DEFAULT_FLAP_PENALTY = 5;

function positive_or_default(value, fallback) {
    let n = int(value);
    if (type(n) != "int" || n < 1)
        return fallback;
    return n;
}

function non_negative_or_default(value, fallback) {
    if (value == null)
        return fallback;
    let n = int(value);
    if (type(n) != "int" || n < 0)
        return fallback;
    return n;
}

function classify(sample) {
    if (type(sample) != "object")
        return MODE_NORMAL;

    let direct_domestic = sample.direct_domestic !== false;
    let direct_foreign = sample.direct_foreign !== false;
    let tunnel_foreign = sample.tunnel_foreign !== false;

    if (!direct_domestic && !direct_foreign && !tunnel_foreign)
        return MODE_WAN_DOWN;
    if (!tunnel_foreign)
        return MODE_TUNNEL_BROKEN;
    if (!direct_foreign)
        return MODE_FOREIGN_BLOCKED;
    return MODE_NORMAL;
}

function prune_transitions(transitions, now, window_seconds) {
    let kept = [];
    if (type(transitions) != "array")
        return kept;
    let cutoff = now - window_seconds;
    for (let ts in transitions) {
        let t = int(ts);
        if (t >= cutoff)
            push(kept, t);
    }
    return kept;
}

function create(opts) {
    let o = type(opts) == "object" ? opts : {};
    return {
        mode: MODE_NORMAL,
        escalated: false,
        fail_streak: 0,
        ok_streak: 0,
        escalated_at: 0,
        last_transition_at: 0,
        transitions: [],
        fail_threshold: positive_or_default(o.fail_threshold, DEFAULT_FAIL_THRESHOLD),
        recover_threshold: positive_or_default(o.recover_threshold, DEFAULT_RECOVER_THRESHOLD),
        dwell_seconds: non_negative_or_default(o.dwell_seconds, DEFAULT_DWELL_SECONDS),
        flap_window: positive_or_default(o.flap_window, DEFAULT_FLAP_WINDOW),
        flap_limit: positive_or_default(o.flap_limit, DEFAULT_FLAP_LIMIT),
        flap_penalty: positive_or_default(o.flap_penalty, DEFAULT_FLAP_PENALTY)
    };
}

function effective_recover_threshold(guard, now) {
    if (type(guard) != "object")
        return DEFAULT_RECOVER_THRESHOLD;
    let ts = now != null ? int(now) : time();
    let recent = prune_transitions(guard.transitions, ts, guard.flap_window);
    let base = positive_or_default(guard.recover_threshold, DEFAULT_RECOVER_THRESHOLD);
    if (length(recent) > positive_or_default(guard.flap_limit, DEFAULT_FLAP_LIMIT))
        return base + positive_or_default(guard.flap_penalty, DEFAULT_FLAP_PENALTY);
    return base;
}

function snapshot(guard, now) {
    if (type(guard) != "object") {
        return {
            mode: MODE_NORMAL,
            escalated: false,
            fail_streak: 0,
            ok_streak: 0,
            escalated_at: 0,
            flap_count: 0,
            recover_target: DEFAULT_RECOVER_THRESHOLD
        };
    }
    let ts = now != null ? int(now) : time();
    let recent = prune_transitions(guard.transitions, ts, guard.flap_window);
    return {
        mode: guard.mode || MODE_NORMAL,
        escalated: guard.escalated === true,
        fail_streak: int(guard.fail_streak || 0),
        ok_streak: int(guard.ok_streak || 0),
        escalated_at: int(guard.escalated_at || 0),
        flap_count: length(recent),
        recover_target: effective_recover_threshold(guard, ts)
    };
}

function observe(guard, sample) {
    if (type(guard) != "object")
        return snapshot(null, null);

    sample = type(sample) == "object" ? sample : {};
    let now = sample.now != null ? int(sample.now) : time();
    guard.transitions = prune_transitions(guard.transitions, now, guard.flap_window);

    let mode = classify(sample);
    guard.mode = mode;

    // Total WAN loss is not a tunnel or censorship failure: hold current state
    // without incrementing fail_streak or triggering a level switch.
    if (mode == MODE_WAN_DOWN) {
        guard.ok_streak = 0;
        return snapshot(guard, now);
    }

    if (mode == MODE_FOREIGN_BLOCKED || mode == MODE_TUNNEL_BROKEN) {
        guard.ok_streak = 0;
        guard.fail_streak = int(guard.fail_streak || 0) + 1;
        if (!guard.escalated && guard.fail_streak >= guard.fail_threshold) {
            guard.escalated = true;
            guard.escalated_at = now;
            guard.last_transition_at = now;
            push(guard.transitions, now);
        }
        return snapshot(guard, now);
    }

    // MODE_NORMAL
    guard.fail_streak = 0;
    guard.ok_streak = int(guard.ok_streak || 0) + 1;

    if (guard.escalated) {
        let elapsed = now - int(guard.escalated_at || 0);
        let needed = effective_recover_threshold(guard, now);
        if (elapsed >= guard.dwell_seconds && guard.ok_streak >= needed) {
            guard.escalated = false;
            guard.ok_streak = 0;
            guard.last_transition_at = now;
            push(guard.transitions, now);
        }
    }

    return snapshot(guard, now);
}

return {
    MODE_NORMAL,
    MODE_FOREIGN_BLOCKED,
    MODE_TUNNEL_BROKEN,
    MODE_WAN_DOWN,
    DEFAULT_FAIL_THRESHOLD,
    DEFAULT_RECOVER_THRESHOLD,
    DEFAULT_DWELL_SECONDS,
    DEFAULT_FLAP_WINDOW,
    DEFAULT_FLAP_LIMIT,
    DEFAULT_FLAP_PENALTY,
    classify,
    create,
    effective_recover_threshold,
    observe,
    snapshot
};
