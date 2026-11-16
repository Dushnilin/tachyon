#!/usr/bin/env ucode
//
// Fuzzer binaries, command bounding and probe bypass nftables setup.
//
// Extracted from diagnostics/fuzzer.uc. Locates tachyon-core, bounds blocking
// shell calls, caches DoH capability and sets up the direct-bypass nftables chain.
//

let fs = require("fs");
let common = require("core.common");
let fuzzer_runner = require("diagnostics.fuzzer_runner");

let as_string = common.as_string;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
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

function get_desync_bin() {
    return resolve_binary([
        getenv("TACHYON_CORE_BIN"),
        "/usr/bin/tachyon-core"
    ]);
}

function has_timeout() {
    if (_has_timeout == null)
        _has_timeout = (system("command -v timeout >/dev/null 2>&1 || [ -x /usr/bin/timeout ]") == 0);
    return _has_timeout;
}

function get_timeout_prefix(sec) {
    sec = sec || 8;
    return has_timeout() ? sprintf("timeout %d ", sec) : "";
}

// Shell watchdog: runs cmd bounded by sec seconds even when the `timeout`
// binary is unavailable or lacks -s/-k flags (BusyBox OpenWrt). Blocking
// forever on system()/pipe.read() wedges the whole fuzzer worker (deadline
// checks in ucode never get to run), so every blocking call must carry a hard
// wall-clock bound around the entire subshell.
const _WATCHDOG_SUBSHELL = "( ( %s ) & _bp=$!; ( trap 'kill -9 $_bs 2>/dev/null; exit 0' TERM INT; sleep %d & _bs=$!; wait $_bs 2>/dev/null; kill -STOP $_bp 2>/dev/null; pkill -9 -P $_bp 2>/dev/null; _kpids=\"$_bp\"; for _pass in 1 2; do _next=\"\"; for _cp in /proc/[0-9]*/stat; do [ -r \"$_cp\" ] || continue; IFS= read -r _line <\"$_cp\" 2>/dev/null || continue; _pid=\"${_cp#/proc/}\"; _pid=\"${_pid%%/stat}\"; case \" $_kpids$_next \" in *\" $_pid \"*) continue ;; esac; _tail=\"${_line##*) }\"; set -- $_tail; case \" $_kpids \" in *\" $2 \"*) _next=\"$_next $_pid\"; kill -STOP \"$_pid\" 2>/dev/null ;; esac; done; [ -n \"$_next\" ] || break; _kpids=\"$_kpids$_next\"; done; for _pid in $_kpids; do [ \"$_pid\" != \"$_bp\" ] && kill -9 \"$_pid\" 2>/dev/null; done; kill -9 $_bp 2>/dev/null ) </dev/null >/dev/null 2>/dev/null & _bw=$!; wait $_bp 2>/dev/null; _rc=$?; kill -TERM $_bw 2>/dev/null; kill -9 $_bw 2>/dev/null; wait $_bw 2>/dev/null; exit $_rc )";

function run_bounded(cmd, sec) {
    sec = sec || 8;
    return system(sprintf(_WATCHDOG_SUBSHELL, cmd, sec));
}

function wrap_probe_cmd(cmd, sec, pid_file) {
    sec = sec || 8;
    let bounded = sprintf(_WATCHDOG_SUBSHELL, cmd, sec);
    if (pid_file && pid_file != "")
        return sprintf("( echo $$ > %s; %s )", shell_quote(pid_file), bounded);
    return bounded;
}

