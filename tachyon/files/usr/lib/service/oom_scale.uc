#!/usr/bin/env ucode
//
// GOMEMLIMIT scale arithmetic for the OOM healer.
//
// Separate from service/watchdog.uc because that file is a script: requiring it runs
// its subscriptions and would start the watchdog. Keeping the arithmetic here also
// means the floor rule can be exercised directly - it is the rule that decides
// whether a restart is worth doing at all.
//

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;


// Shrink by 20% per OOM, and never past this: tachyon-core starved too far stops working
// at all, which is a worse outcome than the memory pressure that caused it.
const OOM_SCALE_FLOOR = 0.2;
const OOM_SCALE_STEP = 0.8;
const OOM_SCALE_PATH = getenv("TACHYON_OOM_SCALE_FILE") || "/etc/tachyon/mem_scale";

function oom_scale_path() {
    return OOM_SCALE_PATH;
}

function read_oom_scale() {
    let data = fs.readfile(oom_scale_path());
    if (data == null) return 1.0;
    let parsed = double(trim(as_string(data)));
    return parsed > 0.1 ? parsed : 1.0;
}

/**
 * True when shrinking once more would fall below the floor - that is, when the
 * restart which follows cannot change anything.
 *
 * This is what stops the loop: the healer used to restart every service on every OOM
 * event, including at the floor where the value written was the value already
 * stored, and restarting under memory pressure is what produced the next event.
 */
function oom_scale_at_floor(scale) {
    return double(scale) * OOM_SCALE_STEP < OOM_SCALE_FLOOR;
}

function next_oom_scale(scale) {
    let next = double(scale) * OOM_SCALE_STEP;
    return next < OOM_SCALE_FLOOR ? OOM_SCALE_FLOOR : next;
}

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
    if (report.memcg == true)
        return "report";
    return "report";
}

function module_exports() {
    return {
        OOM_SCALE_FLOOR,
        OOM_SCALE_STEP,
        CORE_NAMES,
        oom_scale_path,
        read_oom_scale,
        oom_scale_at_floor,
        next_oom_scale,
        oom_report,
        oom_response
    };
}

return module_exports();
