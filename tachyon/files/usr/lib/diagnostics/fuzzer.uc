#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let fuzzer_runner = require("diagnostics.fuzzer_runner");
let history = require("diagnostics.fuzzer.history");
let binaries = require("diagnostics.fuzzer.binaries");
let probe = require("diagnostics.fuzzer.probe");
let targets = require("diagnostics.fuzzer.targets");
let strategies = require("diagnostics.fuzzer.strategies");
let ai = require("diagnostics.fuzzer.ai");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const STATE_FILE = STATE_DIR + "/fuzzer-state.json";
const PID_FILE = STATE_DIR + "/fuzzer-worker.pid";
const JOBS_DIR = STATE_DIR + "/fuzzer";
const HISTORY_FILE = "/etc/tachyon/fuzzer_history.json";
const BYEDPI_PORT = 11089;
const NFQUEUE_QNUM_ZAPRET = 298;
const NFQUEUE_QNUM_ZAPRET2 = 299;
const FUZZER_FWMARK = "0x40000000";
const FUZZER_OUTBOUND_MARK = getenv("NFT_OUTBOUND_MARK") || "0x08000000";
const JOB_HARD_DEADLINE_SECONDS = int(getenv("TACHYON_JOB_HARD_DEADLINE_SECONDS") || "2700");

function log_fuzzer_message(message, level) {
    level = as_string(level || "warn");
    command_success_from_args([ "logger", "-t", "tachyon", "[fuzzer] [" + level + "] " + as_string(message) ]);
}

function get_job_dir(job_id) { return history.get_job_dir(job_id); }

function ensure_job_dir(job_id) { return history.ensure_job_dir(job_id); }

// ── History Persistence ──────────────────────────────────────────────────────
function load_history() { return history.load_history(); }

function save_history(history) { return history.save_history(history); }

function append_history(entry) { return history.append_history(entry); }

function get_history(limit) { return history.get_history(limit); }

function resolve_binary(paths) { return binaries.resolve_binary(paths); }

function get_zapret2_bin() { return binaries.get_zapret2_bin(); }

function get_zapret_bin() { return binaries.get_zapret_bin(); }

function get_byedpi_bin() { return binaries.get_byedpi_bin(); }

function get_zapret2_lua_flags(args_str) { return binaries.get_zapret2_lua_flags(args_str); }

let _has_timeout = null;
function get_timeout_prefix(sec) { return binaries.get_timeout_prefix(sec); }

function wrap_cmd_timeout(cmd, sec, pid_file) { return binaries.wrap_cmd_timeout(cmd, sec, pid_file); }

// Shell watchdog: runs cmd bounded by sec seconds even when the `timeout`
// binary is unavailable. Blocking forever on system()/pipe.read() wedges the
// whole fuzzer worker (deadline checks in ucode never get to run), so every
// blocking call must carry a hard wall-clock bound.
const _WATCHDOG_SUBSHELL = "( %s & _bp=$!; ( sleep %d; kill -9 $_bp 2>/dev/null ) & _bw=$!; wait $_bp 2>/dev/null; kill $_bw 2>/dev/null; wait $_bw 2>/dev/null )";

function run_bounded(cmd, sec) { return binaries.run_bounded(cmd, sec); }

function wrap_probe_cmd(cmd, sec, pid_file) { return binaries.wrap_probe_cmd(cmd, sec, pid_file); }

let _fuzzer_curl_dns_flags = null;
function get_fuzzer_curl_dns_flags() { return binaries.get_fuzzer_curl_dns_flags(); }

let _fuzzer_host_cache = {};
function get_resolved_host_flags(url) { return binaries.get_resolved_host_flags(url); }