function wrap_cmd_timeout(cmd, sec, pid_file) {
    return wrap_probe_cmd(cmd, sec, pid_file);
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
    if (_fuzzer_curl_dns_flags != null)
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

function format_resolve_flags(host, ip, port) {
    if (!ip || ip == "") return "";
    let flags = sprintf("--resolve %s:443:%s --resolve %s:80:%s ", host, ip, host, ip);
    if (port && port != "" && port != "443" && port != "80") {
        flags += sprintf("--resolve %s:%s:%s ", host, port, ip);
    }
    return flags;
}

function append_dns_candidate(dns_candidates, seen_dns, srv) {
    if (srv && !seen_dns[srv]) {
        push(dns_candidates, srv);
        seen_dns[srv] = true;
    }
}

function collect_isp_nameservers() {
    let list = [];
    try {
        let resolv_auto = fs.readfile("/tmp/resolv.conf.d/resolv.conf.auto");
        if (resolv_auto) {
            for (let line in split(resolv_auto, "\n")) {
                let m_ns = match(trim(line), /^nameserver[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
                if (m_ns && m_ns[1] && is_valid_public_ip(m_ns[1]))
                    push(list, m_ns[1]);
            }
        }
    } catch (e) {}
    return list;
}

function get_resolved_host_flags(url) {
    let m = match(as_string(url || ""), /^https?:\/\/([^\/:]+)(:([0-9]+))?/i);
    if (!m || !m[1]) return "";
    let host = m[1];
    let host_lc = lc(host);
    let port = m[3] || "";
    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) || index(host, ":") >= 0) return "";
    if (!fuzzer_runner.is_valid_hostname(host)) return "";
    if (exists(_fuzzer_host_cache, host))
        return format_resolve_flags(host, _fuzzer_host_cache[host], port);
    _fuzzer_host_cache[host] = "";

    // Do not use redirector.googlevideo.com/report_mapping here: the address on
    // the left of "=>" is the *client's* public IP (the router WAN address), not
    // a GGC cache node. Pinning googlevideo hosts to it made every YouTube probe
    // connect back to the router itself and time out (curl exit 28).

    let is_googlevideo = (host_lc == "googlevideo.com" || index(host_lc, ".googlevideo.com") >= 0);
    let safe_host = shell_quote(host);
    let resolve_gv_fallback = function() {
        let gv_flags = (host_lc != "redirector.googlevideo.com")
            ? get_resolved_host_flags("https://redirector.googlevideo.com/")
            : "";
        if (gv_flags == "") gv_flags = get_resolved_host_flags("https://googlevideo.com/");
        if (gv_flags == "") gv_flags = get_resolved_host_flags("https://www.youtube.com/");
        let m_ip = match(gv_flags, /:443:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
        return (m_ip && m_ip[1]) ? m_ip[1] : null;
    };
    let ip = null;
    if (match(host_lc, /^rr[0-9]+\.googlevideo\.com$/) != null) {
        ip = resolve_gv_fallback();
    }

    // 1. Primary: query router bootstrap DNS & ISP upstream DNS via UDP 53
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

    let isp_dns = collect_isp_nameservers();
    if (is_googlevideo) {
        // Resolve media cache hosts via ISP DNS first to hit operator-local nodes.
        for (let srv in isp_dns)
            append_dns_candidate(dns_candidates, seen_dns, srv);
        append_dns_candidate(dns_candidates, seen_dns, uci_bootstrap);
    } else {
        append_dns_candidate(dns_candidates, seen_dns, uci_bootstrap);
        for (let srv in isp_dns)
            append_dns_candidate(dns_candidates, seen_dns, srv);
    }

    // Add dependable fallback public nameservers
    for (let srv in [ "77.88.8.8", "8.8.8.8", "1.1.1.1" ])
        append_dns_candidate(dns_candidates, seen_dns, srv);

    if (!ip) {
        for (let srv in dns_candidates) {
            let np = fs.popen(wrap_probe_cmd(sprintf("nslookup %s %s 2>/dev/null", safe_host, srv), 3), "r");
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

    // 4. Fallback for regional googlevideo.com CDN nodes that are not in public DNS:
    // resolve redirector.googlevideo.com, googlevideo.com or www.youtube.com IP so curl
    // connects to Google's frontend while preserving the regional SNI in ClientHello.
    if (!ip && index(host_lc, ".googlevideo.com") >= 0 && host != "googlevideo.com") {
        ip = resolve_gv_fallback();
    }

    if (ip) {
        _fuzzer_host_cache[host] = ip;
        return format_resolve_flags(host, ip, port);
    }
    _fuzzer_host_cache[host] = "";
    return "";
}

function prewarm_targets_dns(urls_list) {
    if (type(urls_list) != "array")
        return;
    let seen = {};
    for (let item in urls_list) {
        let u = as_string(item ? (item.url || "") : "");
        let m = match(u, /^https?:\/\/([^\/:]+)(:([0-9]+))?/i);
        if (!m || !m[1]) continue;
        let k = m[1] + ":" + (m[3] || "");
        if (seen[k]) continue;
        seen[k] = true;
        get_resolved_host_flags(u);
    }
}

let _fuzzer_ip_cache = {};

function resolve_host_ipv4(host) {
    host = trim(as_string(host || ""));
    if (host == "") return null;
    if (is_valid_public_ip(host)) return host;
    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) || index(host, ":") >= 0) return null;
    if (!fuzzer_runner.is_valid_hostname(host)) return null;
    if (exists(_fuzzer_ip_cache, host))
        return _fuzzer_ip_cache[host];

    let flags = get_resolved_host_flags("https://" + host + "/");
    let m = match(flags, /:443:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
    let ip = (m && m[1] && is_valid_public_ip(m[1])) ? m[1] : null;
    _fuzzer_ip_cache[host] = ip;
    return ip;
}

function parse_udp_target_url(url) {
    let u = trim(as_string(url || ""));
    let m = match(u, /^udp:\/\/([^\/:]+)(:([0-9]{1,5}))?/);
    if (!m || !m[1]) return null;
    let host = m[1];
    let port = (m[3] && m[3] != "") ? int(m[3]) : 3478;
    if (port < 1 || port > 65535) port = 3478;
    let ip = resolve_host_ipv4(host);
    return {
        host: host,
        ip: ip || host,
        port: port
    };
}

function probe_udp_stun_cmd(host_ip, port, res_file) {
    let rf = shell_quote(res_file || (STATE_DIR + "/fuzzer_udp_res.bin"));
    let safe_ip = shell_quote(as_string(host_ip));
    let p = int(port) || 19302;
    return sprintf(
        "rm -f %s; read _u1 _ < /proc/uptime 2>/dev/null || _u1=0; " +
        "if [ -x /bin/bash ]; then printf 'exec 3<>/dev/udp/%%s/%%d && printf \"\\\\x00\\\\x01\\\\x00\\\\x00\\\\x21\\\\x12\\\\xa4\\\\x42tachyonstun1\" >&3 && dd bs=64 count=1 <&3 >%%s 2>/dev/null\\n' %s %d %s | /bin/bash 2>/dev/null; " +
        "elif command -v socat >/dev/null 2>&1; then printf '\\x00\\x01\\x00\\x00\\x21\\x12\\xa4\\x42tachyonstun1' | socat -T 2 - UDP:%s:%d >%s 2>/dev/null; fi; " +
        "read _u2 _ < /proc/uptime 2>/dev/null || _u2=\"$_u1\"; " +
        "_sz=$(wc -c <%s 2>/dev/null || echo 0); _hdr=$(hexdump -n 2 -e '2/1 \"%%02x\"' %s 2>/dev/null || echo ''); rm -f %s; " +
        "_dt=$(awk -v a=\"$_u1\" -v b=\"$_u2\" 'BEGIN{d=b-a; if(d<=0) d=0.02; printf \"%%.3f\", d}'); " +
        "if [ \"$_sz\" -ge 20 ] 2>/dev/null && [ \"$_hdr\" = \"0101\" ]; then printf '200\\t%%s\\t%%s\\t32768\\t%%d\\t%%s\\t1\\t0\\n' \"$_dt\" \"$_dt\" \"$_sz\" \"$_dt\"; " +
        "else printf '000\\t0.000\\t0.000\\t0\\t0\\t0.000\\t1\\t28\\n'; fi",
        rf, safe_ip, p, rf, safe_ip, p, rf, rf, rf, rf
    );
}

let _probe_port_seeded = false;

// Builds the probe curl command. Output: http_code, appconnect, starttransfer,
// speed, size, time_connect, tcp_up, exit. tcp_up is 1 (TCP handshake done),
// 0 (SYN never answered) or 2 (unknown).
//
// curl resets time_connect to 0 when a transfer times out, even if the TCP
// handshake completed and only TLS stalled (observed on a router: conntrack
// ESTABLISHED, 12 ClientHello retransmits, curl time_connect=0). OpenWrt's curl
// is built without verbose strings, so the log cannot tell either. Instead the
// probe pins curl to a random source-port window and reads the conntrack state
// of those ports afterwards: SYN_SENT means no SYN-ACK, anything else means TCP
// was up. The verbose log is kept as a secondary signal for full curl builds.
function probe_curl_cmd(extra_flags, target_flags, url, err_file, connect_timeout, max_time) {
    let math = require("math");
    if (!_probe_port_seeded) {
        math.srand(clock()[1] ^ int(fs.readlink("/proc/self") || 0));
        _probe_port_seeded = true;
    }
    let cto = int(connect_timeout) > 0 ? int(connect_timeout) : 4;
    let mto = int(max_time) > 0 ? int(max_time) : 6;
    let port_lo = 20000 + (math.rand() % 4000) * 10;
    let port_hi = port_lo + 7;
    let ef = shell_quote(err_file);
    return sprintf(
        "curl -v --local-port %d-%d %s%s-so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}\\t%%{size_download}\\t%%{time_connect}' --connect-timeout %d --max-time %d %s 2>%s; _rc=$?; " +
        "if grep -qE 'ALPN|Client hello|TLS handshake|SSL connection|Connected to|Established connection' %s 2>/dev/null; then _tcp=1; " +
        "elif [ -r /proc/net/nf_conntrack ]; then _tcp=$(awk -v a=%d -v b=%d '$3==\"tcp\"{sp=-1; for(i=7;i<=NF;i++) if($i ~ /^sport=/){sp=substr($i,7)+0; break} if(sp>=a && sp<=b){seen=1; if($6!=\"SYN_SENT\") up=1}} END{print up ? 1 : (seen ? 0 : 2)}' /proc/net/nf_conntrack 2>/dev/null); [ -n \"$_tcp\" ] || _tcp=2; " +
        "else _tcp=2; fi; rm -f %s; printf '\\t%%d\\t%%d\\n' $_tcp $_rc",
        port_lo, port_hi, extra_flags || "", target_flags || "", cto, mto, shell_quote(url), ef, ef, port_lo, port_hi, ef
    );
}

// Marks probe traffic with FUZZER_OUTBOUND_MARK so TachyonTable's mangle_output
// returns and it goes DIRECT to WAN. Only unmarked packets are touched: OR-ing
// the bypass bit onto a section mark would pull that traffic out of its
// production queue.
function add_bypass_core_chain(scope, with_udp) {
    scope = as_string(scope || "");
    system("nft 'add chain inet tachyon_fuzzer bypass_core { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_core meta mark & %s == %s counter return' 2>/dev/null", FUZZER_FWMARK, FUZZER_FWMARK));
    system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_core %smeta mark 0 meta l4proto tcp tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } meta mark set %s counter' 2>/dev/null", scope, FUZZER_OUTBOUND_MARK));
    if (with_udp) {
        system(sprintf("nft 'add rule inet tachyon_fuzzer bypass_core %smeta mark 0 meta l4proto udp udp dport { 80, 443, 3478-3481, 5000-5020, 19294-19344, 27015-27050, 50000-65535 } meta mark set %s counter' 2>/dev/null", scope, FUZZER_OUTBOUND_MARK));
    }
}

const TARGET_SUITES = {
    youtube_suite: {
        name: "YouTube Full Suite (Stream + CDN + Web)",
        urls: [
            { name: "GoogleVideo Stream CDN", url: "https://rr1.googlevideo.com/videoplayback", weight: 60, required: true, probe_kind: "streaming" },
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
    },
    cs2_faceit_suite: {
        name: "CS2 / Faceit / Cybershoke Suite (Web + API + UDP)",
        urls: [
            { name: "Faceit Web Portal", url: "https://www.faceit.com/", weight: 35, required: true, probe_kind: "tls_http" },
            { name: "Cybershoke CS2 Servers", url: "https://cybershoke.net/", weight: 30, required: true, probe_kind: "tls_http" },
            { name: "Steam SDR Relay Config (CS2)", url: "https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730", weight: 20, required: false, probe_kind: "tls_http" },
            { name: "Gaming STUN / UDP Session", url: "udp://stun.l.google.com:19302", weight: 15, required: false, probe_kind: "udp_stun" }
        ]
    },
    gaming_udp_suite: {
        name: "Gaming & Voice UDP Suite (STUN + Source)",
        urls: [
            { name: "Google STUN UDP (19302)", url: "udp://stun.l.google.com:19302", weight: 60, required: true, probe_kind: "udp_stun" },
            { name: "Cloudflare STUN UDP (3478)", url: "udp://stun.cloudflare.com:3478", weight: 40, required: false, probe_kind: "udp_stun" }
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
    cs2_faceit_suite: "https://www.faceit.com/",
    cs2_faceit: "https://www.faceit.com/",
    cybershoke: "https://cybershoke.net/",
    gaming_udp_suite: "udp://stun.l.google.com:19302",
    quic_http3: "https://www.google.com"
};

function resolve_target_url(target_key, custom_url) {
    target_key = trim(as_string(target_key || ""));
    let custom_parts = split(as_string(custom_url || ""), /[\r\n,;\t ]+/);
    if (index(target_key, ",") >= 0) {
        for (let part in split(target_key, ",")) {
            let k = trim(as_string(part));
            if (k == "") continue;
            if (k == "custom" && custom_url && custom_url != "") {
                for (let u in custom_parts) {
                    let norm = fuzzer_runner.normalize_target_url(u);
                    if (norm != "")
                        return norm;
                }
            }
            if (TARGET_URLS[k])
                return TARGET_URLS[k];
        }
    }
    if (custom_url && custom_url != "") {
        for (let u in custom_parts) {
            let norm = fuzzer_runner.normalize_target_url(u);
            if (norm != "")
                return norm;
        }
    }
    return TARGET_URLS[target_key] || TARGET_URLS.youtube;
}

function build_custom_targets_list(custom_url) {
    let urls = split(as_string(custom_url || ""), /[\r\n,;\t ]+/);
    let result = [];
    let seen = {};
    let idx = 0;
    for (let u in urls) {
        let norm = fuzzer_runner.normalize_target_url(u);
        if (norm == "" || seen[norm]) continue;
        seen[norm] = true;
        idx++;
        let is_udp_url = index(norm, "udp://") == 0;
        let hm = match(norm, /^(https?|udp):\/\/([^\/]+)/i);
        let disp = (hm && hm[2]) ? hm[2] : sprintf("Custom Target %d", idx);
        push(result, {
            name: disp,
            url: norm,
            weight: 100,
            required: true,
            probe_kind: is_udp_url ? "udp_stun" : "tls_http"
        });
    }
    if (length(result) > 0) return result;
    return [ { name: "Custom Target", url: fuzzer_runner.normalize_target_url(custom_url) || as_string(custom_url || ""), weight: 100, required: true, probe_kind: "tls_http" } ];
}

function resolve_single_target_urls(key, custom_url) {
    if (key == "custom" && custom_url && custom_url != "")
        return build_custom_targets_list(custom_url);
    if (key == "quic_http3")
        return [ { name: "Google QUIC Initial / HTTP3", url: "https://www.google.com", weight: 100, required: true, probe_kind: "quic" } ];
    let suite = TARGET_SUITES[key];
    if (suite && suite.urls && length(suite.urls) > 0)
        return suite.urls;
    let single = TARGET_URLS[key] || TARGET_URLS.youtube;
    let is_udp_url = index(as_string(single), "udp://") == 0;
    return [ { name: key, url: single, weight: 100, required: true, probe_kind: is_udp_url ? "udp_stun" : (key == "quic_http3" ? "quic" : "tls_http") } ];
}

function resolve_target_urls_list(target_key, custom_url) {
    target_key = trim(as_string(target_key || "youtube_suite"));
    if (index(target_key, ",") >= 0) {
        let keys_arr = split(target_key, ",");
        let combined = [];
        let seen = {};
        for (let raw_k in keys_arr) {
            let k = trim(as_string(raw_k));
            if (k == "") continue;
            let sub_list = resolve_single_target_urls(k, custom_url);
            for (let item in sub_list) {
                let sig = as_string(item.url) + "|" + as_string(item.probe_kind || "tls_http");
                if (seen[sig]) continue;
                seen[sig] = true;
                push(combined, item);
            }
        }
        if (length(combined) > 0)
            return combined;
    }
    if (custom_url && custom_url != "")
        return build_custom_targets_list(custom_url);
    return resolve_single_target_urls(target_key, custom_url);
}

function module_exports() {
    return {
        FUZZER_FWMARK,
        FUZZER_OUTBOUND_MARK,
        log_fuzzer_message,
        resolve_binary,
        get_desync_bin,
        has_timeout,
        get_timeout_prefix,
        wrap_cmd_timeout,
        run_bounded,
        wrap_probe_cmd,
        is_valid_public_ip,
        get_fuzzer_curl_dns_flags,
        get_resolved_host_flags,
        prewarm_targets_dns,
        resolve_host_ipv4,
        parse_udp_target_url,
        probe_udp_stun_cmd,
        probe_target_ips,
        target_scope_match,
        add_bypass_core_chain,
        probe_curl_cmd,
        TARGET_SUITES,
        TARGET_URLS,
        resolve_target_url,
        resolve_target_urls_list
    };
}

return module_exports();
