#!/usr/bin/env ucode
//
// Fuzzer probe targets and DPI type detection.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split). Owns the
// target suites, target URL resolution and the direct-probe DPI classifier.
//

let fs = require("fs");
let common = require("core.common");

let binaries = require("diagnostics.fuzzer.binaries");
let probe = require("diagnostics.fuzzer.probe");

let as_string = common.as_string;
let shell_quote = common.shell_quote;

function detect_dpi_type(target_key, custom_url) {
    let urls_list = binaries.resolve_target_urls_list(target_key, custom_url);
    let target_url = urls_list[0] ? urls_list[0].url : "https://www.google.com";
    let dns_flags = binaries.get_fuzzer_curl_dns_flags();

    let result = {
        type: "unknown",
        confidence: 0,
        details: "",
        recommended_engines: [],
        probe_metrics: { http_code: 0, handshake_ms: 0, ttfb_ms: 0, speed_kbps: 0, error: "" }
    };

    // Direct probe with bypass of Sing-box TProxy.
    // Pre-clean: delete any stale fuzzer table so chain/rule adds don't conflict.
    binaries.run_bounded("nft delete table inet tachyon_fuzzer >/dev/null 2>&1", 10);
    system("nft add table inet tachyon_fuzzer 2>/dev/null");
    system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443 } meta mark set meta mark | %s counter' 2>/dev/null", binaries.FUZZER_OUTBOUND_MARK));

    let target_flags = binaries.get_resolved_host_flags(target_url);
    if (target_flags == "") target_flags = dns_flags;

    let curl_cmd = binaries.wrap_probe_cmd(
        sprintf(
            "curl %s-so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}\\t%%{size_download}' -L --connect-timeout 4 --max-time 6 %s 2>&1; printf '\\t%%d\\n' $?",
            target_flags,
            shell_quote(target_url)
        ),
        8
    );
    let pipe = fs.popen(curl_cmd, "r");
    let output = pipe ? pipe.read("all") : "";
    if (pipe) pipe.close();
    output = trim(output);

    probe.cleanup_temp_daemons();

    let metrics = {};
    probe.parse_curl_output(output, metrics);
    result.probe_metrics = {
        http_code: metrics.http_code || 0,
        handshake_ms: metrics.handshake_ms || 0,
        ttfb_ms: metrics.ttfb_ms || 0,
        speed_kbps: metrics.speed_kbps || 0,
        data_bytes: metrics.data_bytes || 0,
        dpi_verdict: metrics.dpi_verdict || "unknown",
        error: metrics.error || ""
    };

    // Also check for DNS-level blocking
    let domain = target_url;
    let dm = match(domain, /https?:\/\/([^/]+)/);
    if (dm && dm[1]) domain = dm[1];

    let dns_cmd = binaries.wrap_probe_cmd(sprintf("nslookup %s 77.88.8.8 2>&1 || nslookup %s 2>&1", shell_quote(domain), shell_quote(domain)), 4);
    let dns_pipe = fs.popen(dns_cmd, "r");
    let dns_out = dns_pipe ? dns_pipe.read("all") : "";
    if (dns_pipe) dns_pipe.close();

    let dns_blocked = false;
    if (index(dns_out, "NXDOMAIN") >= 0 || index(dns_out, "can't resolve") >= 0 || index(dns_out, "** server can't find") >= 0) {
        dns_blocked = true;
    }

    // Analyze failure patterns
    let http_code = metrics.http_code || 0;
    let handshake = metrics.handshake_ms || 0;
    let ttfb = metrics.ttfb_ms || 0;
    let error_str = metrics.error || "";

    // 1. Check if target is directly accessible first
    if ((http_code >= 200 && http_code < 400) || (http_code >= 401 && http_code <= 405)) {
        result.type = "none";
        result.confidence = 95;
        result.details = sprintf("Target directly accessible — no DPI blocking detected (HTTP %d, TTFB %dms)", http_code, ttfb);
        result.recommended_engines = [];
    } else if (dns_blocked && http_code == 0 && handshake == 0) {
        result.type = "dns_block";
        result.confidence = 90;
        result.details = sprintf("DNS resolution failed for %s — likely DNS-level blocking or hijacking", domain);
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    } else if (metrics.dpi_verdict == "throttled_16k" || (http_code == 200 && metrics.data_bytes >= 10240 && metrics.data_bytes <= 28672)) {
        result.type = "throttle";
        result.confidence = 95;
        result.details = sprintf("16KB DPI throttling detected on %s — handshake succeeded but stream dropped at ~16KB data transfer", domain);
        result.recommended_engines = ["zapret2", "byedpi"];
    } else if ((http_code == 0 && handshake == 0) && (index(error_str, "timed out") >= 0 || index(error_str, "Connection timed out") >= 0 || index(error_str, "ETIMEDOUT") >= 0)) {
        result.type = "drop";
        result.confidence = 90;
        result.details = sprintf("TCP connect timed out for %s — TSPU / DPI packet drop (blackhole) detected. Can be bypassed using syndata, multisplit, or PAWS spoofing.", domain);
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    } else if (index(error_str, "Connection reset") >= 0 || index(error_str, "ECONNRESET") >= 0) {
        result.type = "rst";
        result.confidence = 85;
        result.details = sprintf("TCP RST received from DPI — active TCP reset injection detected");
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    } else if (http_code == 0 || index(error_str, "Connection refused") >= 0 || index(error_str, "ECONNREFUSED") >= 0) {
        result.type = "rst";
        result.confidence = 70;
        result.details = sprintf("Connection refused — likely RST or blackhole by DPI");
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    } else if (handshake > 2000) {
        result.type = "throttle";
        result.confidence = 75;
        result.details = sprintf("Very slow TLS handshake (%dms) — likely DPI deep inspection causing delay", handshake);
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    } else if (ttfb > 3000 && http_code >= 200 && http_code < 400) {
        result.type = "throttle";
        result.confidence = 65;
        result.details = sprintf("High TTFB (%dms) despite successful connection — likely bandwidth throttling", ttfb);
        result.recommended_engines = ["zapret2", "byedpi"];
    } else {
        result.type = "unknown";
        result.confidence = 30;
        result.details = sprintf("Inconclusive — HTTP %d, error: %s", http_code, error_str != "" ? error_str : "none");
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    }

    return result;
}

