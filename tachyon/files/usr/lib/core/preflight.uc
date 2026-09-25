#!/usr/bin/env ucode
//
// Preflight validation and resource budgeting layer.
//
// Performs deterministic system readiness checks before risky mutations,
// package upgrades, or transaction executions:
//   1. Free / Available RAM check (MemAvailable / MemFree + Buffers + Cached)
//   2. /tmp filesystem capacity and available space
//   3. Flash (/overlay or root) capacity and available space
//   4. Package manager database availability and lock state
//   5. Architecture compatibility check
//   6. 7-factor disk budget calculator and storage fit validator
//      (download + temp + old + new + rollback + metadata + reserve)
//   7. Preflight validator plug-in for core.transaction
//

let fs = require("fs");
let common = require("core.common");
let packages = require("core.packages");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_output = common.command_output;
let command_from_args = common.command_from_args;

// ---------------------------------------------------------------------------
// Constants & Defaults
// ---------------------------------------------------------------------------

const DEFAULT_MIN_RAM_KB = int(getenv("TACHYON_MIN_RAM_KB") || "16384");    // 16 MB
const DEFAULT_MIN_TMP_KB = int(getenv("TACHYON_MIN_TMP_KB") || "4096");     // 4 MB
const DEFAULT_MIN_FLASH_KB = int(getenv("TACHYON_MIN_FLASH_KB") || "2048"); // 2 MB
const DEFAULT_DISK_RESERVE_KB = int(getenv("TACHYON_DISK_RESERVE_KB") || "2048"); // 2 MB reserve

// ---------------------------------------------------------------------------
// Helper: Meminfo Parser
// ---------------------------------------------------------------------------

function parse_meminfo(meminfo_text) {
    let result = {
        total_kb: 0,
        free_kb: 0,
        available_kb: null,
        buffers_kb: 0,
        cached_kb: 0
    };

    if (meminfo_text == null || meminfo_text == "")
        return result;

    for (let line in split(meminfo_text, "\n")) {
        line = trim(line);
        if (line == "") continue;

        let m_tot = match(line, /^MemTotal:\s+(\d+)\s+kB/i);
        if (m_tot) { result.total_kb = int(m_tot[1]); continue; }

        let m_free = match(line, /^MemFree:\s+(\d+)\s+kB/i);
        if (m_free) { result.free_kb = int(m_free[1]); continue; }

        let m_avail = match(line, /^MemAvailable:\s+(\d+)\s+kB/i);
        if (m_avail) { result.available_kb = int(m_avail[1]); continue; }

        let m_buf = match(line, /^Buffers:\s+(\d+)\s+kB/i);
        if (m_buf) { result.buffers_kb = int(m_buf[1]); continue; }

        let m_cache = match(line, /^Cached:\s+(\d+)\s+kB/i);
        if (m_cache) { result.cached_kb = int(m_cache[1]); continue; }
    }

    if (result.available_kb == null)
        result.available_kb = result.free_kb + result.buffers_kb + result.cached_kb;

    return result;
}

// ---------------------------------------------------------------------------
// 1. Memory Check
// ---------------------------------------------------------------------------

function check_ram(opts) {
    opts = type(opts) == "object" ? opts : {};
    let min_kb = (opts.min_available_kb != null) ? int(opts.min_available_kb) : DEFAULT_MIN_RAM_KB;
    let path = as_string(opts.meminfo_path || getenv("TACHYON_MEMINFO_PATH") || "/proc/meminfo");

    let text = "";
    if (opts.meminfo_text != null) {
        text = as_string(opts.meminfo_text);
    } else {
        let read_res = fs.readfile(path);
        text = (read_res != null) ? as_string(read_res) : "";
    }

    let mem = parse_meminfo(text);
    let ok = (mem.available_kb != null && mem.available_kb >= min_kb);

    let msg = "";
    if (mem.total_kb == 0 && text == "") {
        msg = sprintf("Unable to read memory information from %s", path);
        ok = false;
    } else if (ok) {
        msg = sprintf("Available RAM %d KB satisfies requirement %d KB (Total: %d KB)", mem.available_kb, min_kb, mem.total_kb);
    } else {
        msg = sprintf("Insufficient available RAM: %d KB available, %d KB required (Total: %d KB)", mem.available_kb, min_kb, mem.total_kb);
    }

    return {
        ok: ok,
        total_kb: mem.total_kb,
        free_kb: mem.free_kb,
        available_kb: mem.available_kb || 0,
        buffers_kb: mem.buffers_kb,
        cached_kb: mem.cached_kb,
        required_kb: min_kb,
        message: msg
    };
}

