#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let command_output_from_args = common.command_output_from_args;
let command_status_from_args = common.command_status_from_args;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let option = common.option;
let list_option = common.list_option;
let normalize_status = common.normalize_status;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = getenv("TACHYON_UI_STATE_DIR") || "/var/run/tachyon";
const BENCHMARK_STATE_FILE = STATE_DIR + "/dns-benchmark-state.json";
const BENCHMARK_PID_FILE = STATE_DIR + "/dns-benchmark.pid";
const SERVICE_INIT = getenv("TACHYON_SERVICE_INIT") || "/etc/init.d/tachyon";

const CANDIDATE_SERVERS = [
    // --- Yandex DNS ---
    { id: "yandex_udp", provider: "Yandex", type: "udp", address: "77.88.8.8", ip: "77.88.8.8", tag: "Primary" },
    { id: "yandex_udp2", provider: "Yandex", type: "udp", address: "77.88.8.1", ip: "77.88.8.1", tag: "Secondary" },

    // --- Cloudflare DNS ---
    { id: "cloudflare_udp", provider: "Cloudflare", type: "udp", address: "1.1.1.1", ip: "1.1.1.1", tag: "Primary" },
    { id: "cloudflare_udp2", provider: "Cloudflare", type: "udp", address: "1.0.0.1", ip: "1.0.0.1", tag: "Secondary" },
    { id: "cloudflare_doh", provider: "Cloudflare", type: "doh", address: "https://cloudflare-dns.com/dns-query", ip: "1.1.1.1", tag: "DoH Encrypted" },

    // --- Google Public DNS ---
    { id: "google_udp", provider: "Google", type: "udp", address: "8.8.8.8", ip: "8.8.8.8", tag: "Primary" },
    { id: "google_udp2", provider: "Google", type: "udp", address: "8.8.4.4", ip: "8.8.4.4", tag: "Secondary" },
    { id: "google_doh", provider: "Google", type: "doh", address: "https://dns.google/dns-query", ip: "8.8.8.8", tag: "DoH Encrypted" },

    // --- AdGuard DNS ---
    { id: "adguard_udp", provider: "AdGuard", type: "udp", address: "94.140.14.14", ip: "94.140.14.14", tag: "Default" },
    { id: "adguard_doh", provider: "AdGuard", type: "doh", address: "https://dns.adguard-dns.com/dns-query", ip: "94.140.14.14", tag: "DoH AdBlock" },

    // --- Comss.one DNS ---
    { id: "comss_udp", provider: "Comss.one", type: "udp", address: "92.223.109.31", ip: "92.223.109.31", tag: "Anti-Censorship" },
    { id: "comss_doh", provider: "Comss.one", type: "doh", address: "https://dns.comss.one/dns-query", ip: "92.223.109.31", tag: "DoH Anti-Censorship" },

    // --- Control D ---
    { id: "controld_udp", provider: "Control D", type: "udp", address: "76.76.2.0", ip: "76.76.2.0", tag: "Unfiltered" },
    { id: "controld_doh", provider: "Control D", type: "doh", address: "https://freedns.controld.com/p0", ip: "76.76.2.0", tag: "DoH Encrypted" },

    // --- Quad9 ---
    { id: "quad9_udp", provider: "Quad9", type: "udp", address: "9.9.9.9", ip: "9.9.9.9", tag: "Primary" },
    { id: "quad9_doh", provider: "Quad9", type: "doh", address: "https://dns.quad9.net/dns-query", ip: "9.9.9.9", tag: "DoH Secure" },

    // --- Mullvad DNS ---
    { id: "mullvad_udp", provider: "Mullvad", type: "udp", address: "194.242.2.2", ip: "194.242.2.2", tag: "Privacy" },
    { id: "mullvad_doh", provider: "Mullvad", type: "doh", address: "https://dns.mullvad.net/dns-query", ip: "194.242.2.2", tag: "DoH Privacy" },

    // --- OpenDNS ---
    { id: "opendns_udp", provider: "OpenDNS", type: "udp", address: "208.67.222.222", ip: "208.67.222.222", tag: "Standard" },
    { id: "opendns_doh", provider: "OpenDNS", type: "doh", address: "https://doh.opendns.com/dns-query", ip: "208.67.222.222", tag: "DoH Encrypted" }
];

const TEST_DOMAINS = [
    "google.com",
    "yandex.ru"
];

