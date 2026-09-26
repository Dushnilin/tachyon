#!/usr/bin/env ucode
//
// Fuzzer binaries, command bounding and nftables setup.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split). Everything
// here is about talking to the host: locating nfqws/ciadpi, bounding blocking
// shell calls, caching DoH capability and setting up the probe nftables table.
//

let fs = require("fs");
let common = require("core.common");
let fuzzer_runner = require("diagnostics.fuzzer_runner");

let as_string = common.as_string;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const NFQUEUE_QNUM_ZAPRET = 298;
const NFQUEUE_QNUM_ZAPRET2 = 299;
const FUZZER_FWMARK = "0x40000000";
const FUZZER_OUTBOUND_MARK = getenv("NFT_OUTBOUND_MARK") || "0x08000000";

let _has_timeout = null;
let _fuzzer_curl_dns_flags = null;
let _fuzzer_host_cache = {};

function log_fuzzer_message(message, level) {
    level = as_string(level || "warn");
    command_success_from_args([ "logger", "-t", "tachyon", "[fuzzer] [" + level + "] " + as_string(message) ]);
}

function resolve_binary(paths) {
    for (let p in paths) {
        if (p && fs.stat(p) != null)
            return p;
    }
    return null;
}

function get_zapret2_bin() {
    return resolve_binary([
        getenv("ZAPRET2_NFQWS2_BIN"),
        "/opt/zapret2/nfq2/nfqws2",
        "/opt/zapret2/nfq/nfqws2",
        "/opt/zapret2/nfqws2",
        "/usr/bin/nfqws2"
    ]);
}

function get_zapret_bin() {
    return resolve_binary([
        getenv("ZAPRET_NFQWS_BIN"),
        "/opt/zapret/nfq/nfqws",
        "/opt/zapret/nfqws",
        "/usr/bin/nfqws"
    ]);
}

function get_byedpi_bin() {
    return resolve_binary([
        getenv("BYEDPI_BIN"),
        "/opt/byedpi/ciadpi",
        "/usr/bin/ciadpi"
    ]);
}

function get_zapret2_lua_flags(args_str) {
    if (index(args_str, "--lua-init") >= 0)
        return "";

    let candidate_dirs = [
        getenv("ZAPRET2_PROVIDER_LUA_DIR"),
        LIB_DIR + "/providers/zapret2/lua",
        "/usr/lib/tachyon/providers/zapret2/lua",
        "/opt/zapret2/lua",
        "/opt/zapret2/files/lua",
        "/opt/zapret2/share/zapret/lua",
        "/opt/zapret2/init.d/sysv/lua",
        "/opt/zapret/lua",
        "/opt/zapret/files/lua",
        "/usr/share/zapret2/lua",
        "/usr/share/zapret/lua",
        "/etc/zapret2/lua",
        "/etc/zapret/lua",
        "/usr/lib/zapret2/lua",
        "/usr/lib/zapret/lua"
    ];

    let lua_scripts = [
        "zapret-lib.lua",
        "zapret-antidpi.lua",
        "zapret-auto.lua"
    ];

    let flags = "";
    for (let script in lua_scripts) {
        let found = null;
        for (let d in candidate_dirs) {
            if (!d || fs.stat(d) == null)
                continue;
            let p = d + "/" + script;
            if (fs.stat(p) != null) {
                found = p;
                break;
            }
            if (fs.stat(p + ".gz") != null) {
                found = p + ".gz";
                break;
            }
        }
        if (found != null)
            flags += sprintf("--lua-init=@%s ", found);
    }
    return flags;
}

function has_timeout() {
    if (_has_timeout === null)
        _has_timeout = (system("command -v timeout >/dev/null 2>&1 || [ -x /usr/bin/timeout ]") == 0);
    return _has_timeout;
}

function get_timeout_prefix(sec) {
    sec = sec || 8;
    return has_timeout() ? sprintf("timeout %d ", sec) : "";
}