// ---------------------------------------------------------------------------
// Helper: Filesystem df parser
// ---------------------------------------------------------------------------

function parse_df_output(output) {
    if (output == null || output == "")
        return null;

    let lines = split(trim(output), "\n");
    if (length(lines) < 2)
        return null;

    // Use POSIX df -Pk output:
    // Filesystem 1024-blocks Used Available Capacity Mounted on
    let data_line = trim(lines[length(lines) - 1]);
    let parts = [];
    for (let part in split(data_line, " ")) {
        if (part != "") push(parts, part);
    }

    if (length(parts) < 6)
        return null;

    return {
        filesystem: parts[0],
        total_kb: int(parts[1]),
        used_kb: int(parts[2]),
        available_kb: int(parts[3]),
        use_pct: parts[4],
        mounted_on: parts[5]
    };
}

// ---------------------------------------------------------------------------
// 2. Storage Check (generic path)
// ---------------------------------------------------------------------------

function check_storage(target_path, opts) {
    target_path = as_string(target_path || "/");
    opts = type(opts) == "object" ? opts : {};
    let min_kb = (opts.min_free_kb != null) ? int(opts.min_free_kb) : 0;

    let df_data = null;
    if (opts.mock_df != null && type(opts.mock_df) == "object") {
        df_data = opts.mock_df;
    } else {
        let cmd = "df -Pk " + shell_quote(target_path) + " 2>/dev/null";
        let out = command_output(cmd);
        df_data = parse_df_output(out);
    }

    if (df_data == null) {
        return {
            ok: false,
            path: target_path,
            filesystem: "unknown",
            total_kb: 0,
            used_kb: 0,
            available_kb: 0,
            use_pct: "0%",
            required_kb: min_kb,
            message: sprintf("Unable to determine disk space for path %s", target_path)
        };
    }

    let ok = df_data.available_kb >= min_kb;
    let msg = ok ?
        sprintf("Storage on %s (%s) has %d KB free, requirement %d KB satisfied", target_path, df_data.filesystem, df_data.available_kb, min_kb) :
        sprintf("Storage deficit on %s (%s): %d KB free, %d KB required (deficit: %d KB)", target_path, df_data.filesystem, df_data.available_kb, min_kb, min_kb - df_data.available_kb);

    return {
        ok: ok,
        path: target_path,
        filesystem: df_data.filesystem,
        mounted_on: df_data.mounted_on,
        total_kb: df_data.total_kb,
        used_kb: df_data.used_kb,
        available_kb: df_data.available_kb,
        use_pct: df_data.use_pct,
        required_kb: min_kb,
        message: msg
    };
}

// ---------------------------------------------------------------------------
// 3. /tmp Capacity Check
// ---------------------------------------------------------------------------

function check_tmp(opts) {
    opts = type(opts) == "object" ? opts : {};
    let min_kb = (opts.min_free_kb != null) ? int(opts.min_free_kb) : DEFAULT_MIN_TMP_KB;
    let path = as_string(opts.tmp_path || getenv("TACHYON_TMP_PATH") || "/tmp");
    let storage_opts = { min_free_kb: min_kb };
    if (opts.mock_df != null) storage_opts.mock_df = opts.mock_df;
    return check_storage(path, storage_opts);
}

// ---------------------------------------------------------------------------
// 4. Flash / Root Capacity Check (/overlay or /)
// ---------------------------------------------------------------------------

function check_flash(opts) {
    opts = type(opts) == "object" ? opts : {};
    let min_kb = (opts.min_free_kb != null) ? int(opts.min_free_kb) : DEFAULT_MIN_FLASH_KB;

    let target = opts.flash_path || getenv("TACHYON_FLASH_PATH");
    if (target == null || target == "") {
        // Detect if /overlay is mounted or accessible
        let st = fs.stat("/overlay");
        if (st != null)
            target = "/overlay";
        else
            target = "/";
    }

    let storage_opts = { min_free_kb: min_kb };
    if (opts.mock_df != null) storage_opts.mock_df = opts.mock_df;
    return check_storage(target, storage_opts);
}

