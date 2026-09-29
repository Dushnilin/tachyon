// DNS outages, resolver transitions and local curl failures are not evidence
// that one destination needs a proxy. Shared with regression tests.
let common = require("core.common");
let sb_constants = require("singbox.constants");

// Codebase convention: as_string lives in core/common, not in ucode itself.
let as_string = common.as_string;

const DNS_SETTLE_SECONDS = 30;

// A domain must keep failing across two probes before it is acted on, and the
// two must be far enough apart to be independent samples rather than the same
// failure observed twice inside one cycle.
const CONFIRM_WINDOW = 120;

function observe_dns(previous, observation, now) {
    previous = previous || {};
    observation = observation || {};
    let signature = observation.signature;
    let changed = signature != previous.signature || previous.changed_at == null ||
        now < previous.changed_at;
    let changed_at = changed || observation.busy ? now : previous.changed_at;
    return {
        signature,
        changed_at,
        ready: signature != null && !observation.busy && now - changed_at >= DNS_SETTLE_SECONDS
    };
}

function probe_kind(status) {
    status = int(status);
    if (status == 0) return "ok";
    if (status == 5 || status == 6) return "dns";
    // TCP-level failures: these are what a DPI reset actually looks like.
    if (index([7, 28, 35, 52, 55, 56], status) >= 0) return "transport";
    // A failed certificate check is indistinguishable from a MITM, and a MITM
    // is a block. Treating it as "local" silently dropped exactly the case
    // this feature exists to catch, so it counts as evidence instead - the
    // proxy half of the verdict is what keeps a genuinely broken certificate
    // from being written anywhere.
    if (index([58, 60, 77, 83, 90, 91], status) >= 0) return "transport";
    // Protocol and framing errors come from the origin or an intermediary that
    // is not necessarily a censor, so they stay inconclusive.
    return "local";
}

function probe_status(args) {
    // ucode system() returns the exit code, not a POSIX waitpid() status.
    // Passing argv directly also avoids an unnecessary command shell.
    let status = system(args);
    return status == null ? 255 : (status < 0 ? 128 - int(status) : int(status));
}

// ─── sing-box log shapes ──────────────────────────────────────────────────────
// Captured from a router running sing-box 1.14.2-lx.2. Two facts about that
// format drive everything below:
//
//   * the connection's open line carries the hostname unquoted
//     ("outbound connection to www.google.com:443"), while the failure line
//     carries only the resolved IP ("dial tcp 173.194.221.84:7"). The
//     hostname is therefore only recoverable by correlating the two lines;
//   * "direct" is the outbound TYPE, not a routing decision. A section backed
//     by a local DPI bypass logs outbound/direct[<section>-out], so reading
//     the word as "the bypass path failed" inverted its meaning and turned
//     every broken section into a blocked-destination report.

// Oldest first: the quoted form only exists on pre-1.14 builds, but it is kept
// so the fixtures that predate this format keep working.
const HOST_PATTERNS = [
    /"([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})(:[0-9]+)?"/,
    /outbound connection to ([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,}):[0-9]+/,
    /dial [a-z]+ ([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,}):[0-9]+/,
    /target[= ]([a-zA-Z0-9][a-zA-Z0-9.-]{1,60}\.[a-zA-Z]{2,})/
];

// A candidate must end in an alphabetic TLD, which is what keeps bare IPv4
// literals and IPv6 (colons are outside the character class) out.
function host_is_usable(host) {
    if (host == null || length(host) < 5) return false;
    if (index(host, "*") >= 0 || index(host, "?") >= 0) return false;
    if (index(host, "..") >= 0) return false;
    if (index(host, "-") == 0 || substr(host, length(host) - 1) == "-") return false;
    return true;
}

function extract_host(line) {
    if (line == null) return null;
    let text = as_string(line);
    for (let pattern in HOST_PATTERNS) {
        let m = match(text, pattern);
        if (!m || !m[1]) continue;
        if (host_is_usable(m[1])) return m[1];
    }
    return null;
}