const KNOWN_BLOB_FILES = {
    tls_max: { file: "tls_clienthello_max_ru.bin", size: 654, desc: "Max.ru authentic ClientHello" },
    tls_google: { file: "tls_clienthello_www_google_com.bin", size: 681, desc: "Google authentic ClientHello" },
    tls_gosuslugi: { file: "tls_clienthello_gosuslugi_ru.bin", size: 517, desc: "Gosuslugi Russian Government ClientHello" },
    tls_sber: { file: "tls_clienthello_sberbank_ru.bin", size: 517, desc: "Sberbank authentic ClientHello" },
    tls_iana: { file: "tls_clienthello_iana_org.bin", size: 517, desc: "IANA root authority ClientHello" },
    tls_vk: { file: "tls_clienthello_vk_com.bin", size: 517, desc: "VK authentic ClientHello" },
    tls_onetrust: { file: "tls_clienthello_www_onetrust_com.bin", size: 664, desc: "OneTrust CDN ClientHello" },
    quic_google: { file: "quic_initial_www_google_com.bin", size: 1200, desc: "Google QUIC Initial" },
    quic_yt1: { file: "quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_1.bin", size: 1230, desc: "GoogleVideo Kyber QUIC Initial" },
    quic_vk: { file: "quic_initial_vk_com.bin", size: 1357, desc: "VK QUIC Initial" },
    stun_fake: { file: "stun.bin", size: 100, desc: "STUN discovery packet" },
    discord_udp: { file: "stun.bin", size: 100, desc: "Discord Voice UDP fake packet" }
};

function get_zapret2_blob_dir() { return binaries.get_zapret2_blob_dir(); }

function resolve_zapret2_blobs(args_str) { return binaries.resolve_zapret2_blobs(args_str); }

function setup_fuzzer_direct_nftables(qnum, is_udp) { return binaries.setup_fuzzer_direct_nftables(qnum, is_udp); }

function validate_strategy_args(engine, args_val) {
    return fuzzer_runner.validate_strategy_args(engine, args_val);
}

const PATTERNS_FILE = "/etc/tachyon/fuzzer_patterns.json";
const BUILTIN_PRESETS_FILE = getenv("TACHYON_PRESETS_FILE") || "/usr/share/tachyon/dpi-presets.json";
const USER_PRESETS_FILE = "/etc/tachyon/dpi-presets-user.json";

let _builtin_presets_cache = null;
let _preset_autoid = 0;

function presets_file_candidates() { return strategies.presets_file_candidates(); }

function load_presets_file(path) { return strategies.load_presets_file(path); }

function normalize_preset_entry(entry, engine) { return strategies.normalize_preset_entry(entry, engine); }

function load_builtin_presets() { return strategies.load_builtin_presets(); }

function reset_presets_cache() { return strategies.reset_presets_cache(); }

function preset_blobs_available(entry) { return strategies.preset_blobs_available(entry); }



function get_patterns_config() { return strategies.get_patterns_config(); }

function save_patterns_config(cfg_obj) { return strategies.save_patterns_config(cfg_obj); }

function reset_patterns_config() { return strategies.reset_patterns_config(); }

// Target Suites & Definitions


// Strategy Matrices (Expanded Elite Production Suite)




function generate_combinatorial_zapret2() { return strategies.generate_combinatorial_zapret2(); }

function generate_combinatorial_zapret() { return strategies.generate_combinatorial_zapret(); }

function generate_combinatorial_byedpi() { return strategies.generate_combinatorial_byedpi(); }

function generate_adaptive_strategies(engine, target) { return strategies.generate_adaptive_strategies(engine, target); }

function get_strategies_for_engine(engine, mode, target) { return strategies.get_strategies_for_engine(engine, mode, target); }

function resolve_target_url(target_key, custom_url) { return binaries.resolve_target_url(target_key, custom_url); }

function resolve_target_urls_list(target_key, custom_url) { return binaries.resolve_target_urls_list(target_key, custom_url); }

function ensure_state_dir() { return history.ensure_state_dir(); }

function save_fuzzer_state(state) { return history.save_fuzzer_state(state); }

function safe_json_parse(str) { return history.safe_json_parse(str); }

function query_llm(provider, api_key, custom_url, prompt_text, model_override) { return ai.query_llm(provider, api_key, custom_url, prompt_text, model_override); }

function parse_llm_json(raw_text) { return ai.parse_llm_json(raw_text); }