// ---------------------------------------------------------------------------
// 5. Package Manager Database & Lock Status
// ---------------------------------------------------------------------------

function check_package_db(opts) {
    opts = type(opts) == "object" ? opts : {};
    let mgr = packages.detect_pkg_manager();
    let holder = packages.find_lock_holder();
    let locked = (holder != null);
    let stale = locked ? packages.is_stale_lock(holder) : false;

    // Optional wait if locked
    if (locked && opts.wait_lock) {
        let wait_res = packages.wait_for_lock({
            timeout: int(opts.lock_timeout || 10)
        });
        if (wait_res.acquired) {
            locked = false;
            holder = null;
            stale = false;
        }
    }

    let allow_missing = (opts.allow_missing_pkg_mgr == true || getenv("TACHYON_PREFLIGHT_ALLOW_MISSING_PKG") == "1");
    let ok = !locked;
    let msg = "";
    if (mgr == "") {
        msg = "No supported package manager (apk or opkg) found on system";
        ok = allow_missing;
    } else if (!locked) {
        msg = sprintf("Package manager %s is ready (database unlocked)", uc(mgr));
    } else if (stale) {
        msg = sprintf("Package manager %s is locked by dead PID %s (stale lock)", uc(mgr), holder.pid);
    } else {
        msg = sprintf("Package manager %s is currently locked by PID %s (%s)", uc(mgr), holder.pid, holder.command);
    }

    return {
        ok: ok,
        package_manager: mgr,
        locked: locked,
        holder: holder,
        stale: stale,
        message: msg
    };
}

// ---------------------------------------------------------------------------
// 6. CPU Architecture Compatibility
// ---------------------------------------------------------------------------

function check_arch(opts) {
    opts = type(opts) == "object" ? opts : {};
    let detected = packages.detect_arch();

    let supported = true;
    let msg = "";

    if (detected == "" || detected == "unknown") {
        supported = false;
        msg = "Failed to detect CPU architecture";
    } else if (type(opts.supported_archs) == "array") {
        supported = (index(opts.supported_archs, detected) >= 0);
        if (supported) {
            msg = sprintf("Architecture '%s' is in supported list", detected);
        } else {
            msg = sprintf("Architecture '%s' is not supported (allowed: %s)", detected, join(", ", opts.supported_archs));
        }
    } else if (opts.target_arch != null && opts.target_arch != "") {
        let target = as_string(opts.target_arch);
        // Direct match or known aliases
        if (target == detected) {
            supported = true;
            msg = sprintf("Architecture '%s' matches target '%s'", detected, target);
        } else if ((target == "arm64" && detected == "aarch64") || (target == "aarch64" && detected == "arm64")) {
            supported = true;
            msg = sprintf("Architecture '%s' is compatible with target '%s'", detected, target);
        } else if ((target == "amd64" && detected == "x86_64") || (target == "x86_64" && detected == "amd64")) {
            supported = true;
            msg = sprintf("Architecture '%s' is compatible with target '%s'", detected, target);
        } else {
            supported = false;
            msg = sprintf("Architecture mismatch: system is '%s', target requires '%s'", detected, target);
        }
    } else {
        msg = sprintf("Detected CPU architecture '%s'", detected);
    }

    return {
        ok: supported,
        arch: detected,
        supported: supported,
        message: msg
    };
}

// ---------------------------------------------------------------------------
// 7. 7-Factor Disk Budget Calculator & Validator
// ---------------------------------------------------------------------------

function to_kb(value, unit) {
    if (value == null || value == "")
        return 0;
    let n = int(value);
    if (unit == "kb")
        return n;
    // Default unit is bytes
    return int((n + 1023) / 1024);
}