function wrap_cmd_timeout(cmd, sec, pid_file) {
    sec = sec || 8;
    let t = has_timeout();
    if (pid_file && pid_file != "") {
        if (t)
            return sprintf("( echo $$ > %s; timeout -s KILL %d %s )", shell_quote(pid_file), sec, cmd);
        return sprintf("( echo $$ > %s; %s )", shell_quote(pid_file), cmd);
    }
    if (t)
        return sprintf("timeout -s KILL %d %s", sec, cmd);
    return cmd;
}

// Shell watchdog: runs cmd bounded by sec seconds even when the `timeout`
// binary is unavailable. Blocking forever on system()/pipe.read() wedges the
// whole fuzzer worker (deadline checks in ucode never get to run), so every
// blocking call must carry a hard wall-clock bound.
const _WATCHDOG_SUBSHELL = "( %s & _bp=$!; ( sleep %d; kill -9 $_bp 2>/dev/null ) & _bw=$!; wait $_bp 2>/dev/null; kill $_bw 2>/dev/null; wait $_bw 2>/dev/null )";

function run_bounded(cmd, sec) {
    sec = sec || 8;
    if (has_timeout())
        return system(sprintf("timeout -s KILL %d %s", sec, cmd));
    return system(sprintf(_WATCHDOG_SUBSHELL, cmd, sec));
}

function wrap_probe_cmd(cmd, sec, pid_file) {
    sec = sec || 8;
    if (has_timeout())
        return wrap_cmd_timeout(cmd, sec, pid_file);
    if (pid_file && pid_file != "")
        return sprintf("( echo $$ > %s; %s )", shell_quote(pid_file), sprintf(_WATCHDOG_SUBSHELL, cmd, sec));
    return sprintf(_WATCHDOG_SUBSHELL, cmd, sec);
}