function get_fuzzer_state() { return history.get_fuzzer_state(); }

function kill_pid_file(path) { return probe.kill_pid_file(path); }

function cleanup_temp_daemons(job_id) { return probe.cleanup_temp_daemons(job_id); }

function parse_curl_output(output, result) { return probe.parse_curl_output(output, result); }

// ── DPI Type Detection ──────────────────────────────────────────────────────
// Probes the target without any bypass to determine how it's being blocked.
// Returns: { type: "rst"|"throttle"|"dns_block"|"ip_block"|"unknown"|"none",
//            confidence: 0-100, details: string, recommended_engines: string[] }
function detect_dpi_type(target_key, custom_url) { return targets.detect_dpi_type(target_key, custom_url); }


// ── Strategy Priority Reranking (based on DPI type) ─────────────────────────
function rerank_strategies_by_dpi(strategies, dpi_type) { return targets.rerank_strategies_by_dpi(strategies, dpi_type); }

function run_probe(engine, args_str, target_key, custom_url, job_id) { return probe.run_probe(engine, args_str, target_key, custom_url, job_id); }

function synthesize_ai_strategies(engine, target, custom_url, user_prompt) { return ai.synthesize_ai_strategies(engine, target, custom_url, user_prompt); }

function run_fuzzer_worker(engine, target, custom_url, rule_section, custom_file, mode, job_id) {
    if (job_id && job_id != "") {
        ensure_job_dir(job_id);
    }
    let target_url = resolve_target_url(target, custom_url);

    let state = get_fuzzer_state();
    if (!state.running || (job_id && state.job_id != job_id)) {
        state = {
            running: true,
            job_id: job_id || sprintf("fuzz_%d", clock()[0]),
            engine,
            target,
            target_url,
            mode: as_string(mode || "presets"),
            rule_section: as_string(rule_section),
            custom_file: as_string(custom_file || ""),
            progress_pct: 0,
            current_index: 0,
            total_strategies: 0,
            current_strategy: { name: "Initializing DPI detection...", args: "" },
            results: [],
            best_strategy: null,
            error: null,
            aborted: false,
            started_at: clock()[0],
            finished_at: 0,
            dpi_detection: null,
            phase: "detecting_dpi",
            stage: 1
        };
        save_fuzzer_state(state);
    }

    if (custom_url && custom_url != "" && !fuzzer_runner.is_valid_url(custom_url)) {
        state.running = false;
        state.error = "Invalid custom URL: malformed or forbidden characters";
        state.finished_at = clock()[0];
        save_fuzzer_state(state);
        cleanup_temp_daemons(state.job_id);
        return;
    }

    // ── Pre-fuzz DPI detection ────────────────────────────────────────────
    let dpi_detection = detect_dpi_type(target, custom_url);
    state.dpi_detection = dpi_detection;
    state.phase = "exploration";
    state.stage = 1;
    save_fuzzer_state(state);

    let strategies = null;
    if (custom_file && custom_file != "" && fs.stat(custom_file) != null) {
        strategies = common.read_json_file(custom_file);
    }
    if (!strategies || type(strategies) != "array" || length(strategies) == 0) {
        strategies = get_strategies_for_engine(engine, mode, target);
    }

    // Fail-closed re-validation of all candidate strategies before benchmarking
    let validated_strategies = [];
    for (let s in strategies) {
        if (s && s.args && fuzzer_runner.validate_strategy_args(s.engine || engine, s.args)) {
            push(validated_strategies, s);
        }
    }
    strategies = validated_strategies;
    if (length(strategies) == 0) {
        state.running = false;
        state.error = "No valid strategies found to benchmark";
        state.finished_at = clock()[0];
        save_fuzzer_state(state);
        cleanup_temp_daemons(state.job_id);
        return;
    }

    // Rerank strategies based on detected DPI type
    strategies = rerank_strategies_by_dpi(strategies, dpi_detection);

    let total = length(strategies);
    state.total_strategies = total;
    save_fuzzer_state(state);
    
    try {
        let highest_score = -1;
        let best = null;
        let working_count = 0;
        let consecutive_plateau = 0;
        
        // ── Stage 1: Exploration (Single-probe scan) ──────────────────────
        for (let i = 0; i < total; i++) {
            let strat = strategies[i];
            state.current_index = i + 1;
            state.current_strategy = strat;
            state.progress_pct = int(((i) / (1.0 * total)) * 70.0);
            save_fuzzer_state(state);

            let elapsed = clock()[0] - state.started_at;
            if (elapsed > JOB_HARD_DEADLINE_SECONDS) {
                state.running = false;
                state.error = sprintf("Hard deadline reached (%ds). Tested %d/%d strategies.", JOB_HARD_DEADLINE_SECONDS, i, total);
                state.finished_at = clock()[0];
                save_fuzzer_state(state);
                cleanup_temp_daemons(state.job_id);
                return;
            }

            let probe = null;
            try {
                probe = run_probe(strat.engine || engine, strat.args, target, custom_url, state.job_id);
            } catch (err) {
                cleanup_temp_daemons(state.job_id);
                probe = {
                    success: false,
                    http_code: 0,
                    handshake_ms: 0,
                    ttfb_ms: 0,
                    speed_kbps: 0,
                    data_bytes: 0,
                    data_verified: false,
                    dpi_verdict: "failed",
                    score: 0,
                    error: sprintf("Probe error: %s", err),
                    sub_probes: []
                };
            }
            
            let item_result = {
                id: strat.id || sprintf("strat_%d", i + 1),
                name: strat.name || sprintf("Strategy %d", i + 1),
                engine: strat.engine || engine,
                args: strat.args,
                description: strat.description || "",
                rationale: strat.rationale || "",
                source: strat.source || "",
                tags: type(strat.tags) == "array" ? strat.tags : [],
                success: probe.success,
                http_code: probe.http_code,
                handshake_ms: probe.handshake_ms,
                ttfb_ms: probe.ttfb_ms,
                speed_kbps: probe.speed_kbps,
                data_bytes: probe.data_bytes || 0,
                data_verified: probe.data_verified || false,
                dpi_verdict: probe.dpi_verdict || "unknown",
                score: probe.score,
                error: probe.error,
                sub_probes: probe.sub_probes || [],
                stability_pct: probe.success ? 100 : 0,
                reps: 1,
                jitter_ms: 0,
                confidence: probe.success ? "preliminary" : "none",
                badge: ""
            };
            
            if (item_result.success) {
                working_count++;
                if (item_result.score > highest_score) {
                    highest_score = item_result.score;
                    best = item_result;
                    consecutive_plateau = 0;
                } else {
                    consecutive_plateau++;
                }
            } else if (working_count > 0) {
                consecutive_plateau++;
            }
            
            push(state.results, item_result);
            state.progress_pct = int(((i + 1) / (1.0 * total)) * 70.0);
            save_fuzzer_state(state);

            // Adaptive mode early plateau detection
            if (mode == "adaptive" && consecutive_plateau >= 8 && working_count >= 2) {
                break;
            }
        }

        // ── Stage 2: Verification (3 Repetitions on Top Candidates) ────────
        let working_candidates = [];
        for (let r in state.results) {
            if (r && r.success === true) push(working_candidates, r);
        }
        sort(working_candidates, function(a, b) { return b.score - a.score; });

        let avail_kb = fuzzer_runner.get_system_memory_kb();
        let max_verify = (avail_kb < 32768) ? 3 : 5;
        let num_verify = length(working_candidates) < max_verify ? length(working_candidates) : max_verify;

        if (num_verify > 0) {
            state.phase = "verification";
            state.stage = 2;
            save_fuzzer_state(state);

            for (let v_idx = 0; v_idx < num_verify; v_idx++) {
                let cand = working_candidates[v_idx];
                state.current_strategy = {
                    name: sprintf("[Stage 2: verifying %d/%d] %s", v_idx + 1, num_verify, cand.name),
                    args: cand.args
                };
                state.progress_pct = 70 + int(((v_idx) / (1.0 * num_verify)) * 30.0);
                save_fuzzer_state(state);

                let elapsed = clock()[0] - state.started_at;
                if (elapsed > JOB_HARD_DEADLINE_SECONDS) {
                    break;
                }

                let rep_ttfb = [];
                let rep_speed = [];
                let rep_handshake = [];
                let rep_bytes = [];
                let rep_success = 0;

                for (let rep = 0; rep < 3; rep++) {
                    let p = null;
                    try {
                        p = run_probe(cand.engine || engine, cand.args, target, custom_url, state.job_id);
                    } catch (e) {
                        cleanup_temp_daemons(state.job_id);
                    }
                    if (p && p.success) {
                        rep_success++;
                        push(rep_ttfb, p.ttfb_ms);
                        push(rep_speed, p.speed_kbps);
                        push(rep_handshake, p.handshake_ms);
                        push(rep_bytes, p.data_bytes || 0);
                    }
                }

                let stability_pct = int((rep_success / 3.0) * 100);
                cand.verified = true;
                cand.reps = 3;
                cand.stability_pct = stability_pct;

                if (rep_success > 0) {
                    let med_ttfb = fuzzer_runner.calculate_median(rep_ttfb);
                    let jitter_ms = fuzzer_runner.calculate_jitter(rep_ttfb, med_ttfb);
                    let p25_speed = fuzzer_runner.calculate_p25(rep_speed);
                    let med_bytes = fuzzer_runner.calculate_median(rep_bytes);
                    let data_verified = (med_bytes >= 32768);

                    cand.ttfb_ms = med_ttfb;
                    cand.jitter_ms = jitter_ms;
                    cand.speed_kbps = fuzzer_runner.calculate_median(rep_speed);
                    cand.p25_speed_kbps = p25_speed;
                    cand.data_bytes = med_bytes;
                    cand.data_verified = data_verified;

                    let conf = "low";
                    if (stability_pct == 100 && jitter_ms <= 80) conf = "high";
                    else if (stability_pct >= 66 && jitter_ms <= 200) conf = "medium";
                    cand.confidence = conf;

                    // Composite Stage 2 Score: Stability (0-400) + Latency (0-300) + Speed p25 (0-150) + Data (20-50)
                    cand.score = int((stability_pct * 4.0) + (max(0, 1000 - med_ttfb) * 0.3) + (min(500, int(p25_speed / 10.0)) * 0.3) + (data_verified ? 50 : 20));
                } else {
                    cand.score = 0;
                    cand.success = false;
                    cand.confidence = "low";
                    cand.jitter_ms = 0;
                    cand.p25_speed_kbps = 0;
                    cand.error = "Failed all 3 verification repetitions (unstable connection)";
                }

                for (let r_i = 0; r_i < length(state.results); r_i++) {
                    if (state.results[r_i].id == cand.id) {
                        state.results[r_i] = cand;
                        break;
                    }
                }
                save_fuzzer_state(state);
            }
        }
        
        // ── Assign Badges based on verified results ────────────────────────
        let best_verified = null;
        let highest_vscore = -1;
        for (let r in state.results) {
            if (r.success && r.score > highest_vscore) {
                highest_vscore = r.score;
                best_verified = r;
            }
        }
        if (best_verified) {
            best_verified.badge = "🏆 Best Match";
            state.best_strategy = best_verified;
        }
        
        let min_ttfb = 999999;
        let fastest = null;
        let lowest_jitter = 999999;
        let most_stable = null;

        for (let r in state.results) {
            if (r.success && r.stability_pct == 100) {
                if (r.ttfb_ms > 0 && r.ttfb_ms < min_ttfb) {
                    min_ttfb = r.ttfb_ms;
                    fastest = r;
                }
                if (r.jitter_ms !== null && r.jitter_ms < lowest_jitter) {
                    lowest_jitter = r.jitter_ms;
                    most_stable = r;
                }
            }
        }
        if (fastest && fastest.id != (best_verified ? best_verified.id : "")) {
            fastest.badge = "⚡ Ultra Fast";
        }
        if (most_stable && most_stable.id != (best_verified ? best_verified.id : "") && (!fastest || most_stable.id != fastest.id)) {
            most_stable.badge = "🛡️ Bulletproof";
        }
        
        state.running = false;
        state.stage = 2;
        state.phase = "finished";
        state.current_strategy = null;
        state.progress_pct = 100;
        state.finished_at = clock()[0];
        save_fuzzer_state(state);

        // ── Persist to history ────────────────────────────────────────────
        let duration = state.finished_at - state.started_at;
        append_history({
            timestamp: state.finished_at,
            engine: engine,
            target: target,
            mode: mode,
            best_strategy: state.best_strategy ? {
                id: state.best_strategy.id,
                name: state.best_strategy.name,
                engine: state.best_strategy.engine,
                args: state.best_strategy.args,
                score: state.best_strategy.score,
                ttfb_ms: state.best_strategy.ttfb_ms,
                speed_kbps: state.best_strategy.speed_kbps,
                stability_pct: state.best_strategy.stability_pct,
                confidence: state.best_strategy.confidence
            } : null,
            total_tested: total,
            working_count: working_count,
            dpi_detection: dpi_detection,
            duration_sec: int(duration)
        });
    } catch (err) {
        state.running = false;
        state.phase = "finished";
        state.current_strategy = null;
        state.error = as_string(err);
        state.finished_at = clock()[0];
        if (!state.best_strategy && state.results) {
            let max_score = -1;
            let best_item = null;
            for (let r in state.results) {
                if (r.success && r.score > max_score) {
                    max_score = r.score;
                    best_item = r;
                }
            }
            if (best_item) {
                best_item.badge = "🏆 Best Match";
                state.best_strategy = best_item;
            }
        }
        save_fuzzer_state(state);
    }
    
    cleanup_temp_daemons(state.job_id);
}