function calculate_disk_budget(spec) {
    spec = type(spec) == "object" ? spec : {};
    let unit = as_string(spec.unit || "bytes");

    let download_kb = to_kb(spec.download, unit);
    let temp_kb     = to_kb(spec.temp, unit);
    let old_kb      = to_kb(spec.old, unit);
    let new_kb      = to_kb(spec.new, unit);
    let rollback_kb = to_kb(spec.rollback, unit);
    let metadata_kb = to_kb(spec.metadata, unit);
    let reserve_kb  = (spec.reserve != null) ? to_kb(spec.reserve, unit) : DEFAULT_DISK_RESERVE_KB;

    // Peak storage required in /tmp (or RAM tmpfs):
    // Includes: downloaded package/archive + unpacked temp extraction + snapshot for rollback + reserve margin
    let tmp_peak_kb = download_kb + temp_kb + rollback_kb + reserve_kb;

    // Peak storage required on target Flash (/overlay or /):
    // During installation, old files exist until atomically replaced by new ones, plus metadata and safety reserve
    let flash_peak_kb = old_kb + new_kb + metadata_kb + reserve_kb;

    // Permanent net storage delta on Flash after old files are removed and transaction completes
    let flash_net_kb = new_kb - old_kb + metadata_kb;

    // Combined peak
    let total_peak_kb = tmp_peak_kb + flash_peak_kb;

    return {
        download_kb: download_kb,
        temp_kb: temp_kb,
        old_kb: old_kb,
        new_kb: new_kb,
        rollback_kb: rollback_kb,
        metadata_kb: metadata_kb,
        reserve_kb: reserve_kb,
        tmp_peak_kb: tmp_peak_kb,
        flash_peak_kb: flash_peak_kb,
        flash_net_kb: flash_net_kb,
        total_peak_kb: total_peak_kb
    };
}

function validate_disk_budget(spec, opts) {
    opts = type(opts) == "object" ? opts : {};
    let budget = calculate_disk_budget(spec);

    let tmp_res = check_tmp({
        min_free_kb: budget.tmp_peak_kb,
        tmp_path: opts.tmp_path,
        mock_df: opts.mock_tmp_df
    });

    let flash_res = check_flash({
        min_free_kb: budget.flash_peak_kb,
        flash_path: opts.flash_path,
        mock_df: opts.mock_flash_df
    });

    let ok = tmp_res.ok && flash_res.ok;
    let tmp_deficit = tmp_res.available_kb < budget.tmp_peak_kb ? (budget.tmp_peak_kb - tmp_res.available_kb) : 0;
    let flash_deficit = flash_res.available_kb < budget.flash_peak_kb ? (budget.flash_peak_kb - flash_res.available_kb) : 0;

    let msg = "";
    if (ok) {
        msg = sprintf("Disk budget satisfied: /tmp requires %d KB (available %d KB), flash requires %d KB (available %d KB)",
            budget.tmp_peak_kb, tmp_res.available_kb, budget.flash_peak_kb, flash_res.available_kb);
    } else {
        let parts = [];
        if (!tmp_res.ok)
            push(parts, sprintf("/tmp needs %d KB, short by %d KB", budget.tmp_peak_kb, tmp_deficit));
        if (!flash_res.ok)
            push(parts, sprintf("flash needs %d KB, short by %d KB", budget.flash_peak_kb, flash_deficit));
        msg = "Disk budget validation failed: " + join("; ", parts);
    }

    return {
        ok: ok,
        budget: budget,
        tmp: {
            path: tmp_res.path,
            available_kb: tmp_res.available_kb,
            required_kb: budget.tmp_peak_kb,
            ok: tmp_res.ok,
            deficit_kb: tmp_deficit
        },
        flash: {
            path: flash_res.path,
            available_kb: flash_res.available_kb,
            required_kb: budget.flash_peak_kb,
            ok: flash_res.ok,
            deficit_kb: flash_deficit
        },
        message: msg
    };
}

// ---------------------------------------------------------------------------
// 8. Full Unified Preflight Check
// ---------------------------------------------------------------------------

