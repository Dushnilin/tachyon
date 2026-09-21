#!/usr/bin/env ucode
//
// Fuzzer probe execution.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split). Owns the
// per-strategy probe: spawning the engine, running curl through the probe
// nftables table, parsing metrics and cleaning up daemons.
//

let fs = require("fs");
let common = require("core.common");
let fuzzer_runner = require("diagnostics.fuzzer_runner");
let binaries = require("diagnostics.fuzzer.binaries");
let history = require("diagnostics.fuzzer.history");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;

const STATE_DIR = history.STATE_DIR;
const BYEDPI_PORT = 11089;
const JOB_HARD_DEADLINE_SECONDS = int(getenv("TACHYON_JOB_HARD_DEADLINE_SECONDS") || "2700");

function kill_pid_file(path) {
    fuzzer_runner.kill_pid_file(path);
}

function cleanup_temp_daemons(job_id) {
    if (job_id) {
        let job_dir = history.get_job_dir(job_id);
        if (job_dir) {
            kill_pid_file(job_dir + "/engine.pid");
            kill_pid_file(job_dir + "/probe.pid");
        }
    }
    kill_pid_file(STATE_DIR + "/fuzzer_byedpi.pid");
    kill_pid_file(STATE_DIR + "/fuzzer_zapret.pid");
    kill_pid_file(STATE_DIR + "/fuzzer_zapret2.pid");
    kill_pid_file(STATE_DIR + "/fuzzer_probe.pid");

    // Directly parse /proc/net/netfilter/nfnetlink_queue to terminate any process bound to fuzzer queues
    for (let w = 0; w < 5; w++) {
        let nfq = fs.readfile("/proc/net/netfilter/nfnetlink_queue");
        let found = false;
        if (nfq) {
            let lines = split(trim(nfq), "\n");
            for (let line in lines) {
                let cols = split(trim(line), /[ \t]+/);
                if (length(cols) >= 2) {
                    let q = int(cols[0]);
                    let p = int(cols[1]);
                    if ((q == binaries.NFQUEUE_QNUM_ZAPRET || q == binaries.NFQUEUE_QNUM_ZAPRET2) && p > 0) {
                        found = true;
                        system(sprintf("kill -9 %d >/dev/null 2>&1", p));
                    }
                }
            }
        }
        if (!found) break;
        system("sleep 0.1");
    }

    // Terminate any stray nfqws / nfqws2 / ciadpi fuzzer daemons
    let self_pid = fs.readlink("/proc/self");
    let procs = fs.glob("/proc/[0-9]*");
    if (procs) {
        for (let p_dir in procs) {
            let p_id = replace(p_dir, "/proc/", "");
            if (p_id != self_pid) {
                let cmdline = fs.readfile(p_dir + "/cmdline");
                if (cmdline && (index(cmdline, "nfqws") >= 0 || index(cmdline, "ciadpi") >= 0)) {
                    if (index(cmdline, "qnum=298") >= 0 || index(cmdline, "qnum=299") >= 0 || index(cmdline, "11089") >= 0) {
                        system(sprintf("kill -9 %s >/dev/null 2>&1", p_id));
                    }
                }
            }
        }
    }

    // Ensure ByeDPI port is released (hard-bounded to avoid hangs)
    binaries.run_bounded(sprintf("fuser -k %d/tcp >/dev/null 2>&1", BYEDPI_PORT), 3);

    // Notice: global kill of curl processes removed to avoid killing external curl operations

    // nft delete can block in-kernel on an orphaned nfqueue binding left by a killed
    // daemon; without the bound it wedges the ucode interpreter permanently.
    // 10s is generous enough for slow ARM routers to flush orphaned queue bindings.
    binaries.run_bounded("nft delete table inet tachyon_fuzzer >/dev/null 2>&1", 10);
    try { fs.unlink(STATE_DIR + "/fuzzer_daemon_err.log"); } catch (e) {}
}