function stop_fuzzer(quiet) {
    let state = get_fuzzer_state();
    let job_id = state ? state.job_id : null;
    let job_dir = get_job_dir(job_id);
    if (job_dir) {
        kill_pid_file(job_dir + "/worker.pid");
    }
    kill_pid_file(PID_FILE);
    cleanup_temp_daemons(job_id);
    
    state.running = false;
    state.aborted = true;
    state.phase = "finished";
    state.current_strategy = null;
    state.error = "Stopped by user";
    state.finished_at = clock()[0];
    if (!state.best_strategy && state.results) {
        let max_score = -1;
        let best_item = null;
        for (let r in state.results) {
            if (r.success && r.score > max_score) {
                max_score = r.score;
                best_item = r;
            }
        }
        if (best_item) {
            best_item.badge = "🏆 Best Match";
            state.best_strategy = best_item;
        }
    }
    save_fuzzer_state(state);
    
    if (!quiet)
        print(sprintf("%J\n", { success: true, message: "Fuzzer stopped" }));
}

function start_fuzzer(engine, target, custom_url, rule_section, custom_file, mode, timeout_seconds) {
    let current = get_fuzzer_state();
    if (current.running) {
        stop_fuzzer(true);
        system("sleep 0.25");
    }
    
    if (custom_url && custom_url != "") {
        let urls = split(custom_url, /[,\n]+/);
        for (let u in urls) {
            let trimmed = trim(as_string(u));
            if (trimmed != "" && !fuzzer_runner.is_valid_url(trimmed)) {
                print(sprintf("%J\n", { success: false, error: sprintf("Invalid custom URL: '%s' is malformed or contains forbidden characters", trimmed) }));
                return;
            }
        }
    }

    ensure_state_dir();
    let job_id = sprintf("fuzz_%d", clock()[0]);
    ensure_job_dir(job_id);
    cleanup_temp_daemons(job_id);

    // Immediately write starting state to prevent race conditions during frontend polling
    let state = {
        running: true,
        job_id: job_id,
        engine: engine || "zapret2",
        target: target || "youtube_suite",
        target_url: resolve_target_url(target, custom_url),
        mode: as_string(mode || "presets"),
        rule_section: as_string(rule_section),
        custom_file: as_string(custom_file || ""),
        progress_pct: 0,
        current_index: 0,
        total_strategies: 0,
        current_strategy: { name: "Initializing DPI detection...", args: "" },
        results: [],
        best_strategy: null,
        error: null,
        aborted: false,
        started_at: clock()[0],
        finished_at: 0,
        dpi_detection: null,
        phase: "detecting_dpi",
        stage: 1
    };
    save_fuzzer_state(state);
    
    let fuzzer_bin = LIB_DIR + "/diagnostics/fuzzer.uc";
    if (fs.stat(fuzzer_bin) == null) fuzzer_bin = "/usr/lib/tachyon/diagnostics/fuzzer.uc";

    let deadline_override = int(timeout_seconds) || JOB_HARD_DEADLINE_SECONDS;
    let deadline_env = sprintf("TACHYON_JOB_HARD_DEADLINE_SECONDS=%d", deadline_override);
    let cmd = sprintf(
        "%s ucode -L %s %s worker %s %s %s %s %s %s %s",
        deadline_env,
        shell_quote(LIB_DIR),
        shell_quote(fuzzer_bin),
        shell_quote(engine || "zapret2"),
        shell_quote(target || "youtube_suite"),
        shell_quote(custom_url || ""),
        shell_quote(rule_section || ""),
        shell_quote(custom_file || ""),
        shell_quote(mode || "presets"),
        shell_quote(job_id)
    );
    
    let job_worker_pid = get_job_dir(job_id) + "/worker.pid";
    system(common.background_command_with_pid(cmd, ">/dev/null", ">" + shell_quote(PID_FILE) + " && cp " + shell_quote(PID_FILE) + " " + shell_quote(job_worker_pid) + " 2>/dev/null"));
    
    print(sprintf("%J\n", { success: true, job_id, engine: engine || "zapret2", target: target || "youtube_suite", mode: mode || "presets" }));
}