function check_all(opts) {
    opts = type(opts) == "object" ? opts : {};

    let ram_res   = check_ram(opts.ram);
    let tmp_res   = check_tmp(opts.tmp);
    let flash_res = check_flash(opts.flash);
    let pkg_res   = check_package_db(opts.packages);
    let arch_res  = check_arch(opts.arch);

    let budget_res = null;
    if (opts.budget != null)
        budget_res = validate_disk_budget(opts.budget, opts);

    let errors = [];
    let warnings = [];

    if (!ram_res.ok)   push(errors, ram_res.message);
    if (!tmp_res.ok)   push(errors, tmp_res.message);
    if (!flash_res.ok) push(errors, flash_res.message);
    if (!arch_res.ok)  push(errors, arch_res.message);

    if (!pkg_res.ok) {
        if (opts.ignore_package_lock == true)
            push(warnings, pkg_res.message);
        else
            push(errors, pkg_res.message);
    }

    if (budget_res != null && !budget_res.ok)
        push(errors, budget_res.message);

    let all_ok = (length(errors) == 0);

    return {
        ok: all_ok,
        passed: all_ok,
        errors: errors,
        warnings: warnings,
        checks: {
            ram: ram_res,
            tmp: tmp_res,
            flash: flash_res,
            packages: pkg_res,
            arch: arch_res,
            budget: budget_res
        }
    };
}

// ---------------------------------------------------------------------------
// 9. Integration with core.transaction
// ---------------------------------------------------------------------------