// ── Strategy Priority Reranking (based on DPI type) ─────────────────────────
function rerank_strategies_by_dpi(strategies, dpi_type) {
    if (!dpi_type || dpi_type.type == "none" || dpi_type.type == "unknown")
        return strategies;

    let priority_ids = [];
    if (dpi_type.type == "rst") {
        priority_ids = ["badseq", "md5sig", "multisplit", "disorder", "syndata", "paws"];
    } else if (dpi_type.type == "drop" || dpi_type.type == "ip_block") {
        priority_ids = ["syndata", "multisplit", "multidisorder", "paws", "seqovl", "fake", "badseq", "disorder"];
    } else if (dpi_type.type == "throttle") {
        priority_ids = ["multisplit", "seqovl", "wsize", "split2", "paws", "syndata"];
    } else if (dpi_type.type == "dns_block") {
        priority_ids = ["fake", "ttl=3", "ttl=4", "sniext", "multisplit"];
    }

    if (length(priority_ids) == 0)
        return strategies;

    let scored = [];
    for (let s in strategies) {
        let score = 0;
        let args_lower = lc(as_string(s.args));
        let name_lower = lc(as_string(s.name));
        for (let pid in priority_ids) {
            if (index(args_lower, pid) >= 0 || index(name_lower, pid) >= 0) {
                score += 10;
            }
        }
        push(scored, { strat: s, score: score });
    }

    for (let i = 0; i < length(scored) - 1; i++) {
        for (let j = i + 1; j < length(scored); j++) {
            if (scored[j].score > scored[i].score) {
                let tmp = scored[i];
                scored[i] = scored[j];
                scored[j] = tmp;
            }
        }
    }

    let result = [];
    for (let item in scored) {
        push(result, item.strat);
    }
    return result;
}

function module_exports() {
    return {
        TARGET_SUITES,
        TARGET_URLS,
        detect_dpi_type,
        rerank_strategies_by_dpi
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: diagnostics/fuzzer/targets.uc (library module, no CLI)\n");
exit(1);