function get_available_engines() {
    return {
        zapret2: get_zapret2_bin() != null,
        zapret: get_zapret_bin() != null,
        byedpi: get_byedpi_bin() != null
    };
}

function normalize_strategy_for_uci(engine, args_val) {
    args_val = trim(as_string(args_val));
    if (engine == "zapret2") {
        let blob_defs = resolve_zapret2_blobs(args_val);
        if (blob_defs != "") {
            args_val = trim(blob_defs) + " " + args_val;
        }
    }
    return args_val;
}

function apply_strategy(engine, args_val, target_rule) {
    engine = lc(as_string(engine));
    args_val = trim(as_string(args_val));
    target_rule = trim(as_string(target_rule));
    
    if (args_val == "") {
        print(sprintf("%J\n", { success: false, error: "Empty strategy arguments" }));
        return;
    }
    
    if (!fuzzer_runner.validate_strategy_args(engine, args_val)) {
        print(sprintf("%J\n", { success: false, error: "Cannot apply invalid or insecure strategy arguments" }));
        return;
    }

    args_val = normalize_strategy_for_uci(engine, args_val);
    
    let uci = uci_core.cursor();
    let applied = false;
    
    if (target_rule != "" && target_rule != "global") {
        if (engine == "zapret2")
            uci.set(CONFIG_NAME, target_rule, "nfqws2_opt", args_val);
        else if (engine == "zapret")
            uci.set(CONFIG_NAME, target_rule, "nfqws_opt", args_val);
        else if (engine == "byedpi")
            uci.set(CONFIG_NAME, target_rule, "byedpi_cmd_opts", args_val);
        applied = true;
    } else {
        let provider_sec = engine;
        let sec_obj = uci.get_all(CONFIG_NAME, provider_sec);
        if (sec_obj == null) {
            uci.set(CONFIG_NAME, provider_sec, "provider");
        }
        uci.set(CONFIG_NAME, provider_sec, "enabled", "1");
        if (engine == "zapret2")
            uci.set(CONFIG_NAME, provider_sec, "nfqws2_opt", args_val);
        else if (engine == "zapret")
            uci.set(CONFIG_NAME, provider_sec, "nfqws_opt", args_val);
        else if (engine == "byedpi")
            uci.set(CONFIG_NAME, provider_sec, "byedpi_cmd_opts", args_val);
        applied = true;
    }
    
    uci.commit(CONFIG_NAME);
    system(common.background_command("tachyon reload"));
    
    print(sprintf("%J\n", {
        success: true,
        engine,
        applied_to: target_rule != "" ? target_rule : "global",
        args: args_val
    }));
}