function preflight_validator(opts) {
    opts = type(opts) == "object" ? opts : {};
    return function(tx) {
        let res = check_all(opts);
        if (!res.ok) {
            let detail = join("; ", res.errors);
            if (tx && type(tx.log) == "function") {
                tx.log("error", "Preflight validation failed: " + detail);
            }
            return {
                ok: false,
                reason: "Preflight check failed: " + detail,
                detail: res
            };
        }
        if (tx && type(tx.log) == "function") {
            tx.log("info", "Preflight validation passed: all resource budgets verified");
        }
        return {
            ok: true,
            detail: res
        };
    };
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        check_ram,
        check_storage,
        check_tmp,
        check_flash,
        check_package_db,
        check_arch,
        calculate_disk_budget,
        validate_disk_budget,
        check_all,
        preflight_validator,
        parse_meminfo,
        parse_df_output,
        DEFAULT_MIN_RAM_KB,
        DEFAULT_MIN_TMP_KB,
        DEFAULT_MIN_FLASH_KB,
        DEFAULT_DISK_RESERVE_KB
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ---------------------------------------------------------------------------
// CLI Interface
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

if (mode == "all") {
    let res = check_all();
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "ram") {
    let min_kb = ARGV[1] != null ? int(ARGV[1]) : DEFAULT_MIN_RAM_KB;
    let res = check_ram({ min_available_kb: min_kb });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "tmp") {
    let min_kb = ARGV[1] != null ? int(ARGV[1]) : DEFAULT_MIN_TMP_KB;
    let res = check_tmp({ min_free_kb: min_kb });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "flash") {
    let min_kb = ARGV[1] != null ? int(ARGV[1]) : DEFAULT_MIN_FLASH_KB;
    let res = check_flash({ min_free_kb: min_kb });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "storage") {
    let target = ARGV[1] || "/";
    let min_kb = ARGV[2] != null ? int(ARGV[2]) : 0;
    let res = check_storage(target, { min_free_kb: min_kb });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "packages") {
    let res = check_package_db();
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "arch") {
    let target = ARGV[1];
    let res = check_arch({ target_arch: target });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "budget") {
    let raw = ARGV[1] || "{}";
    let spec = {};
    try { spec = json(raw); } catch (e) { spec = {}; }
    let res = validate_disk_budget(spec);
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "selftest") {
    let pass = 0;
    let fail = 0;

    function assert(cond, name) {
        if (cond) {
            pass++;
        } else {
            fail++;
            warn("FAIL: " + name + "\n");
        }
    }

    // 1. Meminfo parser
    let mock_meminfo = "MemTotal:       1024000 kB\nMemFree:         100000 kB\nMemAvailable:    300000 kB\nBuffers:          50000 kB\nCached:          150000 kB\n";
    let parsed_mem = parse_meminfo(mock_meminfo);
    assert(parsed_mem.total_kb == 1024000, "parse_meminfo total_kb");
    assert(parsed_mem.available_kb == 300000, "parse_meminfo available_kb");

    // Fallback without MemAvailable
    let mock_meminfo_legacy = "MemTotal:       1024000 kB\nMemFree:         100000 kB\nBuffers:          50000 kB\nCached:          150000 kB\n";
    let parsed_leg = parse_meminfo(mock_meminfo_legacy);
    assert(parsed_leg.available_kb == 300000, "parse_meminfo legacy fallback (100k + 50k + 150k)");

    // 2. check_ram
    let ram_ok = check_ram({ meminfo_text: mock_meminfo, min_available_kb: 200000 });
    assert(ram_ok.ok == true, "check_ram satisfies minimum");
    let ram_fail = check_ram({ meminfo_text: mock_meminfo, min_available_kb: 400000 });
    assert(ram_fail.ok == false, "check_ram detects insufficient RAM");

    // 3. parse_df_output
    let mock_df_str = "Filesystem           1024-blocks      Used Available Capacity Mounted on\n/dev/root               102400     51200     51200      50% /\n";
    let parsed_df = parse_df_output(mock_df_str);
    assert(parsed_df != null, "parse_df_output not null");
    assert(parsed_df.total_kb == 102400, "parse_df total_kb");
    assert(parsed_df.available_kb == 51200, "parse_df available_kb");

    // 4. Disk budget calculator
    let budget_spec = {
        download: 10485760, // 10 MB in bytes = 10240 KB
        temp: 20971520,     // 20 MB = 20480 KB
        old: 15728640,      // 15 MB = 15360 KB
        new: 18874368,      // 18 MB = 18432 KB
        rollback: 15728640, // 15 MB = 15360 KB
        metadata: 1048576,  // 1 MB = 1024 KB
        reserve: 2097152    // 2 MB = 2048 KB
    };
    let b = calculate_disk_budget(budget_spec);
    assert(b.download_kb == 10240, "budget download_kb");
    assert(b.temp_kb == 20480, "budget temp_kb");
    assert(b.rollback_kb == 15360, "budget rollback_kb");
    // tmp_peak = 10240 + 20480 + 15360 + 2048 = 48128 KB
    assert(b.tmp_peak_kb == 48128, "budget tmp_peak_kb calculation");
    // flash_peak = 15360 + 18432 + 1024 + 2048 = 36864 KB
    assert(b.flash_peak_kb == 36864, "budget flash_peak_kb calculation");
    // flash_net = 18432 - 15360 + 1024 = 4096 KB
    assert(b.flash_net_kb == 4096, "budget flash_net_kb calculation");

    // 5. validate_disk_budget with mock storage
    let mock_tmp_df = { filesystem: "tmpfs", total_kb: 65536, used_kb: 10000, available_kb: 55536, mounted_on: "/tmp", use_pct: "15%" };
    let mock_flash_df = { filesystem: "/dev/mtdblock3", total_kb: 65536, used_kb: 20000, available_kb: 45536, mounted_on: "/overlay", use_pct: "30%" };

    let valid_res = validate_disk_budget(budget_spec, {
        mock_tmp_df: mock_tmp_df,
        mock_flash_df: mock_flash_df
    });
    assert(valid_res.ok == true, "validate_disk_budget ok when space sufficient");

    let small_tmp_df = { filesystem: "tmpfs", total_kb: 32768, used_kb: 10000, available_kb: 22768, mounted_on: "/tmp", use_pct: "30%" };
    let invalid_res = validate_disk_budget(budget_spec, {
        mock_tmp_df: small_tmp_df,
        mock_flash_df: mock_flash_df
    });
    assert(invalid_res.ok == false, "validate_disk_budget fails when /tmp insufficient");
    assert(invalid_res.tmp.deficit_kb > 0, "reports /tmp deficit");

    // 6. check_arch
    let arch_same = check_arch({ target_arch: "x86_64", supported_archs: [ "x86_64", "aarch64" ] });
    assert(type(arch_same.arch) == "string", "arch is string");

    print("preflight.uc selftest: " + pass + " passed, " + fail + " failed\n");
    exit(fail > 0 ? 1 : 0);
}
else {
    warn("Usage: core/preflight.uc <all|ram|tmp|flash|storage|packages|arch|budget|selftest> ...\n");
    exit(1);
}
