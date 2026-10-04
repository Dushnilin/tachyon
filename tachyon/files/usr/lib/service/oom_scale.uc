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


// Shrink by 20% per OOM, and never past this: sing-box starved too far stops working
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

function module_exports() {
    return {
        OOM_SCALE_FLOOR,
        OOM_SCALE_STEP,
        oom_scale_path,
        read_oom_scale,
        oom_scale_at_floor,
        next_oom_scale
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: service/oom_scale.uc (library module, no CLI)\n");
exit(1);