function auto_apply_best(target_rule) {
    let state = get_fuzzer_state();
    if (state.aborted) {
        print(sprintf("%J\n", { success: false, error: "Cannot auto-apply: benchmark was stopped manually" }));
        return;
    }
    if (state.progress_pct < 100) {
        print(sprintf("%J\n", { success: false, error: "Cannot auto-apply: benchmark did not complete 100%" }));
        return;
    }
    if (!state.best_strategy || state.best_strategy.score <= 0) {
        print(sprintf("%J\n", { success: false, error: "No winning strategy found — run a benchmark first" }));
        return;
    }
    let best = state.best_strategy;
    apply_strategy(best.engine, best.args, target_rule);
}

function clear_history() { return history.clear_history(); }

function get_presets_info() { return strategies.get_presets_info(); }


function update_presets() { return strategies.update_presets(); }

// CLI Dispatcher
let op = ARGV[0] || "status";

if (op == "start") {
    start_fuzzer(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
} else if (op == "worker") {
    run_fuzzer_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
} else if (op == "status") {
    print(sprintf("%J\n", get_fuzzer_state()));
} else if (op == "stop") {
    stop_fuzzer();
} else if (op == "apply") {
    apply_strategy(ARGV[1], ARGV[2], ARGV[3]);
} else if (op == "get_patterns" || op == "patterns") {
    print(sprintf("%J\n", { success: true, patterns: get_patterns_config() }));
} else if (op == "save_patterns") {
    let cfg = safe_json_parse(ARGV[1]);
    save_patterns_config(cfg);
} else if (op == "reset_patterns") {
    reset_patterns_config();
} else if (op == "ai_synthesize" || op == "synthesize") {
    synthesize_ai_strategies(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
} else if (op == "detect_dpi") {
    let detection = detect_dpi_type(ARGV[1], ARGV[2]);
    print(sprintf("%J\n", detection));
} else if (op == "auto_apply") {
    auto_apply_best(ARGV[1]);
} else if (op == "history") {
    let entries = get_history(ARGV[1]);
    print(sprintf("%J\n", { success: true, entries: entries }));
} else if (op == "clear_history") {
    clear_history();
} else if (op == "generate" || op == "strategies_generate") {
    print(sprintf("%J\n", get_strategies_for_engine(ARGV[1], ARGV[2] || "combinatorial")));
} else if (op == "strategies") {
    let strat_mode = ARGV[1] || "presets";
    print(sprintf("%J\n", {
        available_engines: get_available_engines(),
        target_suites: binaries.TARGET_SUITES,
        patterns: get_patterns_config(),
        zapret2: get_strategies_for_engine("zapret2", strat_mode),
        zapret: get_strategies_for_engine("zapret", strat_mode),
        byedpi: get_strategies_for_engine("byedpi", strat_mode)
    }));
} else if (op == "presets_info") {
    print(sprintf("%J\n", get_presets_info()));
} else if (op == "update_presets") {
    update_presets();
} else if (op == "probe") {
    let r = run_probe(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
    print(sprintf("%J\n", r));
} else {
    warn("Usage: fuzzer.uc [start|status|stop|apply|strategies|generate|get_patterns|save_patterns|reset_patterns|ai_synthesize|detect_dpi|auto_apply|history|clear_history|presets_info|update_presets|worker|probe] ...\n");
    exit(1);
}