function parse_curl_output(output, result) {
    result = result || {};
    output = trim(as_string(output));
    if (output == "") {
        result.success = false;
        result.http_code = 0;
        result.handshake_ms = 0;
        result.ttfb_ms = 0;
        result.speed_kbps = 0;
        result.data_bytes = 0;
        result.data_verified = false;
        result.dpi_verdict = "timeout";
        result.score = 0;
        result.error = "Probe timeout or connection refused";
        return result;
    }
    
    // In case there are multiple lines (e.g. warnings or messages), find the tab-delimited metrics line
    let lines = split(output, "\n");
    let target_line = "";
    for (let l in lines) {
        let tl = trim(l);
        if (index(tl, "\t") >= 0) {
            target_line = tl;
            break;
        }
    }
    if (target_line == "") target_line = trim(lines[length(lines) - 1]);

    let parts = split(target_line, "\t");
    if (length(parts) < 4) {
        result.success = false;
        result.http_code = 0;
        result.score = 0;
        result.data_bytes = 0;
        result.data_verified = false;
        result.dpi_verdict = "malformed";
        result.error = "Malformed probe metrics output";
        return result;
    }
    
    let http_code = int(parts[0]);
    let appconnect = 1.0 * parts[1];
    let starttransfer = 1.0 * parts[2];
    let speed_bytes = 1.0 * parts[3];
    let size_download = length(parts) >= 5 ? int(parts[4]) : 0;
    let exit_code = length(parts) >= 6 ? int(parts[5]) : 0;
    
    result.http_code = http_code;
    result.handshake_ms = int(appconnect * 1000.0);
    result.ttfb_ms = int(starttransfer * 1000.0);
    result.speed_kbps = int(speed_bytes / 1024.0);
    result.data_bytes = size_download;

    // Check for HTTP 400 (Server Receives Fakes - desync corruption)
    if (http_code == 400) {
        result.success = false;
        result.score = 0;
        result.data_verified = false;
        result.dpi_verdict = "server_fakes";
        result.error = "HTTP 400 (Remote server rejected corrupted/fake packet payload)";
        return result;
    }

    // Check for 16KB DPI Throttling (TSPU stream drop / connection reset after 10-28KB)
    if (exit_code != 0 && size_download >= 10240 && size_download <= 28672) {
        result.success = false;
        result.score = 0;
        result.data_verified = false;
        result.dpi_verdict = "throttled_16k";
        result.error = sprintf("16KB DPI Data Throttle (stream killed after %d B, curl exit %d)", size_download, exit_code);
        return result;
    }

    if (exit_code != 0 && http_code == 0) {
        result.success = false;
        result.score = 0;
        result.data_verified = false;
        result.dpi_verdict = "dropped";
        result.error = sprintf("Connection dropped by DPI (curl exit %d)", exit_code);
        return result;
    }

    if (exit_code != 0 && http_code >= 200 && http_code < 400) {
        result.success = false;
        result.score = 0;
        result.data_verified = false;
        result.dpi_verdict = "transfer_failed";
        result.error = sprintf("Data transfer aborted after %d B (curl exit %d)", size_download, exit_code);
        return result;
    }
    
    // Any valid HTTP response from origin (including 401/403/404/405 when hitting endpoints without auth headers)
    if ((http_code >= 200 && http_code < 400) || http_code == 401 || http_code == 403 || http_code == 404 || http_code == 405) {
        result.success = true;
        let base_score = (http_code >= 200 && http_code < 400) ? 100 : 85;
        let latency_score = max(0, 1000 - result.ttfb_ms);
        let speed_score = int(result.speed_kbps / 10.0);
        let data_bonus = size_download >= 32768 ? 50 : (size_download >= 1024 ? 20 : 0);
        result.score = base_score + latency_score + speed_score + data_bonus;
        result.error = "";
        result.data_verified = size_download >= 32768;
        result.dpi_verdict = size_download >= 32768 ? "verified_32k" : "available";
    } else {
        result.success = false;
        result.score = 0;
        result.data_verified = false;
        result.dpi_verdict = "failed";
        result.error = http_code > 0 ? sprintf("HTTP Status %d", http_code) : "Connection dropped by DPI";
    }
    
    return result;
}

