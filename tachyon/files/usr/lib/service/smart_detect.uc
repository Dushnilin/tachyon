// DNS outages, resolver transitions and local curl failures are not evidence
// that one destination needs a proxy. Shared with regression tests.
const DNS_SETTLE_SECONDS = 30;

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
    // Connection, body-transfer and TLS-handshake errors may be caused by DPI.
    // Certificate verification, local I/O and command/config errors may not.
    return index([7, 16, 18, 28, 35, 52, 55, 56, 92], status) >= 0 ? "transport" : "local";
}

function probe_status(args) {
    // ucode system() returns the exit code, not a POSIX waitpid() status.
    // Passing argv directly also avoids an unnecessary command shell.
    let status = system(args);
    return status == null ? 255 : (status < 0 ? 128 - int(status) : int(status));
}

return { observe_dns, probe_kind, probe_status, DNS_SETTLE_SECONDS };
