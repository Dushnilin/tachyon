#!/usr/bin/env ucode

// ─── Tachyon Last Known Good (LKG) State Manager ──────────────────────────────
//
// Architectural Role:
//   Maintains the canonical "Last Known Good" state of Tachyon in /etc/tachyon/state/known_good/
//   - Observation Window: monitors active configuration after changes (service alive,
//     DNS resolving, routing healthy, no restart loops).
//   - Automatic Promotion: blesses configuration as Known Good when observation window passes.
//   - Preferred Rollback: Reconciler and Watchdog prefer rolling back to Known Good
//     before resorting to destructive factory resets or emergency failsafes.
//   - Loop Prevention: guards against flapping or rolling back to an identical failing state.
//

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const DEFAULT_CONFIG_PATH = "/etc/config/" + CONFIG_NAME;

let as_string = common.as_string;
let shell_quote = common.shell_quote;

// Optional core modules
let logging = null;
try { logging = require("core.logging"); } catch (e) {}

let events = null;
try { events = require("core.events"); } catch (e) {}

// ─── Path Resolution ──────────────────────────────────────────────────────────

let _override_kg_dir = null;
let _override_obs_file = null;
let _override_cfg_path = null;
let _override_variant_path = null;

function set_test_overrides(kg_dir, obs_file, cfg_path, variant_path) {
    _override_kg_dir = kg_dir;
    _override_obs_file = obs_file;
    _override_cfg_path = cfg_path;
    _override_variant_path = variant_path;
}

function get_known_good_dir() {
    if (_override_kg_dir != null) return _override_kg_dir;
    let d = getenv("TACHYON_KNOWN_GOOD_DIR");
    if (d != null && d != "") return d;
    return "/etc/tachyon/state/known_good";
}

function get_observation_file() {
    if (_override_obs_file != null) return _override_obs_file;
    let f = getenv("TACHYON_OBSERVATION_FILE");
    if (f != null && f != "") return f;
    if (fs.access("/var/run", "w")) return "/var/run/tachyon/observation_state.json";
    return "/tmp/tachyon_observation_state.json";
}

function get_config_path() {
    if (_override_cfg_path != null) return _override_cfg_path;
    let p = getenv("TACHYON_CONFIG_PATH");
    if (p != null && p != "") return p;
    return DEFAULT_CONFIG_PATH;
}

function get_observation_window_seconds() {
    let env_win = getenv("TACHYON_OBSERVATION_WINDOW");
    if (env_win != null && int(env_win) > 0) return int(env_win);

    let c = uci_core.cursor();
    if (c) {
        try {
            c.load(CONFIG_NAME);
            let uci_val = c.get(CONFIG_NAME, "settings", "observation_window");
            if (uci_val != null && int(uci_val) > 0) return int(uci_val);
        } catch (e) {}
    }
    return 60; // 60 seconds default observation window
}

// ─── Logging & Event Helpers ──────────────────────────────────────────────────

function log_info(msg) {
    if (logging && logging.info) {
        logging.info("known_good: " + msg);
    } else {
        system("logger -t " + shell_quote(CONFIG_NAME) + " [info] [known_good] " + shell_quote(msg) + " 2>/dev/null");
    }
}

function log_warn(msg) {
    if (logging && logging.warn) {
        logging.warn("known_good: " + msg);
    } else {
        system("logger -t " + shell_quote(CONFIG_NAME) + " [warn] [known_good] " + shell_quote(msg) + " 2>/dev/null");
    }
}

function publish_event(event_name, data) {
    if (events && events.publish) {
        try {
            events.publish(event_name, data || {});
        } catch (e) {}
    }
}

// ─── Utility Functions ────────────────────────────────────────────────────────

let _rnd_seed = 1000;
function unique_suffix() {
    _rnd_seed = (_rnd_seed + 1) % 999999;
    return as_string(int(time())) + "_" + as_string(_rnd_seed);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) != null) return true;
    let rc = system("mkdir -p " + shell_quote(path) + " 2>/dev/null");
    return rc == 0;
}

function read_json_safe(path) {
    let content = fs.readfile(path);
    if (content == null) return null;
    try {
        return json(as_string(content));
    } catch (e) {
        return null;
    }
}