function is_valid_public_ip(ip) {
    if (!ip || type(ip) != "string") return false;
    let m = match(ip, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
    if (!m) return false;
    let o1 = int(m[1]), o2 = int(m[2]), o3 = int(m[3]), o4 = int(m[4]);
    if (o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255) return false;
    if (o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224) return false;
    if (o1 == 100 && o2 >= 64 && o2 <= 127) return false;
    if (o1 == 169 && o2 == 254) return false;
    if (o1 == 172 && o2 >= 16 && o2 <= 31) return false;
    if (o1 == 192 && o2 == 168) return false;
    if (o1 == 198 && (o2 == 18 || o2 == 19)) return false;
    return true;
}

function get_fuzzer_curl_dns_flags() {
    if (_fuzzer_curl_dns_flags !== null)
        return _fuzzer_curl_dns_flags;
    let uci_bootstrap = "77.88.8.8";
    try {
        let p_boot = fs.popen("uci -q get tachyon.settings.bootstrap_dns_server 2>/dev/null", "r");
        let b_val = p_boot ? trim(p_boot.read("all")) : "";
        if (p_boot) p_boot.close();
        if (b_val != "" && is_valid_public_ip(b_val))
            uci_bootstrap = b_val;
    } catch (e) {}

    if (system(sprintf("curl --dns-servers %s,77.88.8.8 -V >/dev/null 2>&1", uci_bootstrap)) == 0) {
        _fuzzer_curl_dns_flags = sprintf("--dns-servers %s,77.88.8.8 ", uci_bootstrap);
        return _fuzzer_curl_dns_flags;
    }
    _fuzzer_curl_dns_flags = "";
    return _fuzzer_curl_dns_flags;
}

function get_resolved_host_flags(url) {
    let m = match(url, /^https?:\/\/([^\/:]+)/);
    if (!m || !m[1]) return "";
    let host = m[1];
    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) || index(host, ":") >= 0) return "";
    if (!fuzzer_runner.is_valid_hostname(host)) return "";
    if (exists(_fuzzer_host_cache, host))
        return _fuzzer_host_cache[host];

    // For googlevideo.com, query report_mapping to discover client's real local GGC caching cluster
    if (index(host, "googlevideo.com") >= 0) {
        let t_pre = get_timeout_prefix(3);
        let p_map = fs.popen(sprintf("%scurl -s --connect-timeout 2 -m 3 https://redirector.googlevideo.com/report_mapping 2>/dev/null", t_pre), "r");
        let map_out = p_map ? p_map.read("all") : "";
        if (p_map) p_map.close();
        if (map_out) {
            let m_ggc = match(map_out, /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[ \t]*=>/);
            if (m_ggc && m_ggc[1] && is_valid_public_ip(m_ggc[1])) {
                let ggc_ip = m_ggc[1];
                let flag = sprintf("--resolve %s:443:%s ", host, ggc_ip);
                _fuzzer_host_cache[host] = flag;
                return flag;
            }
        }
    }

    let safe_host = shell_quote(host);
    let ip = null;

    // 1. Primary: query "наш DNS" (router bootstrap DNS & ISP upstream DNS) via UDP 53
    // MUST NEVER query 127.0.0.1 or ::1 to prevent resolving into FakeIP (198.18.x.x)
    let dns_candidates = [];
    let seen_dns = {};

    // Check UCI tachyon bootstrap DNS server (e.g. 77.88.8.8)
    let uci_bootstrap = null;
    try {
        let p_boot = fs.popen("uci -q get tachyon.settings.bootstrap_dns_server 2>/dev/null", "r");
        let b_val = p_boot ? trim(p_boot.read("all")) : "";
        if (p_boot) p_boot.close();
        if (b_val != "" && is_valid_public_ip(b_val))
            uci_bootstrap = b_val;
    } catch (e) {}
    if (uci_bootstrap) {
        push(dns_candidates, uci_bootstrap);
        seen_dns[uci_bootstrap] = true;
    }

    // Check ISP nameservers from resolv.conf.auto
    try {
        let resolv_auto = fs.readfile("/tmp/resolv.conf.d/resolv.conf.auto");
        if (resolv_auto) {
            for (let line in split(resolv_auto, "\n")) {
                let m_ns = match(trim(line), /^nameserver[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
                if (m_ns && m_ns[1] && is_valid_public_ip(m_ns[1]) && !seen_dns[m_ns[1]]) {
                    push(dns_candidates, m_ns[1]);
                    seen_dns[m_ns[1]] = true;
                }
            }
        }
    } catch (e) {}

    // Add dependable fallback public nameservers
    for (let srv in [ "77.88.8.8", "8.8.8.8", "1.1.1.1" ]) {
        if (!seen_dns[srv]) {
            push(dns_candidates, srv);
            seen_dns[srv] = true;
        }
    }

    for (let srv in dns_candidates) {
        let np = fs.popen(sprintf("nslookup %s %s 2>/dev/null", safe_host, srv), "r");
        let nout = np ? np.read("all") : "";
        if (np) np.close();
        if (nout && nout != "") {
            let lines = split(nout, "\n");
            let name_seen = false;
            for (let line in lines) {
                if (index(line, "Name:") >= 0) { name_seen = true; continue; }
                if (name_seen) {
                    let nm = match(line, /Address:[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
                    if (nm && is_valid_public_ip(nm[1])) {
                        ip = nm[1];
                        break;
                    }
                }
            }
        }
        if (ip) break;
    }

    // 2. Fallback: Google & Cloudflare DoH JSON (if UDP 53 was intercepted by ISP)
    if (!ip) {
        let doh_endpoints = [
            "https://dns.google/resolve",
            "https://77.88.8.8/dns-query",
            "https://1.1.1.1/dns-query"
        ];
        for (let ep in doh_endpoints) {
            let p = fs.popen(sprintf("curl -s -m 3 --connect-timeout 2 -H 'accept: application/dns-json' '%s?name=%s&type=A'", ep, safe_host), "r");
            let out = p ? p.read("all") : "";
            if (p) p.close();
            if (out && out != "") {
                try {
                    let data = json(out);
                    if (data && data.Answer) {
                        for (let ans in data.Answer) {
                            if (ans.type == 1 && is_valid_public_ip(ans.data)) {
                                ip = ans.data;
                                break;
                            }
                        }
                    }
                } catch (e) {}
            }
            if (ip) break;
        }
    }

    // 4. Fallback for googlevideo.com CDN nodes that are not in public DNS:
    // resolve googlevideo.com or www.youtube.com IP so curl connects directly to Google's video infrastructure
    // while preserving the regional SNI in ClientHello that triggers TSPU DPI rules.
    if (!ip && (index(host, ".googlevideo.com") >= 0 || host == "googlevideo.com")) {
        let gv_flags = get_resolved_host_flags("https://googlevideo.com/");
        if (gv_flags == "") gv_flags = get_resolved_host_flags("https://www.youtube.com/");
        let m_ip = match(gv_flags, /:443:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
        if (m_ip && m_ip[1]) {
            ip = m_ip[1];
        }
    }

    if (ip) {
        let flags = sprintf("--resolve %s:443:%s --resolve %s:80:%s ", host, ip, host, ip);
        _fuzzer_host_cache[host] = flags;
        return flags;
    }
    _fuzzer_host_cache[host] = "";
    return "";
}

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

function blob_candidate_dirs() {
    return [
        getenv("ZAPRET2_PROVIDER_FILES_DIR") ? (getenv("ZAPRET2_PROVIDER_FILES_DIR") + "/fake") : null,
        "/opt/zapret2/files/fake",
        "/opt/zapret/files/fake",
        "/usr/share/zapret2/files/fake",
        "/usr/share/zapret/files/fake",
        "/etc/zapret2/files/fake",
        "/etc/zapret/files/fake",
        LIB_DIR + "/providers/zapret2/files/fake",
        "/usr/lib/tachyon/providers/zapret2/files/fake"
    ];
}

function get_zapret2_blob_dir() {
    for (let d in blob_candidate_dirs()) {
        if (d && fs.stat(d) != null) return d;
    }
    return "/opt/zapret2/files/fake";
}

function resolve_zapret2_blobs(args_str) {
    if (!args_str || args_str == "") return "";
    let candidate_dirs = blob_candidate_dirs();
    let blob_flags = "";
    for (let name, info in KNOWN_BLOB_FILES) {
        if ((index(args_str, "blob=" + name) >= 0 || index(args_str, "seqovl_pattern=" + name) >= 0) &&
            index(args_str, "--blob=" + name + ":") < 0) {
            let actual_path = null;
            for (let d in candidate_dirs) {
                if (!d || fs.stat(d) == null) continue;
                let p = d + "/" + info.file;
                if (fs.stat(p) != null) {
                    actual_path = p;
                    break;
                }
            }
            if (actual_path != null) {
                blob_flags += sprintf("--blob=%s:@%s ", name, actual_path);
            }
        }
    }
    return blob_flags;
}

function setup_fuzzer_direct_nftables(qnum, is_udp) {
    // ── Pre-cleanup: kill any orphaned fuzzer processes bound to our queues ──
    // An orphaned nfqueue binding wedges the kernel nft subsystem; nft delete
    // blocks forever and the subsequent add silently fails (2>/dev/null), so
    // every strategy reports a false failure.  Kill the binding first.
    for (let w = 0; w < 3; w++) {
        let nfq = fs.readfile("/proc/net/netfilter/nfnetlink_queue");
        let found = false;
        if (nfq) {
            let lines = split(trim(nfq), "\n");
            for (let line in lines) {
                let cols = split(trim(line), /[ \t]+/);
                if (length(cols) >= 2) {
                    let q = int(cols[0]);
                    let p = int(cols[1]);
                    if ((q == qnum || q == NFQUEUE_QNUM_ZAPRET || q == NFQUEUE_QNUM_ZAPRET2) && p > 0) {
                        found = true;
                        system(sprintf("kill -9 %d >/dev/null 2>&1", p));
                    }
                }
            }
        }
        if (!found) break;
        run_bounded("sleep 0.5", 2);
    }

    // ── Clean slate: delete any stale table ──────────────────────────────────
    // 10s timeout — on slow ARM routers nft delete can block on orphaned
    // in-kernel nfqueue bindings; 5s was not enough in some reports.
    run_bounded("nft delete table inet tachyon_fuzzer >/dev/null 2>&1", 10);

    // ── Create table with retry + backoff ────────────────────────────────────
    let nft_err_file = STATE_DIR + "/fuzzer_nft_err.log";
    try { fs.unlink(nft_err_file); } catch (e) {}
    let table_created = false;
    for (let attempt = 0; attempt < 3; attempt++) {
        if (system(sprintf("nft add table inet tachyon_fuzzer 2>%s", shell_quote(nft_err_file))) == 0) {
            table_created = true;
            break;
        }
        // Backoff: wait for orphaned bindings to release
        run_bounded("sleep 0.5", 2);
        run_bounded("nft delete table inet tachyon_fuzzer >/dev/null 2>&1", 10);
    }
    if (!table_created) {
        let nft_err = trim(as_string(fs.readfile(nft_err_file)) || "");
        log_fuzzer_message(sprintf("nftables table creation failed after 3 attempts (qnum=%d): %s", qnum, nft_err != "" ? nft_err : "unknown error"));
        try { fs.unlink(nft_err_file); } catch (e) {}
        return false;
    }
    try { fs.unlink(nft_err_file); } catch (e) {}

    // ── Build ruleset ────────────────────────────────────────────────────────
    // Priority -401: notrack before defrag/conntrack so desync packets (0x40000000 / 0x20000000)
    // are not marked 'ct state invalid' and dropped by OpenWrt fw4 !fw4: Prevent NAT leakage
    system("nft 'add chain inet tachyon_fuzzer predefrag { type filter hook output priority -401 ; policy accept; }' 2>/dev/null");
    system("nft 'add rule inet tachyon_fuzzer predefrag meta mark & 0x60000000 != 0 notrack counter' 2>/dev/null");
    system("nft 'add chain inet tachyon_fuzzer predefrag_pre { type filter hook prerouting priority -401 ; policy accept; }' 2>/dev/null");
    system("nft 'add rule inet tachyon_fuzzer predefrag_pre meta mark & 0x60000000 != 0 notrack counter' 2>/dev/null");

    system("nft 'add chain inet tachyon_fuzzer output { type filter hook output priority -200 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft add rule inet tachyon_fuzzer output meta mark %s counter return 2>/dev/null", FUZZER_FWMARK));
    system("nft 'add rule inet tachyon_fuzzer output ip daddr { 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 77.88.8.8 } counter return' 2>/dev/null");
    system("nft 'add rule inet tachyon_fuzzer output ip6 daddr { 2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844 } counter return' 2>/dev/null");
    if (is_udp) {
        system(sprintf("nft 'add rule inet tachyon_fuzzer output meta l4proto { tcp, udp } th dport { 80, 443, 2053, 2083, 2087, 2096, 8443, 19294-19344, 50000-65535 } counter queue num %d' 2>/dev/null", qnum));
    } else {
        system(sprintf("nft 'add rule inet tachyon_fuzzer output meta l4proto tcp tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } counter queue num %d' 2>/dev/null", qnum));
    }
    // Route hook with priority -155 (before TachyonTable's -150) marks test traffic with FUZZER_OUTBOUND_MARK (direct outbound mark)
    // This guarantees that TachyonTable's mangle_output immediately returns and test traffic goes DIRECT to WAN without Sing-box TProxy
    system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft add rule inet tachyon_fuzzer bypass_singbox meta mark %s counter return 2>/dev/null", FUZZER_FWMARK));
    system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } meta mark set meta mark | %s counter' 2>/dev/null", FUZZER_OUTBOUND_MARK));
    if (is_udp) {
        system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto udp udp dport { 80, 443, 19294-19344, 50000-65535 } meta mark set meta mark | %s counter' 2>/dev/null", FUZZER_OUTBOUND_MARK));
    }

    // ── Verify the queue rule actually landed ────────────────────────────────
    // Without it probes silently test a direct connection, defeating the purpose.
    // nft output format varies by version: "queue num N bypass" (older) vs
    // "queue flags bypass to N" (newer).  Match any qnum near the keyword.
    let verified = command_success(sprintf("nft list table inet tachyon_fuzzer 2>/dev/null | grep -q 'queue.*%d'", qnum));
    if (!verified) {
        log_fuzzer_message(sprintf("nftables queue rule verification failed for qnum=%d; rules may not have been applied", qnum));
    }
    return verified;
}

const TARGET_SUITES = {
    youtube_suite: {
        name: "YouTube Full Suite (Stream + CDN + Web)",
        urls: [
            { name: "GoogleVideo Stream CDN", url: "https://redirector.googlevideo.com/videoplayback", weight: 60, required: true, probe_kind: "streaming" },
            { name: "Static Assets (i.ytimg)", url: "https://i.ytimg.com/generate_204", weight: 15, required: false, probe_kind: "tls_http" },
            { name: "Web Interface", url: "https://www.youtube.com/", weight: 25, required: true, probe_kind: "tls_http" }
        ]
    },
    discord_suite: {
        name: "Discord Full Suite (Web Portal + API + Voice)",
        urls: [
            { name: "Discord Web Portal", url: "https://discord.com/", weight: 50, required: true, probe_kind: "tls_http" },
            { name: "Discord Gateway", url: "https://gateway.discord.gg/", weight: 25, required: true, probe_kind: "tls_http" },
            { name: "Discord Assets CDN", url: "https://media.discordapp.net/", weight: 25, required: false, probe_kind: "tls_http" }
        ]
    },
    twitch_suite: {
        name: "Twitch Live Suite (Web + HLS Video + CDN)",
        urls: [
            { name: "Web Portal", url: "https://www.twitch.tv", weight: 40, required: true, probe_kind: "tls_http" },
            { name: "Static Assets CDN", url: "https://static-cdn.jtvnw.net/", weight: 30, required: false, probe_kind: "tls_http" },
            { name: "HLS Usher API", url: "https://usher.ttvnw.net/", weight: 30, required: true, probe_kind: "tls_http" }
        ]
    },
    twitter_suite: {
        name: "X / Twitter Suite (Web + API + CDN)",
        urls: [
            { name: "X Web Portal", url: "https://x.com", weight: 40, required: true, probe_kind: "tls_http" },
            { name: "API Endpoint", url: "https://api.x.com/", weight: 30, required: true, probe_kind: "tls_http" },
            { name: "Twimg Media CDN", url: "https://pbs.twimg.com/", weight: 30, required: false, probe_kind: "tls_http" }
        ]
    },
    chatgpt_suite: {
        name: "ChatGPT / OpenAI Suite (Web + Static CDN)",
        urls: [
            { name: "ChatGPT Portal", url: "https://chatgpt.com", weight: 60, required: true, probe_kind: "tls_http" },
            { name: "Static Assets CDN", url: "https://cdn.oaistatic.com/", weight: 40, required: false, probe_kind: "tls_http" }
        ]
    },
    instagram_suite: {
        name: "Instagram / Meta Suite (Web + Static CDN)",
        urls: [
            { name: "Web Interface", url: "https://www.instagram.com", weight: 60, required: true, probe_kind: "tls_http" },
            { name: "CDN Static Assets", url: "https://static.cdninstagram.com/", weight: 40, required: false, probe_kind: "tls_http" }
        ]
    },
    telegram_suite: {
        name: "Telegram Suite (Web + API)",
        urls: [
            { name: "Web App", url: "https://web.telegram.org", weight: 50, required: true, probe_kind: "tls_http" },
            { name: "Bot API", url: "https://api.telegram.org", weight: 50, required: true, probe_kind: "tls_http" }
        ]
    },
    rutracker_suite: {
        name: "RuTracker Suite (HTTP / HTTPS)",
        urls: [
            { name: "Main Portal", url: "https://rutracker.org", weight: 60, required: true, probe_kind: "tls_http" },
            { name: "CDN Static Logo", url: "https://static.rutracker.cc/logo/logo-3.png", weight: 40, required: false, probe_kind: "tls_http" }
        ]
    }
};

const TARGET_URLS = {
    youtube_suite: "https://rr1.googlevideo.com/videoplayback",
    youtube: "https://rr1.googlevideo.com/videoplayback",
    youtube_web: "https://www.youtube.com/",
    discord_suite: "https://discord.com/",
    discord: "https://discord.com/",
    twitch_suite: "https://www.twitch.tv",
    twitch: "https://www.twitch.tv",
    twitter_suite: "https://x.com",
    twitter: "https://x.com",
    chatgpt_suite: "https://chatgpt.com",
    chatgpt: "https://chatgpt.com",
    instagram_suite: "https://www.instagram.com",
    instagram: "https://www.instagram.com",
    rutracker_suite: "https://rutracker.org",
    rutracker: "https://rutracker.org",
    telegram_suite: "https://web.telegram.org",
    telegram: "https://web.telegram.org",
    quic_http3: "https://www.google.com"
};

function resolve_target_url(target_key, custom_url) {
    if (custom_url && custom_url != "")
        return custom_url;
    return TARGET_URLS[target_key] || TARGET_URLS.youtube;
}

function resolve_target_urls_list(target_key, custom_url) {
    if (custom_url && custom_url != "") {
        let urls = split(custom_url, /[,\n]+/);
        let result = [];
        let idx = 0;
        for (let u in urls) {
            let trimmed = trim(as_string(u));
            if (trimmed == "") continue;
            idx++;
            push(result, {
                name: sprintf("Custom Target %d", idx),
                url: trimmed,
                weight: 100,
                required: true,
                probe_kind: "tls_http"
            });
        }
        if (length(result) > 0) return result;
        return [ { name: "Custom Target", url: custom_url, weight: 100, required: true, probe_kind: "tls_http" } ];
    }
    target_key = as_string(target_key || "youtube_suite");
    if (target_key == "quic_http3") {
        return [ { name: "Google QUIC Initial / HTTP3", url: "https://www.google.com", weight: 100, required: true, probe_kind: "quic" } ];
    }
    let suite = TARGET_SUITES[target_key];
    if (suite && suite.urls && length(suite.urls) > 0) {
        return suite.urls;
    }
    let single = TARGET_URLS[target_key] || TARGET_URLS.youtube;
    return [ { name: target_key, url: single, weight: 100, required: true, probe_kind: (target_key == "quic_http3" ? "quic" : "tls_http") } ];
}

function module_exports() {
    return {
        NFQUEUE_QNUM_ZAPRET,
        NFQUEUE_QNUM_ZAPRET2,
        FUZZER_FWMARK,
        FUZZER_OUTBOUND_MARK,
        KNOWN_BLOB_FILES,
        log_fuzzer_message,
        resolve_binary,
        get_zapret2_bin,
        get_zapret_bin,
        get_byedpi_bin,
        get_zapret2_lua_flags,
        has_timeout,
        get_timeout_prefix,
        wrap_cmd_timeout,
        run_bounded,
        wrap_probe_cmd,
        is_valid_public_ip,
        get_fuzzer_curl_dns_flags,
        get_resolved_host_flags,
        get_zapret2_blob_dir,
        resolve_zapret2_blobs,
        setup_fuzzer_direct_nftables,
        TARGET_SUITES,
        TARGET_URLS,
        resolve_target_url,
        resolve_target_urls_list
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: diagnostics/fuzzer/binaries.uc (library module, no CLI)\n");
exit(1);
