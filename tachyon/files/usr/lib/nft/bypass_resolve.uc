#!/usr/bin/env ucode
//
// Pre-resolution of bypass-section domains into the section's priority set.
//
// nft populate runs before tachyon-core is up on every start and restart. At
// that moment dnsmasq still forwards to the stopped core - restart() never
// hands DNS back, and a fail-closed hold deliberately keeps it on the proxy -
// so every lookup sat out BusyBox nslookup's full 5 s timeout, twice per domain
// (127.0.0.1, then the resolv.conf server, which is 127.0.0.1 again on OpenWrt),
// for up to 64 domains. A restart after an OOM took six and a half minutes,
// almost five of them here, with the kill-switch blocking the LAN all along.
//
// Each lookup is now bounded, two lookups in a row that run out the clock end
// the pass (the resolver is not answering, so the rest would wait just as
// long), and the pass as a whole has a wall-clock budget. Nothing is lost: the
// list update start_impl() launches once the core is up runs populate again,
// and that pass resolves against a working resolver.
//

let exec = require("core.exec");
let core_ip = require("core.ip");

const LOOKUP_TIMEOUT_S = 2;
const PASS_BUDGET_S = 10;
const MAX_SLOW_IN_A_ROW = 2;

// IPv4 answers from BusyBox or bind nslookup output. Lines before the answer
// section name the server that was asked, so they are skipped; loopback and
// the FakeIP range are never real destinations.
function parse_nslookup_ipv4(output) {
    let found = [];
    let past_header = false;
    for (let line in split(output == null ? "" : "" + output, "\n")) {
        line = trim(line);
        if (index(line, "Name:") == 0 || index(line, "Non-authoritative") >= 0)
            past_header = true;
        if (!past_header) continue;
        let m4 = match(line, /([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/);
        if (!m4 || !core_ip.valid_ipv4(m4[1])) continue;
        let ip = m4[1];
        if (substr(ip, 0, 7) == "127.0.0" || substr(ip, 0, 7) == "198.18." || substr(ip, 0, 7) == "198.19.")
            continue;
        push(found, ip);
    }
    return found;
}

// One domain: the local resolver first, then the system one. The fallback is
// skipped when the first lookup ran out of time - on OpenWrt it asks the same
// 127.0.0.1 and would only wait again.
function nslookup_domain(domain) {
    let res = exec.run({ argv: [ "nslookup", domain, "127.0.0.1" ], timeout: LOOKUP_TIMEOUT_S });
    if (res.status == 0 && res.output != "")
        return { output: res.output, timed_out: false };
    if (res.timed_out)
        return { output: "", timed_out: true };
    res = exec.run({ argv: [ "nslookup", domain ], timeout: LOOKUP_TIMEOUT_S });
    return { output: res.status == 0 ? res.output : "", timed_out: res.timed_out == true };
}

// opts (test seams): lookup(domain) -> { output, timed_out }, now() -> seconds,
// budget_s, lookup_timeout_s, log(message).
// Returns { ips, attempted, stopped } where stopped is null when every domain
// was tried, otherwise "unresponsive" or "budget".
function resolve_bypass_domains(domains, opts) {
    opts = type(opts) == "object" ? opts : {};
    let lookup = type(opts.lookup) == "function" ? opts.lookup : nslookup_domain;
    let now = type(opts.now) == "function" ? opts.now : time;
    let budget = opts.budget_s != null ? int(opts.budget_s) : PASS_BUDGET_S;
    let slow_after = opts.lookup_timeout_s != null ? int(opts.lookup_timeout_s) : LOOKUP_TIMEOUT_S;
    let log = type(opts.log) == "function" ? opts.log : null;

    let ips = [];
    let seen = {};
    let attempted = 0;
    let slow_in_a_row = 0;
    let stopped = null;
    let total = type(domains) == "array" ? length(domains) : 0;
    let deadline = now() + budget;

    for (let i = 0; i < total; i++) {
        if (slow_in_a_row >= MAX_SLOW_IN_A_ROW) { stopped = "unresponsive"; break; }
        if (now() >= deadline) { stopped = "budget"; break; }

        let started = now();
        let res = lookup(domains[i]);
        attempted++;
        // A lookup without a timeout binary still blocks for its full
        // duration, so elapsed time counts as well as the timed_out flag.
        let slow = (type(res) == "object" && res.timed_out == true) || (now() - started >= slow_after);
        slow_in_a_row = slow ? slow_in_a_row + 1 : 0;

        for (let ip in parse_nslookup_ipv4(type(res) == "object" ? res.output : "")) {
            if (seen[ip]) continue;
            seen[ip] = true;
            push(ips, ip);
        }
    }

    if (stopped != null && log != null)
        log(sprintf("Bypass domain pre-resolution stopped after %d of %d domains (%s); the list update after start resolves them once DNS answers",
            attempted, total, stopped == "budget" ? "time budget spent" : "DNS is not answering"));

    return { ips: ips, attempted: attempted, stopped: stopped };
}

return {
    LOOKUP_TIMEOUT_S,
    PASS_BUDGET_S,
    MAX_SLOW_IN_A_ROW,
    parse_nslookup_ipv4,
    nslookup_domain,
    resolve_bypass_domains
};