function write_json_atomic(path, data) {
    let dir_parts = split(path, "/");
    let dir = "";
    for (let i = 0; i < length(dir_parts) - 1; i++) {
        if (dir_parts[i] != "") dir += "/" + dir_parts[i];
    }
    if (dir != "") ensure_dir(dir);

    let tmp_path = path + ".tmp." + unique_suffix();
    let text = sprintf("%J\n", data);
    let ok = fs.writefile(tmp_path, text);
    if (!ok && type(ok) == "boolean") return false;
    let res = fs.rename(tmp_path, path);
    if (!res) {
        // Fallback write directly
        fs.unlink(tmp_path);
        return fs.writefile(path, text);
    }
    return true;
}

function copy_file_atomic(src, dst) {
    let content = fs.readfile(src);
    if (content == null) return false;

    let dir_parts = split(dst, "/");
    let dir = "";
    for (let i = 0; i < length(dir_parts) - 1; i++) {
        if (dir_parts[i] != "") dir += "/" + dir_parts[i];
    }
    if (dir != "") ensure_dir(dir);

    let tmp_path = dst + ".tmp." + unique_suffix();
    let ok = fs.writefile(tmp_path, content);
    if (!ok && type(ok) == "boolean") return false;
    let res = fs.rename(tmp_path, dst);
    if (!res) {
        fs.unlink(tmp_path);
        return fs.writefile(dst, content);
    }
    return true;
}

