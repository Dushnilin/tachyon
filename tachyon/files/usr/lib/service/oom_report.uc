#!/usr/bin/env ucode
//
// Kernel OOM report parsing and response classification for the watchdog.
//
// Separate from service/watchdog.uc because that file is a script: requiring it
// runs its subscriptions and would start the watchdog.
//

let common = require("core.common");

let as_string = common.as_string;

const CORE_NAMES = [ "tachyon-core" ];

/**
 * The newest kernel OOM report in `text` (dmesg output):
 *   { complete, victim, memcg }
 *
 * The kernel prints "<comm> invoked oom-killer" first and names the victim last
 * ("... Killed process <pid> (<comm>) ..."). The watchdog sees the first line
 * through syslog before the last one exists, so the report counts as complete
 * only once a kill line follows the newest "invoked oom-killer".
 *
 * memcg marks an OOM confined to a memory cgroup (a container or a service with
 * its own limit): that cgroup hit its own ceiling, the router did not run out.
 */
function oom_report(text) {
    let report = { complete: false, victim: null, memcg: false };
    let lines = split(as_string(text), "\n");
    let start = -1;
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (index(lines[i], "invoked oom-killer") >= 0) {
            start = i;
            break;
        }
    }
    if (start < 0)
        return report;

    for (let i = start + 1; i < length(lines); i++) {
        let line = lines[i];
        if (index(line, "constraint=CONSTRAINT_MEMCG") >= 0 || index(line, "Memory cgroup out of memory") >= 0)
            report.memcg = true;
        let m = match(line, /Killed process [0-9]+ \(([^)]*)\)/);
        if (m != null) {
            report.victim = m[1];
            report.complete = true;
            break;
        }
    }
    return report;
}

/**
 * What the healer does about one OOM event with native tachyon-core:
 *   "respawn" - the native core was killed. procd respawns it by itself;
 *               a full service restart drops interception needlessly.
 *   "report"  - a memory cgroup hit its own limit, or another process (or an
 *               unknown one) was killed. Report without restarting Tachyon.
 */
function oom_response(report) {
    report = type(report) == "object" ? report : {};
    if (index(CORE_NAMES, report.victim) >= 0)
        return "respawn";
    return "report";
}

function module_exports() {
    return {
        CORE_NAMES,
        oom_report,
        oom_response
    };
}

return module_exports();
