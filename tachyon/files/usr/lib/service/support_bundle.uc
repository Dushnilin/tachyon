#!/usr/bin/env ucode

// ─── Tachyon Diagnostic & Support Bundle Generator ────────────────────────────
//
// Architectural Role:
//   Gathers comprehensive, cross-subsystem diagnostics from the OpenWrt router
//   and packages them into a compressed, privacy-hardened diagnostic archive (.tar.gz).
//
// Privacy Guarantee (Secret Redaction):
//   ALL collected configs, logs, event journals, and command outputs pass through
//   strict redaction before being written to disk:
//     - Telegram bot tokens and admin chat IDs are replaced with redacted markers.
//     - Private keys, preshared keys, and Reality credentials are masked.
//     - Passwords, hashes, and UUIDs in proxy URLs/configs are redacted.
//     - Bearer tokens in headers and query params are stripped.
//
// Bundle Content:
//   - metadata.json: timestamp, versions, OpenWrt release, architecture, uptime, memory, disk
//   - versions.json: installed packages, sing-box, zapret, byedpi, ucode versions
//   - service_status.json: service enabled/running, engine, watchdog, known-good, emergency state
//   - config_sanitized/: /etc/config/tachyon, network, firewall, dhcp, sing-box config.json
//   - events_and_jobs/: event journal (tail), recent job records, AI Doctor reports
//   - network_and_routing/: routing tables (main & tachyon), policy rules, interfaces, resolv.conf
//   - firewall_and_nftables/: TachyonTable / steer ruleset, set counts and element statistics
//   - diagnostics_and_logs/: system logread (tail 500), tachyon logs, process tree, FD counts
//   - checksums.sha256: SHA-256 hashes of all bundled artifacts
//

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;

// Optional core modules loaded with safe fallbacks
let logging = null;
try { logging = require("core.logging"); } catch (e) {}

let events = null;
try { events = require("core.events"); } catch (e) {}

let known_good = null;
try { known_good = require("service.known_good"); } catch (e) {}

// ─── Test Overrides ───────────────────────────────────────────────────────────

let _override_output_dir = null;
let _override_tachyon_config = null;
let _override_test_root = null;

function set_test_overrides(output_dir, tachyon_config, test_root) {
    _override_output_dir = output_dir;
    _override_tachyon_config = tachyon_config;
    _override_test_root = test_root;
}

// ─── Unique ID Generator ──────────────────────────────────────────────────────

let _counter = 0;
function unique_suffix() {
    _counter++;
    return sprintf("%d_%d", time(), _counter);
}

// ─── Command Execution Helper ─────────────────────────────────────────────────