function file_sha256(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null) return "";
    let p = fs.popen("sha256sum " + shell_quote(path) + " 2>/dev/null", "r");
    if (!p) return "";
    let line = p.read("line");
    p.close();
    if (!line) return "";
    let fields = split(trim(line), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

// ─── Known Good Manifest & Storage ────────────────────────────────────────────

function get_manifest_path() {
    return get_known_good_dir() + "/manifest.json";
}

function get_config_backup_path() {
    return get_known_good_dir() + "/config";
}

function get_variant_target_path() {
    if (_override_variant_path != null) return _override_variant_path;
    let p = getenv("SB_VARIANT_STATE_FILE");
    if (p != null && p != "") return p;
    return "/etc/tachyon/sing-box-variant";
}

function get_variant_backup_path() {
    return get_known_good_dir() + "/variant";
}

function get_history_path() {
    return get_known_good_dir() + "/history.json";
}

function has_known_good() {
    let m = read_json_safe(get_manifest_path());
    if (m == null || type(m) != "object") return false;
    let cfg = fs.readfile(get_config_backup_path());
    if (cfg == null || trim(as_string(cfg)) == "") return false;
    return true;
}

function get_known_good_manifest() {
    return read_json_safe(get_manifest_path());
}

function get_history() {
    let hist = read_json_safe(get_history_path());
    if (hist == null || type(hist) != "array") return [];
    return hist;
}

function append_history(action, details) {
    let hist = get_history();
    let entry = {
        timestamp: time(),
        action: action,
        details: details || {}
    };
    push(hist, entry);
    // Keep bounded history (last 20 events)
    while (length(hist) > 20) {
        shift(hist);
    }
    write_json_atomic(get_history_path(), hist);
}

// ─── Engine and Health Probes ─────────────────────────────────────────────────

function get_active_engine() {
    let c = uci_core.cursor();
    if (c) {
        try {
            c.load(CONFIG_NAME);
            let eng = c.get(CONFIG_NAME, "settings", "engine");
            if (eng != null && eng != "") return eng;
        } catch (e) {}
    }
    return "sing-box";
}

function get_engine_pid(engine_id) {
    engine_id = engine_id || get_active_engine();
    let proc_name = engine_id == "steer" ? "steer" : "sing-box";
    let p = fs.popen("pidof " + shell_quote(proc_name) + " 2>/dev/null", "r");
    if (!p) return 0;
    let out = trim(as_string(p.read("line")));
    p.close();
    if (out == "") return 0;
    let pids = split(out, /[ \t]+/);
    return length(pids) > 0 ? int(pids[0]) : 0;
}

function probe_system_health(engine_id) {
    engine_id = engine_id || get_active_engine();

    // 1. Core process running
    let pid = get_engine_pid(engine_id);
    let service_alive = pid > 0;

    // 2. DNS interception
    let dns_ok = false;
    let dns_probe = fs.popen("nslookup -timeout=2 127.0.0.1 127.0.0.1 2>&1", "r");
    if (dns_probe) {
        let out = as_string(dns_probe.read("all"));
        let rc = dns_probe.close();
        if (rc == 0 || index(out, "Address") >= 0 || index(out, "127.0.0.1") >= 0) {
            dns_ok = true;
        }
    }

    // 3. Routing / nftables presence
    let routing_ok = true;
    let nft_probe = fs.popen("nft list table inet TachyonTable 2>&1", "r");
    if (nft_probe) {
        let out = as_string(nft_probe.read("all"));
        let rc = nft_probe.close();
        if (rc != 0 && index(out, "No such file") >= 0) {
            if (engine_id == "steer") {
                let st_probe = fs.popen("nft list table inet steer 2>&1", "r");
                if (st_probe) {
                    let st_rc = st_probe.close();
                    routing_ok = st_rc == 0;
                }
            } else {
                routing_ok = service_alive;
            }
        }
    }

    return {
        service_alive: service_alive,
        engine_pid: pid,
        dns_ok: dns_ok,
        routing_ok: routing_ok,
        all_passed: service_alive && dns_ok && routing_ok
    };
}

// ─── Promotion to Known Good ──────────────────────────────────────────────────

function promote(reason, metrics) {
    metrics = metrics || {};
    let config_file = get_config_path();

    if (fs.stat(config_file) == null) {
        return {
            ok: false,
            success: false,
            error: "Active config file not found: " + config_file
        };
    }

    let config_content = fs.readfile(config_file);
    if (config_content == null || trim(as_string(config_content)) == "") {
        return {
            ok: false,
            success: false,
            error: "Active config file is empty or unreadable"
        };
    }

    ensure_dir(get_known_good_dir());

    // 1. Copy config
    let cfg_backup = get_config_backup_path();
    if (!copy_file_atomic(config_file, cfg_backup)) {
        return {
            ok: false,
            success: false,
            error: "Failed to create atomic backup copy of config"
        };
    }

    // 2. Copy variant if present
    if (fs.stat("/etc/tachyon/sing-box-variant") != null) {
        copy_file_atomic("/etc/tachyon/sing-box-variant", get_variant_backup_path());
    }

    // 3. Calculate hash
    let hash = file_sha256(cfg_backup);
    let eng = get_active_engine();

    // 4. Write manifest
    let manifest = {
        version: constants.TACHYON_VERSION || "1.4.3",
        promoted_at: time(),
        promotion_reason: reason || "manual_bless",
        config_hash: hash,
        engine: eng,
        stable_duration: metrics.stable_duration || 0,
        health_metrics: metrics
    };

    if (!write_json_atomic(get_manifest_path(), manifest)) {
        return {
            ok: false,
            success: false,
            error: "Failed to write manifest.json"
        };
    }

    // 5. Update observation state file
    write_json_atomic(get_observation_file(), {
        status: "promoted",
        promoted_at: time(),
        config_hash: hash,
        reason: reason
    });

    // 6. Record history
    append_history("promote", {
        reason: reason,
        config_hash: hash,
        engine: eng
    });

    log_info(sprintf("Promoted active configuration to Last Known Good (hash: %s, reason: %s)", substr(hash, 0, 12), reason));
    publish_event("known_good_promoted", {
        config_hash: hash,
        promoted_at: manifest.promoted_at,
        reason: reason
    });

    return {
        ok: true,
        success: true,
        promoted_at: manifest.promoted_at,
        config_hash: hash,
        engine: eng,
        reason: reason
    };
}

// ─── Observation Window Logic ─────────────────────────────────────────────────

function start_observation(reason, window_seconds) {
    let config_file = get_config_path();
    let current_hash = file_sha256(config_file);

    // If active config matches current Known Good, no observation needed
    if (has_known_good()) {
        let m = get_known_good_manifest();
        if (m && m.config_hash == current_hash) {
            write_json_atomic(get_observation_file(), {
                status: "already_known_good",
                config_hash: current_hash,
                promoted_at: m.promoted_at
            });
            return {
                status: "already_known_good",
                is_known_good: true,
                config_hash: current_hash
            };
        }
    }

    let win = int(window_seconds || get_observation_window_seconds());
    let eng = get_active_engine();
    let initial_pid = get_engine_pid(eng);

    let obs_state = {
        status: "observing",
        reason: reason || "config_changed",
        started_at: time(),
        window_seconds: win,
        config_hash: current_hash,
        engine: eng,
        initial_pid: initial_pid,
        checks_passed: 0,
        checks_failed: 0,
        last_check_at: time()
    };

    ensure_dir("/var/run/tachyon");
    write_json_atomic(get_observation_file(), obs_state);

    log_info(sprintf("Started observation window (%ds) for config hash %s (reason: %s)", win, substr(current_hash, 0, 12), reason || "unspecified"));
    publish_event("known_good_observation_started", {
        window_seconds: win,
        config_hash: current_hash,
        reason: reason
    });

    return {
        status: "observing",
        is_observing: true,
        started_at: obs_state.started_at,
        window_seconds: win,
        config_hash: current_hash
    };
}

function check_observation(probe_override) {
    let obs = read_json_safe(get_observation_file());
    if (obs == null || obs.status != "observing") {
        return {
            status: obs ? obs.status : "idle",
            is_observing: false,
            message: "No observation window actively running"
        };
    }

    let now = time();
    let elapsed = now - int(obs.started_at || now);
    let current_hash = file_sha256(get_config_path());

    // Config changed while observing -> restart observation
    if (current_hash != obs.config_hash && current_hash != "") {
        return start_observation("config_modified_during_observation", obs.window_seconds);
    }

    // Run or use probe results
    let probe = probe_override || probe_system_health(obs.engine);

    obs.last_check_at = now;

    if (!probe.all_passed) {
        obs.checks_failed = int(obs.checks_failed || 0) + 1;
        write_json_atomic(get_observation_file(), obs);

        // Immediate failure if service died or failures >= 3
        if (!probe.service_alive || obs.checks_failed >= 3) {
            obs.status = "failed";
            obs.failed_at = now;
            obs.failure_reason = !probe.service_alive ? "Engine process died" : "Repeated probe failures during observation";
            write_json_atomic(get_observation_file(), obs);

            append_history("observation_failed", {
                reason: obs.failure_reason,
                config_hash: obs.config_hash,
                elapsed: elapsed
            });

            log_warn(sprintf("Observation window FAILED after %ds: %s", elapsed, obs.failure_reason));
            publish_event("known_good_observation_failed", {
                reason: obs.failure_reason,
                config_hash: obs.config_hash,
                elapsed: elapsed
            });

            return {
                status: "failed",
                should_rollback: true,
                reason: obs.failure_reason,
                elapsed: elapsed,
                failed_checks: {
                    service_alive: probe.service_alive,
                    dns_ok: probe.dns_ok,
                    routing_ok: probe.routing_ok
                }
            };
        }

        return {
            status: "observing",
            elapsed: elapsed,
            remaining: (obs.window_seconds - elapsed) > 0 ? (obs.window_seconds - elapsed) : 0,
            checks_passed: obs.checks_passed,
            checks_failed: obs.checks_failed,
            warning: "Transient check failure detected during observation"
        };
    }

    // Probes passed
    obs.checks_passed = int(obs.checks_passed || 0) + 1;

    // Window elapsed! Bless active state!
    if (elapsed >= int(obs.window_seconds || 60)) {
        let p_res = promote("observation_window_passed", {
            stable_duration: elapsed,
            checks_passed: obs.checks_passed,
            checks_failed: obs.checks_failed
        });
        return {
            status: "promoted",
            is_observing: false,
            promoted_at: p_res.promoted_at,
            config_hash: p_res.config_hash,
            elapsed: elapsed,
            message: "Observation window passed successfully; promoted to Last Known Good"
        };
    }

    write_json_atomic(get_observation_file(), obs);

    return {
        status: "observing",
        is_observing: true,
        elapsed: elapsed,
        remaining: obs.window_seconds - elapsed,
        checks_passed: obs.checks_passed,
        checks_failed: obs.checks_failed
    };
}

// ─── Rollback to Known Good ───────────────────────────────────────────────────

function rollback_to_known_good(reason, options) {
    options = options || {};

    if (!has_known_good()) {
        return {
            ok: false,
            success: false,
            error: "No Last Known Good state exists to roll back to"
        };
    }

    let manifest = get_known_good_manifest();
    let lkg_config_path = get_config_backup_path();
    let active_config_path = get_config_path();

    let lkg_content = fs.readfile(lkg_config_path);
    if (lkg_content == null || trim(as_string(lkg_content)) == "") {
        return {
            ok: false,
            success: false,
            error: "Known good config backup file is missing or unreadable"
        };
    }

    let active_content = fs.readfile(active_config_path);
    let lkg_hash = file_sha256(lkg_config_path);
    let active_hash = file_sha256(active_config_path);

    // Prevent flapping loop if current config is already the known good config
    if (lkg_hash == active_hash && !options.force) {
        return {
            ok: false,
            success: false,
            error: "Active config is already identical to Last Known Good (hash: " + substr(lkg_hash, 0, 12) + "); aborting loop rollback"
        };
    }

    // 1. Preserve failing config for post-mortem forensics
    if (active_content != null) {
        let failed_dest = get_known_good_dir() + "/last_failed_config";
        copy_file_atomic(active_config_path, failed_dest);
    }

    // 2. Restore config atomically
    if (!copy_file_atomic(lkg_config_path, active_config_path)) {
        return {
            ok: false,
            success: false,
            error: "Failed to atomically restore known good configuration to " + active_config_path
        };
    }

    // 3. Restore variant if present
    let variant_backup = get_variant_backup_path();
    if (fs.stat(variant_backup) != null)
        copy_file_atomic(variant_backup, get_variant_target_path());

    // 4. Update observation state to rolled_back
    write_json_atomic(get_observation_file(), {
        status: "rolled_back",
        rolled_back_at: time(),
        restored_from: manifest.promoted_at,
        config_hash: lkg_hash,
        reason: reason || "manual_rollback"
    });

    // 5. Append history
    append_history("rollback", {
        reason: reason || "manual_rollback",
        restored_hash: lkg_hash,
        failed_hash: active_hash,
        promoted_at: manifest.promoted_at
    });

    log_warn(sprintf("Rolled back configuration to Last Known Good state (promoted at %s, hash: %s, reason: %s)",
        as_string(manifest.promoted_at), substr(lkg_hash, 0, 12), reason || "unspecified"));
    publish_event("known_good_rollback_applied", {
        restored_from: manifest.promoted_at,
        config_hash: lkg_hash,
        reason: reason
    });

    // 6. Trigger service reload if requested (default true)
    let reload_initiated = false;
    if (options.reload != false) {
        system(common.background_command("/usr/bin/tachyon reload"));
        reload_initiated = true;
    }

    return {
        ok: true,
        success: true,
        restored_from: manifest.promoted_at,
        config_hash: lkg_hash,
        reason: reason || "manual_rollback",
        reload_initiated: reload_initiated
    };
}

// ─── Status Inspection ────────────────────────────────────────────────────────

function get_status() {
    let manifest = get_known_good_manifest();
    let has_lkg = has_known_good();
    let active_hash = file_sha256(get_config_path());
    let obs = read_json_safe(get_observation_file());

    let obs_status = "idle";
    let elapsed = 0;
    let remaining = 0;
    let win_sec = get_observation_window_seconds();

    if (obs && obs.status == "observing") {
        obs_status = "observing";
        elapsed = time() - int(obs.started_at || time());
        win_sec = int(obs.window_seconds || win_sec);
        remaining = (win_sec - elapsed) > 0 ? (win_sec - elapsed) : 0;
    } else if (obs && obs.status) {
        obs_status = obs.status;
    }

    let is_active_lkg = has_lkg && manifest && (manifest.config_hash == active_hash);

    return {
        has_known_good: has_lkg,
        active_config_hash: active_hash,
        is_active_config_known_good: is_active_lkg,
        manifest: manifest,
        observation: {
            status: obs_status,
            is_observing: obs_status == "observing",
            elapsed_seconds: elapsed,
            window_seconds: win_sec,
            remaining_seconds: remaining,
            checks_passed: obs ? (obs.checks_passed || 0) : 0,
            checks_failed: obs ? (obs.checks_failed || 0) : 0,
            reason: obs ? (obs.reason || "") : ""
        },
        history: get_history()
    };
}

function format_text_status(st) {
    let lines = [];
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, "                   TACHYON LAST KNOWN GOOD (LKG) STATUS                     ");
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, sprintf(" State Available:  %s", st.has_known_good ? "YES" : "NO"));
    push(lines, sprintf(" Active Is LKG:    %s", st.is_active_config_known_good ? "YES (Active == LKG)" : "NO (Candidate / Unpromoted)"));

    if (st.has_known_good && st.manifest) {
        let m = st.manifest;
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Last Known Good Manifest:");
        push(lines, sprintf("  Promoted At:     %s (Epoch: %s)", as_string(m.promoted_at), as_string(m.promoted_at)));
        push(lines, sprintf("  Reason:          %s", m.promotion_reason || "unknown"));
        push(lines, sprintf("  Config SHA256:   %s", m.config_hash || "none"));
        push(lines, sprintf("  Routing Engine:  %s", m.engine || "sing-box"));
        if (m.stable_duration) {
            push(lines, sprintf("  Observed Stable: %ds", m.stable_duration));
        }
    }

    push(lines, "──────────────────────────────────────────────────────────────────────────────");
    push(lines, " Observation Window Status:");
    push(lines, sprintf("  Status:          [%s]", uc(st.observation.status)));
    if (st.observation.is_observing) {
        push(lines, sprintf("  Elapsed / Window: %ds / %ds (Remaining: %ds)",
            st.observation.elapsed_seconds, st.observation.window_seconds, st.observation.remaining_seconds));
        push(lines, sprintf("  Probes Passed:   %d (Failed: %d)",
            st.observation.checks_passed, st.observation.checks_failed));
        push(lines, sprintf("  Trigger Reason:  %s", st.observation.reason));
    } else {
        push(lines, sprintf("  Observation:     %s", st.observation.status == "promoted" ? "Completed (Promoted)" : "Idle"));
    }

    if (length(st.history) > 0) {
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Recent Event History:");
        for (let i = length(st.history) - 1; i >= 0 && i >= length(st.history) - 5; i--) {
            let h = st.history[i];
            push(lines, sprintf("  * [%s] Action: %s (%s)",
                as_string(h.timestamp), uc(h.action), h.details.reason || ""));
        }
    }

    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    return join("\n", lines) + "\n";
}

