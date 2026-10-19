#!/usr/bin/env ucode
//
// Effective GOMEMLIMIT for Go-based core runs (sing-box and its variants), in MiB.
//
// The init-script generators compute this in shell for the long-lived daemon.
// Short-lived CLI runs - `check`, `rule-set match`, `tools fetch` - never see
// procd's environment, so when the active engine is Go-based (`sing-box`) they
// would otherwise start a second Go runtime with no memory ceiling while the
// daemon already holds its own. On 128/256 MB routers that spike is what the
// OOM killer lands on. (Native Rust `tachyon-core` ignores GOMEMLIMIT.)
//
// Lives in core/ rather than service/oom_scale.uc because tachyon_core/* must
// not reach into service/*, and two of the three callers sit in tachyon_core
// and diagnostics.
//

let fs = require("fs");
let uci_core = require("core.uci");

const OOM_SCALE_PATH = getenv("TACHYON_OOM_SCALE_FILE") || "/etc/tachyon/mem_scale";
const MEMINFO_PATH = getenv("TACHYON_MEMINFO_PATH") || "/proc/meminfo";

// Effective OOM scale as a percentage, 20..100. Absent or unparsable means 100.
// The floor of 20 matches the awk the generators embed.
function oom_scale_pct() {
    let data = fs.readfile(OOM_SCALE_PATH);
    if (data == null) return 100;
    let parsed = double(trim(data));
    if (parsed == null) return 100;
    let pct = int(parsed * 100);
    if (pct < 20) pct = 20;
    if (pct > 100) pct = 100;
    return pct;
}

function mem_total_kb() {
    let data = fs.readfile(MEMINFO_PATH);
    if (data == null) return 0;
    for (let line in split(data, "\n")) {
        let m = match(line, /^MemTotal:\s+(\d+)\s+kB/);
        if (m != null) return int(m[1]);
    }
    return 0;
}

function configured_memory_limit_mb() {
    let limit = int(uci_core.get("tachyon-core", "main", "memory_limit_mb") || "0");
    if (limit <= 0)
        limit = int(uci_core.get("tachyon", "settings", "memory_limit_mb") || "0");
    return limit > 0 ? limit : 0;
}

// Test seam: everything the calculation reads is injectable, so the arithmetic
// can be exercised without a router and without stubbing UCI.
// opts: { mem_total_kb, memory_limit_mb, scale_pct }
function gomemlimit_mb(opts) {
    opts = type(opts) == "object" ? opts : {};

    let scale_pct = (opts.scale_pct != null) ? int(opts.scale_pct) : oom_scale_pct();
    if (scale_pct < 20) scale_pct = 20;
    if (scale_pct > 100) scale_pct = 100;

    let limit_mb = (opts.memory_limit_mb != null)
        ? int(opts.memory_limit_mb)
        : configured_memory_limit_mb();

    let total_kb = (opts.mem_total_kb != null) ? int(opts.mem_total_kb) : mem_total_kb();

    let limit = 0;
    if (limit_mb > 0) {
        limit = limit_mb;
    } else if (total_kb > 0) {
        if (total_kb <= 524288 || scale_pct < 100) {
            limit = int(int(total_kb / 1024) * 50 / 100);
            if (limit < 24) limit = 24;
        }
    }

    if (limit > 0 && scale_pct < 100) {
        limit = int(limit * scale_pct / 100);
        if (limit < 16) limit = 16;
    }

    return limit > 0 ? limit : null;
}

// Ready-to-prepend shell assignments, for the callers that build a command
// string rather than an env map and would otherwise need core.exec for
// command_env(). Single-quoted so the value survives any shell reparse.
function gomemlimit_env(opts) {
    let mb = gomemlimit_mb(opts);
    return mb == null ? "" : "GOMEMLIMIT='" + mb + "MiB' ";
}

// Same, as an env-map fragment for callers that already have one.
function gomemlimit_env_map(opts) {
    let mb = gomemlimit_mb(opts);
    return mb == null ? {} : { GOMEMLIMIT: mb + "MiB" };
}

function module_exports() {
    return {
        gomemlimit_mb,
        gomemlimit_env,
        gomemlimit_env_map
    };
}

// Self-check against the cases tests/gomemlimit_scale.sh pins for the shell
// generators. Both implementations must agree, or a short-lived run and the
// daemon end up with different ceilings on the same router.
function gomemlimit_selftest() {
    function expect(name, got, want) {
        if (got != want) {
            printf("FAIL %s: got %J want %J\n", name, got, want);
            return false;
        }
        return true;
    }

    let ok = true;
    ok = expect("explicit cap", gomemlimit_mb({ memory_limit_mb: 128, scale_pct: 100 }), 128) && ok;
    ok = expect("explicit cap scaled", gomemlimit_mb({ memory_limit_mb: 128, scale_pct: 80 }), 102) && ok;
    ok = expect("512MB router", gomemlimit_mb({ mem_total_kb: 507904, scale_pct: 100 }), 248) && ok;
    ok = expect("512MB router scaled", gomemlimit_mb({ mem_total_kb: 507904, scale_pct: 64 }), 158) && ok;
    ok = expect("1GB router unconstrained", gomemlimit_mb({ mem_total_kb: 1010032, scale_pct: 100 }), null) && ok;
    ok = expect("1GB router scaled", gomemlimit_mb({ mem_total_kb: 1010032, scale_pct: 80 }), 394) && ok;
    ok = expect("tiny router floor", gomemlimit_mb({ mem_total_kb: 16384, scale_pct: 100 }), 24) && ok;
    ok = expect("tiny router floor scaled", gomemlimit_mb({ mem_total_kb: 16384, scale_pct: 20 }), 16) && ok;
    ok = expect("no data", gomemlimit_mb({ mem_total_kb: 0, memory_limit_mb: 0, scale_pct: 100 }), null) && ok;
    ok = expect("env prefix", gomemlimit_env({ mem_total_kb: 507904, scale_pct: 100 }), "GOMEMLIMIT='248MiB' ") && ok;
    ok = expect("env map", gomemlimit_env_map({ memory_limit_mb: 128, scale_pct: 100 }).GOMEMLIMIT, "128MiB") && ok;

    if (ok) printf("gomemlimit selftest ok\n");
    return ok;
}

if (ARGV[0] == "selftest")
    exit(gomemlimit_selftest() ? 0 : 1);

return module_exports();