function run_probe(engine, args_str, target_key, custom_url, job_id) {
    cleanup_temp_daemons(job_id);
    if (job_id && job_id != "") {
        history.ensure_job_dir(job_id);
    }
    let job_dir = history.get_job_dir(job_id);
    let probe_pid_path = job_dir ? (job_dir + "/probe.pid") : (STATE_DIR + "/fuzzer_probe.pid");
    try { fs.unlink(probe_pid_path); } catch (e) {}
    
    let urls_list = binaries.resolve_target_urls_list(target_key, custom_url);
    let total_urls = length(urls_list);
    let caps = fuzzer_runner.get_system_capabilities();
    
    let result = {
        success: false,
        http_code: 0,
        handshake_ms: 0,
        ttfb_ms: 0,
        speed_kbps: 0,
        score: 0,
        error: "",
        sub_probes: []
    };
    
    engine = lc(as_string(engine));
    let is_udp = index(args_str, "--filter-udp") >= 0 || index(args_str, "--dpi-desync-any-protocol") >= 0 || target_key == "quic_http3";
    
    let tok_res = fuzzer_runner.tokenize_strategy_args(args_str);
    if (!tok_res.valid) {
        result.error = "Invalid strategy arguments: " + tok_res.error;
        return result;
    }

    if (engine == "byedpi") {
        let bin = binaries.get_byedpi_bin();
        if (!bin) {
            result.error = "ByeDPI binary not found";
            return result;
        }
        
        let pid_path = job_dir ? (job_dir + "/engine.pid") : (STATE_DIR + "/fuzzer_byedpi.pid");
        let stderr_log = job_dir ? (job_dir + "/daemon_err.log") : (STATE_DIR + "/fuzzer_daemon_err.log");
        try { fs.unlink(pid_path); } catch (e) {}
        try { fs.unlink(stderr_log); } catch (e) {}
        
        let argv = fuzzer_runner.build_byedpi_argv(bin, BYEDPI_PORT, tok_res.tokens);
        let spawn_cmd = "cd /tmp && " + common.command_from_args(argv) + " 2>" + shell_quote(stderr_log);
        system(common.background_command_with_pid(spawn_cmd, ">/dev/null", ">" + shell_quote(pid_path)));
        
        let pid_running = false;
        for (let wait_i = 0; wait_i < 15; wait_i++) {
            system("sleep 0.1");
            let pid_str = fs.readfile(pid_path);
            if (pid_str) {
                let pid = trim(as_string(pid_str));
                if (pid != "" && match(pid, /^[0-9]+$/) != null && system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) == 0) {
                    pid_running = true;
                    break;
                }
            }
        }
        
        if (!pid_running) {
            let err_content = fs.readfile(stderr_log);
            let err_msg = err_content ? trim(as_string(err_content)) : "";
            if (err_msg != "") {
                let first_line = split(err_msg, "\n")[0];
                result.error = sprintf("Daemon failed to start: %s", first_line);
            } else {
                result.error = "ByeDPI daemon failed to start (invalid arguments)";
            }
            cleanup_temp_daemons(job_id);
            return result;
        }
        
        // Ensure ciadpi direct outbound connections bypass Sing-Box TProxy
        system("nft add table inet tachyon_fuzzer 2>/dev/null");
        system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
        system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443 } meta mark set meta mark | %s counter' 2>/dev/null", FUZZER_OUTBOUND_MARK));
        
        let passed_count = 0;
        let max_speed = 0;
        let sum_data_bytes = 0;
        let all_data_verified = true;
        let last_http = 0;
        let last_dpi_verdict = "available";
        let required_failed = false;
        
        for (let target_item in urls_list) {
            let is_req = (target_item.required !== false);
            let p_kind = target_item.probe_kind || "tls_http";
            let extra_flags = "";

            if (p_kind == "quic" || target_key == "quic_http3") {
                if (!caps.http3) {
                    let single_res = {
                        target_name: target_item.name,
                        url: target_item.url,
                        required: is_req,
                        weight: target_item.weight || 100,
                        http_code: 0,
                        handshake_ms: 0,
                        ttfb_ms: 0,
                        speed_kbps: 0,
                        data_bytes: 0,
                        data_verified: false,
                        dpi_verdict: "unsupported_proto",
                        score: 0,
                        success: false,
                        error: "HTTP/3 (QUIC) not supported by router curl binary"
                    };
                    push(result.sub_probes, single_res);
                    if (is_req) { required_failed = true; result.error = single_res.error; }
                    break;
                }
                extra_flags = "--http3-only ";
            } else if (p_kind == "streaming") {
                extra_flags = "-r 0-65535 ";
            }

            let curl_cmd = binaries.wrap_probe_cmd(
                sprintf(
                    "curl %s-x socks5h://127.0.0.1:%d -so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}\\t%%{size_download}' -L --connect-timeout 4 --max-time 6 %s 2>/dev/null; printf '\\t%%d\\n' $?",
                    extra_flags,
                    BYEDPI_PORT,
                    shell_quote(target_item.url)
                ),
                8,
                probe_pid_path
            );
            let pipe = fs.popen(curl_cmd, "r");
            let output = pipe ? pipe.read("all") : "";
            if (pipe) pipe.close();
            try { fs.unlink(probe_pid_path); } catch (e) {}
            
            let single_res = parse_curl_output(output, {});
            single_res.target_name = target_item.name;
            single_res.url = target_item.url;
            single_res.required = is_req;
            single_res.weight = target_item.weight || 100;
            push(result.sub_probes, single_res);
            
            if (single_res.success) {
                passed_count++;
                sum_data_bytes += single_res.data_bytes || 0;
                if (!single_res.data_verified) all_data_verified = false;
                if (single_res.speed_kbps > max_speed) max_speed = single_res.speed_kbps;
                last_http = single_res.http_code;
                last_dpi_verdict = single_res.dpi_verdict || "available";
            } else {
                all_data_verified = false;
                if (last_http == 0) last_http = single_res.http_code;
                if (single_res.error && result.error == "") result.error = single_res.error;
                last_dpi_verdict = single_res.dpi_verdict || "failed";
                if (is_req) {
                    required_failed = true;
                    break;
                }
            }
        }
        
        cleanup_temp_daemons(job_id);
        
        if (required_failed || passed_count == 0) {
            result.success = false;
            result.http_code = last_http;
            result.data_bytes = sum_data_bytes;
            result.data_verified = false;
            result.dpi_verdict = last_dpi_verdict;
            result.score = 0;
            if (result.error == "") {
                result.error = sprintf("Required endpoint failed (%d of %d endpoints passed)", passed_count, total_urls);
            }
        } else {
            result.success = true;
            result.http_code = last_http > 0 ? last_http : 200;
            result.speed_kbps = max_speed;
            result.data_bytes = int(sum_data_bytes / (1.0 * total_urls));
            result.data_verified = all_data_verified;
            result.dpi_verdict = all_data_verified ? "verified_32k" : last_dpi_verdict;
            result.error = "";

            let total_w = 0;
            let weighted_score = 0.0;
            let weighted_ttfb = 0.0;
            let weighted_hs = 0.0;
            for (let sp in result.sub_probes) {
                let w = sp.weight || 10;
                total_w += w;
                weighted_score += (sp.score * w);
                weighted_ttfb += (sp.ttfb_ms * w);
                weighted_hs += (sp.handshake_ms * w);
            }
            result.score = total_w > 0 ? int(weighted_score / (1.0 * total_w)) : 0;
            result.ttfb_ms = total_w > 0 ? int(weighted_ttfb / (1.0 * total_w)) : 0;
            result.handshake_ms = total_w > 0 ? int(weighted_hs / (1.0 * total_w)) : 0;
        }
        
        return result;
    }
    
    if (engine == "zapret" || engine == "zapret2") {
        cleanup_temp_daemons(job_id);
        let is_z2 = engine == "zapret2";
        let bin = is_z2 ? binaries.get_zapret2_bin() : binaries.get_zapret_bin();
        let qnum = is_z2 ? binaries.NFQUEUE_QNUM_ZAPRET2 : binaries.NFQUEUE_QNUM_ZAPRET;
        let pid_path = job_dir ? (job_dir + "/engine.pid") : (is_z2 ? (STATE_DIR + "/fuzzer_zapret2.pid") : (STATE_DIR + "/fuzzer_zapret.pid"));
        let stderr_log = job_dir ? (job_dir + "/daemon_err.log") : (STATE_DIR + "/fuzzer_daemon_err.log");
        try { fs.unlink(pid_path); } catch (e) {}
        try { fs.unlink(stderr_log); } catch (e) {}
        
        if (!bin) {
            result.error = (is_z2 ? "Zapret v2" : "Zapret v1") + " binary not found";
            return result;
        }
        
        let lua_init_flags = "";
        let blob_flags = "";
        if (is_z2) {
            lua_init_flags = binaries.get_zapret2_lua_flags(args_str);
            blob_flags = binaries.resolve_zapret2_blobs(args_str);
            if (index(args_str, "--lua-desync") >= 0 && lua_init_flags == "" && index(args_str, "--lua-init") < 0) {
                result.error = "Missing Zapret2 Lua library: zapret-antidpi.lua not found in /opt/zapret2/lua or system paths";
                cleanup_temp_daemons(job_id);
                return result;
            }
        }
        
        let filter_prefix = "";
        if (is_z2 && index(args_str, "--filter-tcp") < 0 && index(args_str, "--filter-l7") < 0) {
            filter_prefix = "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ";
        }
        if (is_z2 && is_udp && index(args_str, "--filter-udp") < 0) {
            filter_prefix += "--filter-udp=443 --payload=quic_initial ";
        }
        
        let fwmark_flag = "";
        if (is_z2) {
            if (index(args_str, "--fwmark") < 0)
                fwmark_flag = sprintf("--fwmark=%s ", FUZZER_FWMARK);
        } else {
            if (index(args_str, "--dpi-desync-fwmark") < 0)
                fwmark_flag = sprintf("--dpi-desync-fwmark=%s ", FUZZER_FWMARK);
        }
        
        let argv = fuzzer_runner.build_zapret_argv(bin, qnum, fwmark_flag, lua_init_flags, blob_flags, filter_prefix, tok_res.tokens);
        let spawn_cmd = "cd /tmp && " + common.command_from_args(argv) + " 2>" + shell_quote(stderr_log);
        system(common.background_command_with_pid(spawn_cmd, ">/dev/null", ">" + shell_quote(pid_path)));
        
        let pid_running = false;
        for (let wait_i = 0; wait_i < 15; wait_i++) {
            system("sleep 0.1");
            let pid_str = fs.readfile(pid_path);
            if (pid_str) {
                let pid = trim(as_string(pid_str));
                if (pid != "" && match(pid, /^[0-9]+$/) != null && system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) == 0) {
                    pid_running = true;
                    break;
                }
            }
        }
        
        if (!pid_running) {
            let err_content = fs.readfile(stderr_log);
            let err_msg = err_content ? trim(as_string(err_content)) : "";
            if (err_msg != "") {
                let lines = split(err_msg, "\n");
                let err_line = "";
                for (let i = length(lines) - 1; i >= 0; i--) {
                    let l = trim(lines[i]);
                    if (l == "") continue;
                    if (index(l, "version") < 0 && index(l, "Running as") < 0 && index(l, "LUA v") < 0 && index(l, "JIT:") < 0 && index(l, "we have") < 0 && index(l, "initializing") < 0 && index(l, "opening nfq") < 0 && index(l, "unbinding") < 0 && index(l, "binding") < 0 && index(l, "setting copy") < 0 && index(l, "chdir") < 0) {
                        err_line = l;
                        break;
                    }
                }
                if (err_line == "") err_line = split(err_msg, "\n")[0];
                result.error = sprintf("Daemon failed to start: %s", err_line);
            } else {
                result.error = sprintf("Daemon %s failed to start (invalid arguments or missing Lua library)", is_z2 ? "nfqws2" : "nfqws");
            }
            cleanup_temp_daemons(job_id);
            return result;
        }
        
        if (!binaries.setup_fuzzer_direct_nftables(qnum, is_udp)) {
            result.error = "nftables setup failed: fuzzer queue rule could not be installed";
            cleanup_temp_daemons(job_id);
            return result;
        }
        
        let passed_count = 0;
        let max_speed = 0;
        let sum_data_bytes = 0;
        let all_data_verified = true;
        let last_http = 0;
        let last_dpi_verdict = "available";
        let dns_flags = binaries.get_fuzzer_curl_dns_flags();
        let required_failed = false;
        
        for (let target_item in urls_list) {
            let is_req = (target_item.required !== false);
            let p_kind = target_item.probe_kind || "tls_http";
            let extra_flags = "";

            if (p_kind == "quic" || target_key == "quic_http3") {
                if (!caps.http3) {
                    let single_res = {
                        target_name: target_item.name,
                        url: target_item.url,
                        required: is_req,
                        weight: target_item.weight || 100,
                        http_code: 0,
                        handshake_ms: 0,
                        ttfb_ms: 0,
                        speed_kbps: 0,
                        data_bytes: 0,
                        data_verified: false,
                        dpi_verdict: "unsupported_proto",
                        score: 0,
                        success: false,
                        error: "HTTP/3 (QUIC) not supported by router curl binary"
                    };
                    push(result.sub_probes, single_res);
                    if (is_req) { required_failed = true; result.error = single_res.error; }
                    break;
                }
                extra_flags = "--http3-only ";
            } else if (p_kind == "streaming") {
                extra_flags = "-r 0-65535 ";
            }

            let target_flags = binaries.get_resolved_host_flags(target_item.url);
            if (target_flags == "") target_flags = dns_flags;

            let curl_cmd = binaries.wrap_probe_cmd(
                sprintf(
                    "curl %s%s-so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}\\t%%{size_download}' -L --connect-timeout 4 --max-time 6 %s 2>/dev/null; printf '\\t%%d\\n' $?",
                    extra_flags,
                    target_flags,
                    shell_quote(target_item.url)
                ),
                8,
                probe_pid_path
            );
            let pipe = fs.popen(curl_cmd, "r");
            let output = pipe ? pipe.read("all") : "";
            if (pipe) pipe.close();
            try { fs.unlink(probe_pid_path); } catch (e) {}
            
            let single_res = parse_curl_output(output, {});
            single_res.target_name = target_item.name;
            single_res.url = target_item.url;
            single_res.required = is_req;
            single_res.weight = target_item.weight || 100;
            push(result.sub_probes, single_res);
            
            if (single_res.success) {
                passed_count++;
                sum_data_bytes += single_res.data_bytes || 0;
                if (!single_res.data_verified) all_data_verified = false;
                if (single_res.speed_kbps > max_speed) max_speed = single_res.speed_kbps;
                last_http = single_res.http_code;
                last_dpi_verdict = single_res.dpi_verdict || "available";
            } else {
                all_data_verified = false;
                if (last_http == 0) last_http = single_res.http_code;
                if (single_res.error && result.error == "") result.error = single_res.error;
                last_dpi_verdict = single_res.dpi_verdict || "failed";
                if (is_req) {
                    required_failed = true;
                    break;
                }
            }
        }
        
        cleanup_temp_daemons(job_id);
        
        if (required_failed || passed_count == 0) {
            result.success = false;
            result.http_code = last_http;
            result.data_bytes = sum_data_bytes;
            result.data_verified = false;
            result.dpi_verdict = last_dpi_verdict;
            result.score = 0;
            if (result.error == "") {
                result.error = sprintf("Required endpoint failed (%d of %d endpoints passed)", passed_count, total_urls);
            }
        } else {
            result.success = true;
            result.http_code = last_http > 0 ? last_http : 200;
            result.speed_kbps = max_speed;
            result.data_bytes = int(sum_data_bytes / (1.0 * total_urls));
            result.data_verified = all_data_verified;
            result.dpi_verdict = all_data_verified ? "verified_32k" : last_dpi_verdict;
            result.error = "";

            let total_w = 0;
            let weighted_score = 0.0;
            let weighted_ttfb = 0.0;
            let weighted_hs = 0.0;
            for (let sp in result.sub_probes) {
                let w = sp.weight || 10;
                total_w += w;
                weighted_score += (sp.score * w);
                weighted_ttfb += (sp.ttfb_ms * w);
                weighted_hs += (sp.handshake_ms * w);
            }
            result.score = total_w > 0 ? int(weighted_score / (1.0 * total_w)) : 0;
            result.ttfb_ms = total_w > 0 ? int(weighted_ttfb / (1.0 * total_w)) : 0;
            result.handshake_ms = total_w > 0 ? int(weighted_hs / (1.0 * total_w)) : 0;
        }
        
        return result;
    }
    
    result.error = "Unknown engine: " + engine;
    return result;
}

function module_exports() {
    return {
        BYEDPI_PORT,
        JOB_HARD_DEADLINE_SECONDS,
        kill_pid_file,
        cleanup_temp_daemons,
        parse_curl_output,
        run_probe
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: diagnostics/fuzzer/probe.uc (library module, no CLI)
");
exit(1);