// ─── Selftest ─────────────────────────────────────────────────────────────────

function selftest() {
    let passed = 0;
    let failed = 0;

    function assert(cond, name) {
        if (cond) {
            passed++;
        } else {
            failed++;
            print("FAIL: " + name + "\n");
        }
    }

    let tmp_test_dir = "/tmp/tachyon_known_good_test_" + unique_suffix();
    let tmp_obs_file = tmp_test_dir + "/obs_state.json";
    let tmp_cfg_file = tmp_test_dir + "/tachyon_config";

    ensure_dir(tmp_test_dir);

    // Apply test overrides for isolation
    set_test_overrides(tmp_test_dir + "/known_good", tmp_obs_file, tmp_cfg_file);

    // Test 1: Initial state has no known good
    assert(has_known_good() == false, "Initially has_known_good is false");

    // Write sample config
    let initial_uci = "config settings 'settings'\n\toption engine 'sing-box'\n";
    fs.writefile(tmp_cfg_file, initial_uci);

    // Test 2: Promote active config to Known Good
    let p_res = promote("test_initial_bless", { stable_duration: 30 });
    assert(p_res.success == true, "promote succeeds");
    assert(has_known_good() == true, "has_known_good returns true after promote");

    let manifest = get_known_good_manifest();
    assert(manifest != null, "manifest is readable");
    assert(manifest.promotion_reason == "test_initial_bless", "manifest reason recorded");
    assert(manifest.engine == "sing-box", "manifest engine recorded");

    // Test 3: Status reports active == LKG
    let st = get_status();
    assert(st.has_known_good == true, "status has_known_good");
    assert(st.is_active_config_known_good == true, "active config is LKG");

    // Test 4: Modify active config -> starts observation
    let modified_uci = "config settings 'settings'\n\toption engine 'sing-box'\nconfig section 's1'\n\toption action 'proxy'\n";
    fs.writefile(tmp_cfg_file, modified_uci);

    let obs_start = start_observation("user_edit_section", 10);
    assert(obs_start.status == "observing", "observation starts on config change");
    assert(obs_start.window_seconds == 10, "observation window recorded");

    let st2 = get_status();
    assert(st2.is_active_config_known_good == false, "active is no longer LKG");
    assert(st2.observation.status == "observing", "status reports observing");

    // Test 5: Check observation ticking
    let check1 = check_observation({ all_passed: true, service_alive: true, dns_ok: true, routing_ok: true });
    assert(check1.status == "observing", "check reports observing when window not elapsed");
    assert(check1.checks_passed >= 1, "checks_passed incremented");

    // Test 6: Check observation failure detection
    let check_fail = check_observation({ all_passed: false, service_alive: false, dns_ok: false, routing_ok: false });
    assert(check_fail.status == "failed", "check reports failed when process dies");
    assert(check_fail.should_rollback == true, "check signals should_rollback");

    // Test 7: Rollback to Known Good
    let roll_res = rollback_to_known_good("observation_health_failed", { reload: false });
    assert(roll_res.success == true, "rollback succeeds");
    assert(roll_res.restored_from == manifest.promoted_at, "restored from correct timestamp");

    // Verify file content restored
    let restored_content = fs.readfile(tmp_cfg_file);
    assert(trim(as_string(restored_content)) == trim(initial_uci), "active config file content restored to LKG");

    // Test 8: Identical config rollback loop guard
    let roll_again = rollback_to_known_good("redundant_rollback", { reload: false });
    assert(roll_again.success == false, "redundant rollback to identical config rejected");
    assert(index(roll_again.error, "already identical") >= 0, "loop guard error message returned");

    // Test 9: Formatter
    let text = format_text_status(get_status());
    assert(index(text, "TACHYON LAST KNOWN GOOD") >= 0, "text format has banner");
    assert(index(text, "State Available:  YES") >= 0, "text format indicates state available");

    // Cleanup & reset overrides
    system("rm -rf " + shell_quote(tmp_test_dir));
    set_test_overrides(null, null, null);

    print(sprintf("Known good selftest: %d passed, %d failed\n", passed, failed));
    return failed == 0 ? 0 : 1;
}