function now_seconds() {
    let stamp = clock();
    return stamp ? stamp[0] : 0;
}

let tool_cache = {};
function has_tool(name) {
    name = as_string(name);
    if (tool_cache[name] != null)
        return tool_cache[name];
    let out = command_output_from_args([ "which", name ]);
    let exists = length(out) > 0;
    tool_cache[name] = exists;
    return exists;
}

function url_host(url) {
    let m = match(as_string(url), /^https?:\/\/([^\/:]+)/);
    return m ? m[1] : "";
}

function domain_to_doh_b64(domain) {
    domain = trim(as_string(domain));
    if (domain == "google.com") return "AAABAAABAAAAAAAABmdvb2dsZQNjb20AAAEAAQ";
    if (domain == "cloudflare.com") return "AAABAAABAAAAAAAACmNsb3VkZmxhcmUDY29tAAABAAE";
    if (domain == "wikipedia.org") return "AAABAAABAAAAAAAACXdpa2lwZWRpYQNvcmcAAAEAAQ";
    if (domain == "yandex.ru") return "AAABAAABAAAAAAAABnlhbmRleAJydQAAAQAB";
    if (domain == "example.com") return "AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE";

    let labels = split(replace(domain, /^\.+|\.+$/, ""), ".");
    let bytes = [ 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 ];
    for (let label in labels) {
        if (label == "") continue;
        push(bytes, length(label));
        for (let i = 0; i < length(label); i++)
            push(bytes, ord(label, i));
    }
    push(bytes, 0, 0, 1, 0, 1);

    let b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let res = "";
    let i = 0;
    while (i < length(bytes)) {
        let b0 = bytes[i];
        let b1 = i + 1 < length(bytes) ? bytes[i + 1] : 0;
        let b2 = i + 2 < length(bytes) ? bytes[i + 2] : 0;

        let c0 = (b0 >> 2) & 0x3f;
        let c1 = (((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)) & 0x3f;
        let c2 = (((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)) & 0x3f;
        let c3 = b2 & 0x3f;

        res += substr(b64chars, c0, 1);
        res += substr(b64chars, c1, 1);
        if (i + 1 < length(bytes))
            res += substr(b64chars, c2, 1);
        if (i + 2 < length(bytes))
            res += substr(b64chars, c3, 1);
        i += 3;
    }
    return res;
}

let resolved_hosts_cache = {};

// Resolves a hostname via a specific bootstrap UDP server with cache and fast fallback.
function resolve_host_via_bootstrap(host, bootstrap_ip, fallback_ip) {
    host = as_string(host);
    bootstrap_ip = as_string(bootstrap_ip);
    fallback_ip = as_string(fallback_ip);

    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/))
        return host;

    let cache_key = host + "@" + bootstrap_ip;
    if (resolved_hosts_cache[cache_key])
        return resolved_hosts_cache[cache_key];

    if (has_tool("dig")) {
        let output = command_output_from_args([
            "dig", "@" + bootstrap_ip, host, "A", "+short", "+time=1", "+tries=1"
        ]);
        if (length(output) > 0) {
            let lines = split(output, "\n");
            for (let line in lines) {
                line = trim(line);
                if (match(line, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
                    resolved_hosts_cache[cache_key] = line;
                    return line;
                }
            }
        }
    }

    if (has_tool("nslookup")) {
        let output = command_output_from_args([ "nslookup", "-timeout=2", "-type=a", host, bootstrap_ip ]);
        if (length(output) == 0 || index(output, "timed out") >= 0)
            output = command_output_from_args([ "nslookup", host, bootstrap_ip ]);
        if (length(output) > 0) {
            let lines = split(output, "\n");
            for (let line in lines) {
                let m = match(line, /Address(?:es)?(?:[ \t]+[0-9]+)?:[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
                if (m && m[1] != null && m[1] != bootstrap_ip) {
                    resolved_hosts_cache[cache_key] = m[1];
                    return m[1];
                }
            }
            let m2 = match(output, /Name:[ \t]+[^\n]+\nAddress(?:[ \t]+[0-9]+)?:[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
            if (m2 && m2[1] != null && m2[1] != bootstrap_ip) {
                resolved_hosts_cache[cache_key] = m2[1];
                return m2[1];
            }
        }
    }

    if (fallback_ip != "") {
        resolved_hosts_cache[cache_key] = fallback_ip;
        return fallback_ip;
    }

    return null;
}

// Probes a UDP DNS server with `dig` (primary) or `nslookup` (fallback).
// Returns latency in milliseconds, or -1 on failure.
function probe_udp(server_ip, domain) {
    server_ip = as_string(server_ip);
    domain = as_string(domain);

    if (has_tool("dig")) {
        let output = command_output_from_args([
            "dig", "@" + server_ip, domain, "A", "+time=1", "+tries=1", "+stats"
        ]);
        if (length(output) > 0) {
            if (index(output, "status: NOERROR") >= 0 || index(output, "status: NXDOMAIN") >= 0) {
                let m = match(output, /;; Query time:[ \t]+([0-9]+)[ \t]+msec/);
                if (m && m[1] != null) {
                    let ms = int(m[1]);
                    return ms >= 0 ? ms : 0;
                }
            }
        }
    }

    if (has_tool("nslookup")) {
        // Fast path: BusyBox / BIND nslookup with -timeout=2 -type=a to query ONLY IPv4 A record
        // and avoid the 2.5s AAAA retransmit timeout bug on dual-stack/IPv4 networks.
        let t0 = clock();
        let output = command_output_from_args([ "nslookup", "-timeout=2", "-type=a", domain, server_ip ]);
        let t1 = clock();

        // If the query explicitly timed out or failed to reach the server, do not re-run
        if (index(output, "timed out") >= 0 || index(output, "no servers could be reached") >= 0 || index(output, "can't find") >= 0)
            return -1;

        if (length(output) > 0) {
            let m_time = match(output, /Query #[0-9]+ completed in ([0-9]+)ms/);
            if (m_time && m_time[1] != null)
                return int(m_time[1]);

            if (index(output, "Name:") >= 0) {
                if (t0 && t1) {
                    let elapsed_ms = (t1[0] - t0[0]) * 1000 + int((t1[1] - t0[1]) / 1000000);
                    return elapsed_ms >= 0 ? elapsed_ms : 0;
                }
            }
        }

        // Fallback for minimal legacy BusyBox without -timeout or -type options (if output was empty)
        t0 = clock();
        let status = command_status_from_args([ "nslookup", domain, server_ip ]);
        t1 = clock();
        if (status == 0 && t0 && t1) {
            let elapsed_ms = (t1[0] - t0[0]) * 1000 + int((t1[1] - t0[1]) / 1000000);
            return elapsed_ms >= 0 ? elapsed_ms : 0;
        }
    }

    return -1;
}

// Probes a DoH DNS server using `curl` with standard RFC 8484 DNS wireformat.
// Returns latency in milliseconds, or -1 on failure.
function probe_doh(server, domain, resolved_ip) {
    let doh_url = as_string(type(server) == "object" ? server.address : server);
    domain = as_string(domain);
    let host = url_host(doh_url);
    resolved_ip = as_string(resolved_ip);

    let b64 = domain_to_doh_b64(domain);
    let query_url = doh_url + (index(doh_url, "?") >= 0 ? "&" : "?") + "dns=" + b64;

    let args = [
        "curl", "-s", "-k", "-m", "2", "--connect-timeout", "2", "-w", "\n%{http_code} %{time_total}",
        "-H", "accept: application/dns-message, application/dns-json"
    ];

    if (host != "" && resolved_ip != "") {
        push(args, "--resolve", host + ":443:" + resolved_ip);
        push(args, "--resolve", host + ":80:" + resolved_ip);
    }
    push(args, query_url);

    let output = command_output_from_args(args);
    if (length(output) > 0) {
        let lines = split(output, "\n");
        let last_line = length(lines) > 0 ? lines[length(lines) - 1] : "";
        if (last_line == "" && length(lines) > 1)
            last_line = lines[length(lines) - 2];

        let m = match(last_line, /^([0-9]{3})[ \t]+([0-9.]+)/);
        if (m && m[1] == "200" && m[2] != null) {
            let total_sec = double(m[2]);
            let ms = int(total_sec * 1000);
            return ms >= 0 ? ms : 0;
        }
    }

    return -1;
}

function test_candidate(server, domains, bootstrap_ips) {
    domains = array_or_empty(domains);
    let total_ms = 0;
    let success_count = 0;
    let total_rounds = length(domains);

    let resolved_ip = "";
    if (server.type == "doh") {
        let host = url_host(server.address);
        bootstrap_ips = array_or_empty(bootstrap_ips);
        for (let b_ip in bootstrap_ips) {
            b_ip = as_string(b_ip);
            if (b_ip != "") {
                resolved_ip = resolve_host_via_bootstrap(host, b_ip, server.ip || "");
                if (resolved_ip != null && resolved_ip != "")
                    break;
            }
        }
        if (resolved_ip == "" || resolved_ip == null)
            resolved_ip = as_string(server.ip || "");
    }

    for (let domain in domains) {
        let ms = -1;
        if (server.type == "doh")
            ms = probe_doh(server, domain, resolved_ip);
        else
            ms = probe_udp(server.ip || server.address, domain);

        if (ms >= 0) {
            total_ms += ms;
            success_count++;
        }
    }

    let result = {
        id: server.id,
        provider: server.provider,
        type: server.type,
        address: server.address,
        ip: server.ip,
        tag: server.tag,
        latency: -1,
        lossPct: 100,
        status: "failed",
        score: 99999
    };

    if (success_count > 0) {
        let avg_latency = int(total_ms / success_count);
        let loss_pct = int(((total_rounds - success_count) * 100) / total_rounds);
        let score = avg_latency + (loss_pct * 5);

        result.latency = avg_latency;
        result.lossPct = loss_pct;
        result.score = score;

        if (avg_latency < 35 && loss_pct == 0)
            result.status = "excellent";
        else if (avg_latency < 75 && loss_pct <= 25)
            result.status = "good";
        else if (avg_latency < 150 && loss_pct <= 50)
            result.status = "fair";
        else if (loss_pct < 100)
            result.status = "slow";
        else
            result.status = "failed";
    }

    return result;
}

function select_diverse_servers(candidates, max_count, max_latency, max_loss) {
    max_count = int(max_count || 2);
    max_latency = int(max_latency || 400);
    max_loss = int(max_loss || 25);

    let selected = [];
    let seen_providers = {};

    for (let c in candidates) {
        if (c.latency < 0 || c.status == "failed" || c.lossPct > max_loss || c.latency > max_latency)
            continue;

        let prov = as_string(c.provider);
        if (!seen_providers[prov]) {
            seen_providers[prov] = true;
            push(selected, c);
            if (length(selected) >= max_count)
                break;
        }
    }

    if (length(selected) < max_count) {
        for (let c in candidates) {
            if (c.latency < 0 || c.status == "failed" || c.lossPct > max_loss || c.latency > max_latency)
                continue;

            let addr = as_string(c.address || c.ip);
            let already = false;
            for (let s in selected) {
                if ((s.address || s.ip) == addr) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                push(selected, c);
                if (length(selected) >= max_count)
                    break;
            }
        }
    }

    return selected;
}

function compute_recommendation(results) {
    results = array_or_empty(results);
    let working = [];
    for (let r in results) {
        if (r.latency >= 0 && r.status != "failed")
            push(working, r);
    }

    // Default failsafe recommendation
    if (length(working) == 0) {
        return {
            dns_type: "udp",
            dns_server: [ "77.88.8.8", "1.1.1.1" ],
            bootstrap_dns_server: [ "77.88.8.8", "1.1.1.1" ],
            dns_fallback_server: [ "1.0.0.1", "77.88.8.1" ],
            dns_upstream_mode: "parallel",
            reason: "All probed DNS servers timed out or failed. Applied safe Yandex & Cloudflare defaults."
        };
    }

    let working_udp = [];
    let working_doh = [];

    for (let r in working) {
        if (r.type == "udp")
            push(working_udp, r);
        else if (r.type == "doh")
            push(working_doh, r);
    }

    working_udp = sort(working_udp, function(a, b) { return a.score - b.score; });
    working_doh = sort(working_doh, function(a, b) { return a.score - b.score; });

    // Select top 2 bootstrap UDP servers from distinct providers
    let top_bootstrap = select_diverse_servers(working_udp, 2, 250, 25);
    if (length(top_bootstrap) == 0) {
        top_bootstrap = [ { address: "77.88.8.8", ip: "77.88.8.8", provider: "Yandex", latency: 15 } ];
    }
    let bootstrap_ips = [];
    for (let b in top_bootstrap)
        push(bootstrap_ips, b.ip || b.address);

    // Select top 2 fallback UDP servers (prefer servers not in bootstrap or distinct)
    let remaining_udp = [];
    for (let u in working_udp) {
        let in_boot = false;
        for (let b in top_bootstrap) {
            if (b.address == u.address || b.ip == u.ip) {
                in_boot = true;
                break;
            }
        }
        if (!in_boot)
            push(remaining_udp, u);
    }
    let top_fallback = select_diverse_servers(remaining_udp, 2, 350, 25);
    if (length(top_fallback) == 0) {
        top_fallback = select_diverse_servers(working_udp, 2, 350, 50);
    }
    let fallback_ips = [];
    for (let f in top_fallback)
        push(fallback_ips, f.ip || f.address);
    if (length(fallback_ips) == 0)
        fallback_ips = [ "1.0.0.1", "77.88.8.1" ];

    let selected_type = "udp";
    let selected_dns_server = [];
    let top_udp_primary = select_diverse_servers(working_udp, 2, 200, 25);
    for (let u in top_udp_primary)
        push(selected_dns_server, u.address || u.ip);
    let reason = "Selected fast UDP servers (" + join(", ", selected_dns_server) + ") as fallback because encrypted DoH is unavailable";

    // ALWAYS PRIORITIZE ENCRYPTED DoH AS PRIMARY DNS
    // Encrypted DNS prevents ISP interception, DNS hijacking, poisoning, and MITM.
    let top_doh = select_diverse_servers(working_doh, 2, 350, 25);
    if (length(top_doh) > 0) {
        selected_type = "doh";
        selected_dns_server = [];
        let doh_names = [];
        for (let d in top_doh) {
            push(selected_dns_server, d.address);
            push(doh_names, sprintf("%s (%dms)", d.provider, d.latency));
        }
        reason = "Selected multiple encrypted DoH servers [" + join(", ", doh_names) + "] for maximum privacy and redundancy, with [" + join(", ", bootstrap_ips) + "] bootstrap DNS";
    }

    return {
        dns_type: selected_type,
        dns_server: selected_dns_server,
        bootstrap_dns_server: bootstrap_ips,
        dns_fallback_server: fallback_ips,
        dns_upstream_mode: "parallel",
        reason: reason
    };
}

function run_benchmark(on_progress) {
    let udp_candidates = [];
    let doh_candidates = [];
    for (let s in CANDIDATE_SERVERS) {
        if (s.type == "udp")
            push(udp_candidates, s);
        else if (s.type == "doh")
            push(doh_candidates, s);
    }

    let total = length(udp_candidates) + length(doh_candidates);
    let current_index = 0;
    let results = [];

    // --- Phase 1: Benchmark UDP Bootstrap Candidates ---
    let udp_results = [];
    for (let i = 0; i < length(udp_candidates); i++) {
        let server = udp_candidates[i];
        if (on_progress)
            on_progress(current_index, total, server.provider + " (UDP)", null);

        let res = test_candidate(server, TEST_DOMAINS, []);
        push(udp_results, res);
        push(results, res);
        current_index++;

        if (on_progress)
            on_progress(current_index, total, server.provider + " (UDP)", res);
    }

    // Find best and secondary working UDP bootstrap servers for Phase 2
    let working_udp = [];
    for (let r in udp_results) {
        if (r.latency >= 0 && r.status != "failed")
            push(working_udp, r);
    }
    working_udp = sort(working_udp, function(a, b) { return a.score - b.score; });

    let primary_bootstrap_ip = "77.88.8.8";
    let secondary_bootstrap_ip = "1.1.1.1";
    if (length(working_udp) > 0)
        primary_bootstrap_ip = working_udp[0].ip || working_udp[0].address;
    if (length(working_udp) > 1) {
        for (let u in working_udp) {
            if (u.provider != working_udp[0].provider) {
                secondary_bootstrap_ip = u.ip || u.address;
                break;
            }
        }
    }
    let bootstrap_ips = [ primary_bootstrap_ip, secondary_bootstrap_ip ];

    // --- Phase 2: Benchmark Encrypted DoH Servers via Verified Bootstrap DNS ---
    for (let i = 0; i < length(doh_candidates); i++) {
        let server = doh_candidates[i];
        if (on_progress)
            on_progress(current_index, total, server.provider + " (DoH)", null);

        let res = test_candidate(server, TEST_DOMAINS, bootstrap_ips);
        push(results, res);
        current_index++;

        if (on_progress)
            on_progress(current_index, total, server.provider + " (DoH)", res);
    }

    // Sort by score ascending (lowest score is best)
    results = sort(results, function(a, b) {
        return a.score - b.score;
    });

    let recommendation = compute_recommendation(results);
    return {
        results: results,
        recommendation: recommendation
    };
}

function apply_recommendation(rec) {
    if (!rec || type(rec) != "object")
        return false;

    let cursor = uci_core.cursor();
    if (!cursor)
        return false;

    if (rec.dns_type)
        cursor.set(CONFIG_NAME, "settings", "dns_type", as_string(rec.dns_type));
    if (rec.dns_server)
        cursor.set(CONFIG_NAME, "settings", "dns_server", rec.dns_server);
    if (rec.bootstrap_dns_server)
        cursor.set(CONFIG_NAME, "settings", "bootstrap_dns_server", rec.bootstrap_dns_server);
    if (rec.dns_fallback_server)
        cursor.set(CONFIG_NAME, "settings", "dns_fallback_server", rec.dns_fallback_server);
    if (rec.dns_upstream_mode)
        cursor.set(CONFIG_NAME, "settings", "dns_upstream_mode", as_string(rec.dns_upstream_mode));

    cursor.commit(CONFIG_NAME);

    // Restart tachyon service to apply immediately
    command_success_from_args([ SERVICE_INIT, "restart" ]);
    return true;
}

// --- CLI Output Helpers ---

function print_cli_table(benchmark_data) {
    let results = benchmark_data.results;
    let rec = benchmark_data.recommendation;

    print("\n========================================================================================\n");
    print("                              TACHYON DNS BENCHMARK RESULTS                             \n");
    print("========================================================================================\n");
    printf("%-14s | %-6s | %-42s | %-8s | %-6s | %-10s\n", "Provider", "Type", "Address", "Latency", "Loss", "Rating");
    print("----------------------------------------------------------------------------------------\n");

    for (let r in results) {
        let lat_str = r.latency >= 0 ? sprintf("%d ms", r.latency) : "TIMEOUT";
        let loss_str = sprintf("%d%%", r.lossPct);
        let rating = r.status == "excellent" ? "EXCELLENT" :
                     r.status == "good"      ? "GOOD" :
                     r.status == "fair"      ? "FAIR" :
                     r.status == "slow"      ? "SLOW" : "FAILED";

        printf("%-14s | %-6s | %-42s | %-8s | %-6s | %-10s\n",
            substr(r.provider, 0, 14),
            r.type,
            substr(r.address, 0, 42),
            lat_str,
            loss_str,
            rating
        );
    }
    print("========================================================================================\n\n");

    print("⚡ RECOMMENDED TACHYON DNS CONFIGURATION:\n");
    print("  • DNS Type:              ", rec.dns_type, "\n");
    print("  • Primary DNS:           ", join(", ", rec.dns_server), "\n");
    print("  • Bootstrap DNS:         ", join(", ", rec.bootstrap_dns_server), "\n");
    print("  • Fallback DNS:          ", join(", ", rec.dns_fallback_server), "\n");
    print("  • Upstream Mode:         ", rec.dns_upstream_mode, "\n");
    print("  • Analysis:              ", rec.reason, "\n\n");
}

// --- Background / UI Async Engine ---

function write_state(state) {
    command_success_from_args([ "mkdir", "-p", STATE_DIR ]);
    return write_json_file(BENCHMARK_STATE_FILE, state);
}

function read_state() {
    let data = read_json_file(BENCHMARK_STATE_FILE);
    return type(data) == "object" ? data : null;
}

function start_async() {
    let existing = read_state();
    if (existing && existing.running === true) {
        let age = now_seconds() - (existing.started_at || 0);
        if (age < 90) {
            print(sprintf("%J\n", { success: true, message: "DNS benchmark is already running", state: existing }));
            return 0;
        }
    }

    let initial_state = {
        running: true,
        progress: 0,
        current_server: "Starting benchmark...",
        results: [],
        recommendation: null,
        error: null,
        started_at: now_seconds(),
        finished_at: null
    };
    write_state(initial_state);

    // Fork async background worker
    let worker_cmd = sprintf("TACHYON_LIB=%s ucode -L %s %s/dns/benchmark.uc worker >/dev/null 2>&1 & echo $!",
        shell_quote(LIB_DIR), shell_quote(LIB_DIR), LIB_DIR);

    let pipe = fs.popen(worker_cmd, "r");
    if (pipe) {
        let pid = trim(as_string(pipe.read("all")));
        pipe.close();
        if (pid != "")
            fs.writefile(BENCHMARK_PID_FILE, pid);
    }

    print(sprintf("%J\n", { success: true, message: "DNS benchmark started", running: true }));
    return 0;
}

function run_worker() {
    let state = {
        running: true,
        progress: 0,
        current_server: "Initializing...",
        results: [],
        recommendation: null,
        error: null,
        started_at: now_seconds(),
        finished_at: null
    };
    write_state(state);

    let benchmark_data = run_benchmark(function(completed, total, current_name, latest_result) {
        state.progress = int((completed * 100) / total);
        state.current_server = current_name;
        if (latest_result)
            push(state.results, latest_result);
        write_state(state);
    });

    state.running = false;
    state.progress = 100;
    state.current_server = "Completed";
    state.results = benchmark_data.results;
    state.recommendation = benchmark_data.recommendation;
    state.finished_at = now_seconds();
    write_state(state);

    try { fs.unlink(BENCHMARK_PID_FILE); } catch(e) {}
    return 0;
}

function stop_benchmark() {
    let pid_str = fs.readfile(BENCHMARK_PID_FILE);
    if (pid_str) {
        let pid = int(trim(as_string(pid_str)));
        if (pid > 0)
            command_status_from_args([ "kill", "-9", as_string(pid) ]);
        try { fs.unlink(BENCHMARK_PID_FILE); } catch(e) {}
    }

    let state = read_state() || {};
    state.running = false;
    state.error = "Benchmark stopped by user";
    state.finished_at = now_seconds();
    write_state(state);

    print(sprintf("%J\n", { success: true, message: "Benchmark stopped" }));
    return 0;
}

function get_status() {
    let state = read_state();
    if (!state) {
        state = {
            running: false,
            progress: 0,
            current_server: "",
            results: [],
            recommendation: null,
            error: null,
            started_at: 0,
            finished_at: null
        };
    }
    print(sprintf("%J\n", state));
    return 0;
}

function apply_from_state() {
    let state = read_state();
    if (!state || !state.recommendation) {
        print(sprintf("%J\n", { success: false, error: "No benchmark recommendation available to apply" }));
        return 1;
    }

    let ok = apply_recommendation(state.recommendation);
    if (ok)
        print(sprintf("%J\n", { success: true, message: "Recommended DNS configuration applied and service restarted", recommendation: state.recommendation }));
    else
        print(sprintf("%J\n", { success: false, error: "Failed to apply DNS configuration to UCI" }));
    return ok ? 0 : 1;
}

// --- CLI Dispatcher ---

let mode = ARGV[0] || "";

if (mode == "benchmark") {
    let json_mode = (ARGV[1] == "--json");
    let data = run_benchmark(null);
    if (json_mode)
        print(sprintf("%J\n", data));
    else
        print_cli_table(data);
    exit(0);
}
else if (mode == "autotune") {
    let apply_flag = (ARGV[1] == "--apply" || ARGV[1] == "-a");
    let data = run_benchmark(null);
    print_cli_table(data);
    if (apply_flag) {
        print("Applying recommended DNS configuration...\n");
        if (apply_recommendation(data.recommendation))
            print("✓ Settings saved to /etc/config/tachyon and service restarted successfully.\n");
        else
            print("✗ Failed to apply settings.\n");
    } else {
        print("Tip: Run `tachyon dns_autotune --apply` to automatically save and activate these settings.\n");
    }
    exit(0);
}
else if (mode == "benchmark_async" || mode == "benchmark-async") {
    exit(start_async());
}
else if (mode == "worker") {
    exit(run_worker());
}
else if (mode == "benchmark_status" || mode == "benchmark-status") {
    exit(get_status());
}
else if (mode == "benchmark_stop" || mode == "benchmark-stop") {
    exit(stop_benchmark());
}
else if (mode == "benchmark_apply" || mode == "benchmark-apply") {
    exit(apply_from_state());
}

return {
    CANDIDATE_SERVERS,
    TEST_DOMAINS,
    probe_udp,
    probe_doh,
    test_candidate,
    compute_recommendation,
    run_benchmark,
    apply_recommendation
};