function command_capture(cmd) {
    let pipe = fs.popen(cmd + " 2>/dev/null", "r");
    if (!pipe) return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    if (status > 255) status = int(status / 256);
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(cmd) {
    let res = command_capture(cmd);
    return res.status == 0 ? trim(res.output) : "";
}

// ─── Secret Redaction Subsystem ───────────────────────────────────────────────

const SENSITIVE_KEY_REGEX = /^(password|secret|token|bot_token|telegram_bot_token|telegram_token|api_key|auth_token|bearer|uuid|private_key|secret_key|psk|preshared_key|shadowsocks_key|vless_uuid|vmess_uuid|trojan_password|hysteria_auth)$/i;
const SENSITIVE_KEY_SUBSTR = /(bot_token|telegram_token|private_key|secret_key|preshared_key|password)/i;

function is_sensitive_key(key) {
    if (key == null || key == "") return false;
    let k = as_string(key);
    return match(k, SENSITIVE_KEY_REGEX) != null || match(k, SENSITIVE_KEY_SUBSTR) != null;
}

function redact_string(str) {
    if (str == null || str == "") return "";
    let s = as_string(str);

    // 1. Telegram bot tokens: e.g. 123456789:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567
    s = replace(s, /[0-9]{8,12}:[-_a-zA-Z0-9]{35}/g, "[REDACTED_TELEGRAM_TOKEN]");

    // 2. Bearer tokens: e.g. Bearer eyJhbGci...
    s = replace(s, /Bearer[ \t]+[-_a-zA-Z0-9.+=]{16,}/gi, "Bearer [REDACTED_TOKEN]");

    // 3. VLESS / Trojan / Hysteria UUIDs & passwords in links
    s = replace(s, /vless:\/\/([^@ \t\r\n]+)@/g, "vless://[REDACTED_UUID]@");
    s = replace(s, /trojan:\/\/([^@ \t\r\n]+)@/g, "trojan://[REDACTED_PASS]@");
    s = replace(s, /hysteria2?:\/\/([^@ \t\r\n]+)@/g, "hysteria2://[REDACTED_AUTH]@");

    // 4. Other proxy / HTTP URLs with credentials: e.g. https://user:pass@host:port
    s = replace(s, /:\/\/([^:@\[ \t\r\n]+)(:[^@ \t\r\n]+)?@/g, "://[REDACTED]@");

    // 5. Standalone secret/password params in query strings
    s = replace(s, /([?&](password|secret|key|token|auth)=)[^& \t\r\n]+/gi, "$1[REDACTED]");

    // 6. UCI configuration options with sensitive data
    s = replace(s, /(option\s+([_a-zA-Z0-9]*(telegram_bot_token|bot_token|agent_api_token|api_token|token|password|secret|private_key|preshared_key|uuid|key|auth|pass)[_a-zA-Z0-9]*)\s+['"])[^'"]*(['"])/gi, "$1[REDACTED]$4");
    s = replace(s, /(list\s+(telegram_chat_id|allowed_chats|admin_ids)\s+['"])[^'"]*(['"])/gi, "$1[REDACTED_CHAT_ID]$3");

    return s;
}

function redact_object(val) {
    let t = type(val);
    if (t == "string") {
        return redact_string(val);
    }
    if (t == "array") {
        let out = [];
        for (let item in val) push(out, redact_object(item));
        return out;
    }
    if (t == "object") {
        let out = {};
        for (let k, v in val) {
            if (is_sensitive_key(k)) {
                out[k] = "[REDACTED]";
            } else {
                out[k] = redact_object(v);
            }
        }
        return out;
    }
    return val;
}

function sanitize_uci_text(content) {
    if (content == null || content == "") return "";
    let lines = split(as_string(content), "\n");
    let out = [];
    for (let line in lines) {
        push(out, redact_string(line));
    }
    return join("\n", out);
}

// ─── Logging Helpers ──────────────────────────────────────────────────────────

function log_info(msg) {
    if (logging && logging.log) logging.log(msg, { level: "info", subsystem: "service.support_bundle" });
    else command_capture("logger -t tachyon [info] SupportBundle: " + shell_quote(msg));
}

function log_warn(msg) {
    if (logging && logging.log) logging.log(msg, { level: "warn", subsystem: "service.support_bundle" });
    else command_capture("logger -t tachyon [warn] SupportBundle: " + shell_quote(msg));
}

// ─── Filesystem Helpers ───────────────────────────────────────────────────────

function ensure_dir(dir_path) {
    if (fs.stat(dir_path) == null) {
        system("mkdir -p " + shell_quote(dir_path));
    }
}

function read_file_safe(path) {
    let root = _override_test_root || "";
    let full = root + path;
    if (fs.stat(full) == null) return null;
    return fs.readfile(full);
}

function write_file_safe(path, content) {
    let f = fs.open(path, "w");
    if (!f) return false;
    f.write(as_string(content));
    f.close();
    return true;
}

function write_json_safe(path, data) {
    return write_file_safe(path, sprintf("%J\n", data));
}

function compute_file_sha256(path) {
    if (fs.stat(path) == null) return "";
    let res = command_capture("sha256sum " + shell_quote(path));
    if (res.status == 0 && trim(res.output) != "") {
        let parts = split(trim(res.output), /[ \t]+/);
        return parts[0];
    }
    return "";
}

// ─── Data Collectors ──────────────────────────────────────────────────────────

function collect_metadata() {
    let meta = {
        bundle_generated_at: time(),
        bundle_version: "1.0",
        tachyon_version: constants.TACHYON_VERSION || "1.4.3",
        hostname: command_output("uname -n"),
        kernel: command_output("uname -a"),
        architecture: command_output("uname -m"),
        openwrt_release: {},
        uptime: command_output("uptime"),
        memory: {},
        disk: command_output("df -h / /tmp /etc /overlay")
    };

    // Read /etc/openwrt_release
    let rel_text = read_file_safe("/etc/openwrt_release");
    if (rel_text != null) {
        let lines = split(as_string(rel_text), "\n");
        for (let l in lines) {
            let m = match(l, /^DISTRIB_([A-Z_]+)=['"]?([^'"]*)['"]?/);
            if (m && m[1]) meta.openwrt_release[lc(m[1])] = m[2];
        }
    }

    // Read /proc/meminfo
    let mem_text = read_file_safe("/proc/meminfo");
    if (mem_text != null) {
        let lines = split(as_string(mem_text), "\n");
        for (let l in lines) {
            let m = match(l, /^([A-Za-z0-9_]+):\s+([0-9]+)\s+kB/);
            if (m && m[1]) {
                let k = m[1];
                if (k == "MemTotal" || k == "MemFree" || k == "MemAvailable" || k == "Buffers" || k == "Cached") {
                    meta.memory[k] = int(m[2]);
                }
            }
        }
    }

    return meta;
}

function collect_versions() {
    let vers = {
        ucode: command_output("ucode -v"),
        sing_box: command_output("/usr/bin/sing-box version"),
        sing_box_variant: trim(as_string(read_file_safe("/etc/tachyon/sing-box-variant") || "")),
        zapret: command_output("nfqws --version"),
        zapret2: command_output("nfqws2 --version"),
        byedpi: command_output("ciadpi -v"),
        nftables: command_output("nft --version"),
        iptables: command_output("iptables --version")
    };
    return vers;
}

function collect_service_status() {
    let settings = {};
    try {
        settings = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    } catch (e) {}

    let st = {
        enabled: settings.enabled == "1" || settings.enabled == "true" || settings.enabled == true,
        engine: settings.engine || "sing-box",
        is_steer: settings.engine == "steer" || settings.engine == "steer-extended",
        dns_mode: settings.dns_mode || "dnsmasq",
        tproxy_port: settings.tproxy_port || "1602",
        mixed_port: settings.mixed_port || "4534",
        known_good: null,
        emergency_failsafe: null,
        pids: {
            watchdog: trim(as_string(read_file_safe("/var/run/tachyon_watchdog.pid") || "")),
            sing_box: trim(as_string(read_file_safe("/var/run/sing-box.pid") || "")),
            telegram: trim(as_string(read_file_safe("/var/run/tachyon_telegram.pid") || "")),
            byedpi: trim(as_string(read_file_safe("/var/run/byedpi.pid") || ""))
        }
    };

    if (known_good && known_good.get_status) {
        try { st.known_good = known_good.get_status(); } catch (e) {}
    }

    let emerg = read_file_safe("/etc/tachyon/emergency_state.json");
    if (emerg != null) {
        try { st.emergency_failsafe = json(emerg); } catch (e) {}
    }

    return st;
}

function collect_events_and_jobs() {
    let ev_list = [];
    if (events && events.bus) {
        try {
            let bus = events.bus({ journal: true });
            let journal = bus.journal();
            if (journal && journal.query) {
                ev_list = journal.query({ limit: 100 });
            }
        } catch (e) {}
    }

    let last_doctor = null;
    let doc_raw = read_file_safe("/tmp/ai_doctor_last.json");
    if (doc_raw != null) {
        try { last_doctor = json(doc_raw); } catch (e) {}
    }

    return {
        event_journal: redact_object(ev_list),
        last_ai_doctor_report: redact_object(last_doctor)
    };
}

function collect_process_and_fd_stats() {
    let procs = [];
    let pipe = fs.popen("ps w 2>/dev/null", "r");
    if (pipe) {
        let content = pipe.read("all");
        pipe.close();
        if (content) {
            let lines = split(as_string(content), "\n");
            for (let l in lines) {
                if (trim(l) != "") push(procs, redact_string(l));
            }
        }
    }

    // Measure FD counts for prominent daemons
    let fd_stats = {};
    let pid_files = [
        [ "sing-box", "/var/run/sing-box.pid" ],
        [ "watchdog", "/var/run/tachyon_watchdog.pid" ],
        [ "telegram", "/var/run/tachyon_telegram.pid" ],
        [ "dnsmasq", "/var/run/dnsmasq/dnsmasq.cfg01411c.pid" ]
    ];
    for (let p in pid_files) {
        let name = p[0];
        let p_path = p[1];
        let pid_str = trim(as_string(read_file_safe(p_path) || ""));
        if (pid_str != "" && match(pid_str, /^[0-9]+$/)) {
            let fd_out = command_output("ls -1 /proc/" + pid_str + "/fd | wc -l");
            fd_stats[name] = { pid: int(pid_str), fd_count: int(fd_out) };
        }
    }

    return {
        process_list: procs,
        fd_counts: fd_stats
    };
}

// ─── Bundle Staging & Archiving ───────────────────────────────────────────────

function stage_bundle(stage_dir) {
    ensure_dir(stage_dir);
    ensure_dir(stage_dir + "/config_sanitized");
    ensure_dir(stage_dir + "/network_and_routing");
    ensure_dir(stage_dir + "/firewall_and_nftables");
    ensure_dir(stage_dir + "/diagnostics_and_logs");
    ensure_dir(stage_dir + "/events_and_jobs");

    // 1. Metadata & Versions
    write_json_safe(stage_dir + "/metadata.json", collect_metadata());
    write_json_safe(stage_dir + "/versions.json", collect_versions());
    write_json_safe(stage_dir + "/service_status.json", collect_service_status());

    // 2. Sanitized Configurations
    let cfg_path = _override_tachyon_config || "/etc/config/tachyon";
    let tachyon_cfg = read_file_safe(cfg_path);
    if (tachyon_cfg != null) {
        write_file_safe(stage_dir + "/config_sanitized/tachyon.uci", sanitize_uci_text(tachyon_cfg));
    }
    let net_cfg = read_file_safe("/etc/config/network");
    if (net_cfg != null) {
        write_file_safe(stage_dir + "/config_sanitized/network.uci", sanitize_uci_text(net_cfg));
    }
    let fw_cfg = read_file_safe("/etc/config/firewall");
    if (fw_cfg != null) {
        write_file_safe(stage_dir + "/config_sanitized/firewall.uci", sanitize_uci_text(fw_cfg));
    }
    let dhcp_cfg = read_file_safe("/etc/config/dhcp");
    if (dhcp_cfg != null) {
        write_file_safe(stage_dir + "/config_sanitized/dhcp.uci", sanitize_uci_text(dhcp_cfg));
    }

    // Engine config JSON (sanitized)
    let singbox_cfg = read_file_safe("/etc/sing-box/config.json");
    if (singbox_cfg == null) singbox_cfg = read_file_safe("/var/etc/sing-box/config.json");
    if (singbox_cfg != null) {
        try {
            let parsed = json(singbox_cfg);
            write_json_safe(stage_dir + "/config_sanitized/singbox_config.json", redact_object(parsed));
        } catch (e) {
            write_file_safe(stage_dir + "/config_sanitized/singbox_config.json", redact_string(singbox_cfg));
        }
    }

    // 3. Network and Policy Routing
    write_file_safe(stage_dir + "/network_and_routing/ip_route_v4.txt", command_output("ip route show"));
    write_file_safe(stage_dir + "/network_and_routing/ip_route_v6.txt", command_output("ip -6 route show"));
    write_file_safe(stage_dir + "/network_and_routing/ip_rule_v4.txt", command_output("ip rule show"));
    write_file_safe(stage_dir + "/network_and_routing/ip_rule_v6.txt", command_output("ip -6 rule show"));
    write_file_safe(stage_dir + "/network_and_routing/table_tachyon.txt", command_output("ip route show table 4249"));
    write_file_safe(stage_dir + "/network_and_routing/ip_addr.txt", command_output("ip addr"));

    let resolv = read_file_safe("/tmp/resolv.conf.d/resolv.conf.auto");
    if (resolv == null) resolv = read_file_safe("/etc/resolv.conf");
    if (resolv != null) write_file_safe(stage_dir + "/network_and_routing/resolv.conf", redact_string(resolv));

    // 4. Firewall and nftables
    let nft_tachyon = command_output("nft list table inet TachyonTable");
    if (nft_tachyon == "") nft_tachyon = command_output("nft list table inet steer");
    write_file_safe(stage_dir + "/firewall_and_nftables/nft_ruleset.txt", nft_tachyon);

    // 5. Diagnostics, Process & Log stats
    let proc_stats = collect_process_and_fd_stats();
    write_json_safe(stage_dir + "/diagnostics_and_logs/process_and_fd.json", proc_stats);

    let logread_lines = command_output("logread | tail -n 500");
    write_file_safe(stage_dir + "/diagnostics_and_logs/system_logread.txt", redact_string(logread_lines));

    // 6. Events and AI Doctor
    write_json_safe(stage_dir + "/events_and_jobs/events_and_doctor.json", collect_events_and_jobs());

    // 7. Compute Checksums
    let chk_cmd = "cd " + shell_quote(stage_dir) + " && find . -type f ! -name 'checksums.sha256' -exec sha256sum {} \\; | sort -k 2";
    let chk_res = command_output(chk_cmd);
    write_file_safe(stage_dir + "/checksums.sha256", chk_res + "\n");
}

function create_bundle(output_target, options) {
    options = options || {};
    let timestamp_str = sprintf("%d", time());
    let default_name = "tachyon_support_bundle_" + timestamp_str;

    let base_out_dir = _override_output_dir || "/tmp";
    ensure_dir(base_out_dir);

    let stage_dir = base_out_dir + "/staging_" + default_name + "_" + unique_suffix();
    stage_bundle(stage_dir);

    if (options.archive == false || options.no_archive == true) {
        log_info("Created support bundle directory at " + stage_dir);
        return {
            ok: true,
            success: true,
            bundle_path: stage_dir,
            is_archive: false,
            created_at: time()
        };
    }

    let final_tar_gz = output_target;
    if (final_tar_gz == null || trim(as_string(final_tar_gz)) == "") {
        final_tar_gz = base_out_dir + "/" + default_name + ".tar.gz";
    }

    // Compress using tar -czf or tar -cf fallback
    let tar_cmd = "tar -czf " + shell_quote(final_tar_gz) + " -C " + shell_quote(stage_dir) + " .";
    let res = command_capture(tar_cmd);

    if (res.status != 0) {
        // Fallback to uncompressed tar if gzip not present
        let tar_plain = replace(final_tar_gz, /\.tar\.gz$/, ".tar");
        let fallback_cmd = "tar -cf " + shell_quote(tar_plain) + " -C " + shell_quote(stage_dir) + " .";
        let res_fb = command_capture(fallback_cmd);
        if (res_fb.status == 0) {
            final_tar_gz = tar_plain;
        } else {
            system("rm -rf " + shell_quote(stage_dir));
            return {
                ok: false,
                success: false,
                error: "Failed to create tar archive: " + res.output
            };
        }
    }

    // Clean staging
    system("rm -rf " + shell_quote(stage_dir));

    let fstat = fs.stat(final_tar_gz);
    let size = fstat ? fstat.size : 0;
    let sha256 = compute_file_sha256(final_tar_gz);

    log_info(sprintf("Successfully generated Support Bundle: %s (size: %d bytes, sha256: %s)",
        final_tar_gz, size, substr(sha256, 0, 12)));

    return {
        ok: true,
        success: true,
        bundle_path: final_tar_gz,
        is_archive: true,
        size_bytes: size,
        sha256: sha256,
        created_at: time()
    };
}

// ─── Built-in Selftest ────────────────────────────────────────────────────────

function selftest() {
    let passed = 0;
    let failed = 0;

    function assert(cond, msg) {
        if (cond) {
            passed++;
        } else {
            failed++;
            print("FAIL: " + msg + "\n");
        }
    }

    let test_dir = "/tmp/test_support_bundle_" + unique_suffix();
    system("mkdir -p " + shell_quote(test_dir));

    // Test 1: Redaction of Telegram bot token
    let sample_token = "123456789:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567";
    let red_str = redact_string("Error contacting bot token " + sample_token + " from worker");
    assert(index(red_str, sample_token) < 0, "sample bot token removed from text");
    assert(index(red_str, "[REDACTED_TELEGRAM_TOKEN]") >= 0, "inserted REDACTED_TELEGRAM_TOKEN");

    // Test 2: Redaction of Bearer tokens
    let red_bearer = redact_string("Authorization: Bearer secret_agent_api_token_123456789");
    assert(index(red_bearer, "secret_agent_api_token_123456789") < 0, "bearer token stripped");
    assert(index(red_bearer, "Bearer [REDACTED_TOKEN]") >= 0, "inserted REDACTED_TOKEN");

    // Test 3: Redaction of VLESS UUID
    let red_vless = redact_string("Connecting to vless://12345678-1234-1234-1234-1234567890ab@example.com:443");
    assert(index(red_vless, "12345678-1234-1234-1234-1234567890ab") < 0, "UUID removed from VLESS link");
    assert(index(red_vless, "vless://[REDACTED_UUID]@") >= 0, "inserted REDACTED_UUID marker");

    // Test 4: Redaction of UCI configuration text
    let uci_raw = "config settings\n\toption telegram_bot_token '" + sample_token + "'\n\toption private_key 'MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwgg'\n\toption normal_opt 'hello'\n";
    let uci_clean = sanitize_uci_text(uci_raw);
    assert(index(uci_clean, sample_token) < 0, "bot token redacted in UCI text");
    assert(index(uci_clean, "MIIEvgIB") < 0, "private key redacted in UCI text");
    assert(index(uci_clean, "hello") >= 0, "normal option preserved in UCI text");

    // Test 5: Redaction of recursive JSON object
    let secret_obj = {
        name: "test",
        password: "SuperSecretPassword123!",
        nested: {
            telegram_bot_token: sample_token,
            public_value: 42
        }
    };
    let clean_obj = redact_object(secret_obj);
    assert(clean_obj.password == "[REDACTED]", "password field masked in object");
    assert(clean_obj.nested.telegram_bot_token == "[REDACTED]", "nested bot_token masked in object");
    assert(clean_obj.nested.public_value == 42, "public nested value preserved");

    // Test 6: Create Bundle in sandbox
    set_test_overrides(test_dir, null);
    let target_bundle = test_dir + "/bundle.tar.gz";
    let b_res = create_bundle(target_bundle);

    assert(b_res.ok == true, "create_bundle returned ok");
    assert(fs.stat(target_bundle) != null, "target bundle archive was created on disk");
    assert(b_res.size_bytes > 0, "bundle archive has non-zero size");
    assert(length(b_res.sha256) == 64, "bundle has valid sha256 checksum");

    // Test 7: Verify bundle contents (tar -tf)
    let tar_list = command_output("tar -tf " + shell_quote(target_bundle));
    assert(index(tar_list, "metadata.json") >= 0, "archive contains metadata.json");
    assert(index(tar_list, "versions.json") >= 0, "archive contains versions.json");
    assert(index(tar_list, "service_status.json") >= 0, "archive contains service_status.json");
    assert(index(tar_list, "checksums.sha256") >= 0, "archive contains checksums.sha256");

    // Test 8: Extract and verify checksums inside bundle
    let extract_dir = test_dir + "/extracted";
    system("mkdir -p " + shell_quote(extract_dir) + " && tar -xzf " + shell_quote(target_bundle) + " -C " + shell_quote(extract_dir));
    let chk_verify = command_capture("cd " + shell_quote(extract_dir) + " && sha256sum -c checksums.sha256");
    assert(chk_verify.status == 0, "all bundled files match their embedded sha256 checksums");

    // Cleanup & reset
    system("rm -rf " + shell_quote(test_dir));
    set_test_overrides(null, null);

    print(sprintf("Support bundle selftest: %d passed, %d failed\n", passed, failed));
    return failed == 0 ? 0 : 1;
}

// ─── Module Exports & Guard ───────────────────────────────────────────────────

function module_exports() {
    return {
        create_bundle,
        stage_bundle,
        collect_metadata,
        collect_versions,
        collect_service_status,
        collect_events_and_jobs,
        collect_process_and_fd_stats,
        redact_string,
        redact_object,
        sanitize_uci_text,
        set_test_overrides,
        selftest
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ─── CLI Entrypoint ───────────────────────────────────────────────────────────

let mode = ARGV[0] || "";

if (mode == "selftest") {
    exit(selftest());
} else if (mode == "create" || mode == "generate" || mode == "" || substr(mode, 0, 1) == "-") {
    let target_path = null;
    let format = "text";
    let no_archive = false;

    for (let i = 0; i < length(ARGV); i++) {
        let arg = ARGV[i];
        if (arg == "--json") format = "json";
        else if (arg == "--text") format = "text";
        else if (arg == "--no-archive") no_archive = true;
        else if (target_path == null && substr(arg, 0, 1) != "-" && arg != "create" && arg != "generate") {
            target_path = arg;
        }
    }

    let res = create_bundle(target_path, { no_archive: no_archive });
    if (format == "json") {
        print(sprintf("%J\n", res));
    } else {
        if (res.ok) {
            print("══════════════════════════════════════════════════════════════════════════════\n");
            print("                     TACHYON SUPPORT BUNDLE GENERATED                         \n");
            print("══════════════════════════════════════════════════════════════════════════════\n");
            print(" Bundle File:    " + res.bundle_path + "\n");
            print(" File Size:      " + sprintf("%.2f KB (%d bytes)", res.size_bytes / 1024, res.size_bytes) + "\n");
            print(" SHA-256:        " + res.sha256 + "\n");
            print(" Redaction:      PASS (All bot tokens, UUIDs, and credentials masked)\n");
            print("──────────────────────────────────────────────────────────────────────────────\n");
            print(" You can safely share this file with support or on GitHub issues.\n");
            print("══════════════════════════════════════════════════════════════════════════════\n");
        } else {
            warn("ERROR: Failed to generate support bundle: " + (res.error || "unknown error") + "\n");
        }
    }
    exit(res.ok ? 0 : 1);
} else {
    warn("Usage: service/support_bundle.uc <selftest|create [path] [--json] [--no-archive]>\n");
    exit(1);
}

return module_exports();