function module_exports() {
    return {
        has_known_good,
        get_known_good_manifest,
        get_status,
        format_text_status,
        promote,
        rollback_to_known_good,
        start_observation,
        check_observation,
        get_history,
        selftest,
        set_test_overrides
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ─── CLI Entrypoint ───────────────────────────────────────────────────────────

let mode = ARGV[0] || "";

if (mode == "selftest") {
    exit(selftest());
} else if (mode == "status" || mode == "" || substr(mode, 0, 1) == "-") {
    let format = "text";
    for (let i = 0; i < length(ARGV); i++) {
        if (ARGV[i] == "--json") format = "json";
        else if (ARGV[i] == "--text") format = "text";
    }
    let st = get_status();
    if (format == "json") {
        print(sprintf("%J\n", st));
    } else {
        print(format_text_status(st));
    }
    exit(0);
} else if (mode == "promote" || mode == "bless") {
    let reason = ARGV[1] || "manual_cli_bless";
    let res = promote(reason);
    print(sprintf("%J\n", res));
    exit(res.success ? 0 : 1);
} else if (mode == "rollback" || mode == "restore") {
    let reason = ARGV[1] || "manual_cli_rollback";
    let res = rollback_to_known_good(reason);
    print(sprintf("%J\n", res));
    exit(res.success ? 0 : 1);
} else if (mode == "check" || mode == "check-observation") {
    let res = check_observation();
    print(sprintf("%J\n", res));
    exit(res.status == "failed" ? 1 : 0);
} else if (mode == "start" || mode == "start-observation") {
    let reason = ARGV[1] || "manual_cli_start";
    let win = ARGV[2] ? int(ARGV[2]) : 0;
    let res = start_observation(reason, win);
    print(sprintf("%J\n", res));
    exit(0);
}

return module_exports();