// The bracketed trace id that ties every line of one connection together.
const TRACE_PATTERN = /\[([0-9]{6,}) /;

function parse_trace(line) {
    if (line == null) return null;
    let m = match(as_string(line), TRACE_PATTERN);
    return (m && m[1]) ? m[1] : null;
}

const OUTBOUND_PATTERN = /outbound\/[a-zA-Z0-9-]+\[([^\]\s]+)\]/;

function outbound_tag_of(line) {
    if (line == null) return null;
    let m = match(as_string(line), OUTBOUND_PATTERN);
    return (m && m[1]) ? m[1] : null;
}

// Consecutive direct-failure samples required before UCI is touched. A single
// TCP reset is normal on a loaded router; treating it as a block rewrote the
// user's routing for everyone behind the router.
const CONFIRM_FAILURES = 2;

function new_streak() {
    return { first_fail: null, last_seen: 0 };
}

function verdict(domain, observation, streak) {
    streak = streak || new_streak();
    observation = observation || {};
    let first_fail = streak.first_fail;
    let direct = observation.direct;
    let proxy = observation.proxy;

    // If the proxy path does not work either, the destination is down or
    // broken rather than blocked, and no amount of repeating will change that.
    if (proxy != "ok") return { act: false, seen: false, defer: true, first_fail: null };

    // A destination that answers directly is settled, and remembering it stops
    // it from being re-probed on every cycle.
    if (direct == "ok") return { act: false, seen: true, defer: false, first_fail: null };

    // A local error says nothing about the destination, so it is retried rather
    // than spent.
    if (direct == "local") return { act: false, seen: false, defer: true, first_fail: null };

    // Everything left - "transport" and "dns" alike - is a destination the proxy
    // reaches and the direct path does not. The dns case matters: a resolver
    // that answers NXDOMAIN for a domain the proxy resolves fine is censoring
    // the name, and skipping it outright lost that whole class of block.

    // First failure only opens the streak. Without a timestamp there is nothing
    // to measure the confirmation window against, so it stays unconfirmed.
    if (first_fail == null) {
        return {
            act: false,
            seen: false,
            defer: true,
            first_fail: observation.now != null ? observation.now : null
        };
    }
    if (observation.now != null && observation.now - first_fail < CONFIRM_WINDOW)
        return { act: false, seen: false, defer: true, first_fail: first_fail };

    return { act: true, seen: true, defer: false, first_fail: first_fail };
}

// Only the outbounds that carry unproxied traffic are evidence that a
// destination is blocked. Everything else belongs to a section and its
// failure says something about the section, not about the destination.
const BYPASS_OUTBOUND_TAGS = {
    [sb_constants.DIRECT_OUTBOUND_TAG]: true,
    [sb_constants.BYPASS_OUTBOUND_TAG]: true,
    [sb_constants.DIRECT_BYPASS_OUTBOUND_TAG]: true
};

function is_bypass_outbound_tag(tag) {
    return tag != null && BYPASS_OUTBOUND_TAGS[tag] === true;
}

// The pre-1.14 format names the outbound without a tag ("outbound/direct: ...").
// With no tag there is nothing to mistake for a section, and the untagged
// direct outbound is the unproxied path, so it counts as bypass.
const UNTAGGED_DIRECT_PATTERN = /outbound\/direct[^a-zA-Z0-9-]/;

function failure_outbound_is_bypass(line) {
    let tag = outbound_tag_of(line);
    if (tag != null) return is_bypass_outbound_tag(tag);
    return line != null && match(as_string(line), UNTAGGED_DIRECT_PATTERN) != null;
}

return {
    observe_dns,
    probe_kind,
    probe_status,
    extract_host,
    host_is_usable,
    parse_trace,
    outbound_tag_of,
    is_bypass_outbound_tag,
    failure_outbound_is_bypass,
    verdict,
    new_streak,
    CONFIRM_FAILURES,
    CONFIRM_WINDOW,
    DNS_SETTLE_SECONDS
};
