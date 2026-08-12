#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("uci");

let TARGET_DOMAINS = {
    youtube: "www.youtube.com",
    discord: "discord.com",
    telegram: "web.telegram.org",
    instagram: "www.instagram.com",
    twitter: "twitter.com",
    facebook: "www.facebook.com",
    rutracker: "rutracker.org",
    tiktok: "www.tiktok.com",
    google_ai: "gemini.google.com",
    openai: "chatgpt.com",
    github: "github.com",
    netflix: "www.netflix.com",
    russia_inside: "www.instagram.com"
};

function perform_curl_check(domain) {
    let url = "https://" + domain;
    let cmd = sprintf("curl -k -s -o /dev/null -w '%%{time_namelookup}|%%{time_connect}|%%{time_appconnect}|%%{time_starttransfer}|%%{time_total}|%%{http_code}|%%{remote_ip}' --connect-timeout 5 --max-time 10 %s", url);
    let f = fs.popen(cmd, "r");
    if (!f) return null;
    let result_str = f.read("all");
    let exit_code = f.close();
    
    // exit_code is shifted by 8 in popen close
    exit_code = exit_code / 256;
    
    let parts = split(result_str, "|");
    if (length(parts) < 7) {
        return { success: false, error: "curl_failed", exit_code: exit_code };
    }
    
    let time_namelookup = int(1000 * +(parts[0]));
    let time_connect = int(1000 * +(parts[1]));
    let time_appconnect = int(1000 * +(parts[2]));
    let time_starttransfer = int(1000 * +(parts[3]));
    let time_total = int(1000 * +(parts[4]));
    let http_code = int(parts[5]);
    let remote_ip = parts[6];
    
    let tcp_ms = time_connect > 0 ? time_connect - time_namelookup : 0;
    let tls_ms = time_appconnect > 0 ? time_appconnect - time_connect : 0;
    let http_ms = time_starttransfer > 0 ? time_starttransfer - time_appconnect : 0;
    
    let status_class = "OK";
    
    if (exit_code == 6) status_class = "DNS Error";
    else if (exit_code == 7 || exit_code == 28) status_class = "TCP Timeout/Refused";
    else if (exit_code == 35 || (exit_code == 0 && time_appconnect == 0 && time_connect > 0)) status_class = "TLS Reset";
    else if (exit_code != 0) status_class = "Error (" + exit_code + ")";
    else if (http_code == 403 || http_code == 451) status_class = "HTTP " + http_code;
    else if (http_code >= 200 && http_code < 400) status_class = "OK";
    else status_class = "HTTP " + http_code;

    return {
        success: exit_code == 0 && (http_code >= 200 && http_code < 400),
        status_class: status_class,
        dns_ms: time_namelookup,
        tcp_ms: tcp_ms,
        tls_ms: tls_ms,
        http_ms: http_ms,
        total_ms: time_total,
        http_code: http_code,
        remote_ip: remote_ip,
        exit_code: exit_code
    };
}

function process_sections() {
    let cursor = uci.cursor();
    cursor.load("tachyon");
    
    let results = [];
    
    cursor.foreach("tachyon", "section", function(s) {
        if (s.enabled != "1") return;
        
        let domains_to_check = [];
        
        if (type(s.community_lists) == "array") {
            for (let i = 0; i < length(s.community_lists); i++) {
                let list_name = s.community_lists[i];
                if (TARGET_DOMAINS[list_name]) {
                    push(domains_to_check, TARGET_DOMAINS[list_name]);
                }
            }
        } else if (type(s.community_lists) == "string") {
            if (TARGET_DOMAINS[s.community_lists]) {
                push(domains_to_check, TARGET_DOMAINS[s.community_lists]);
            }
        }
        
        let unique_domains = {};
        for (let i = 0; i < length(domains_to_check); i++) {
            unique_domains[domains_to_check[i]] = true;
        }
        
        for (let domain in keys(unique_domains)) {
            let label = s.label || s['.name'];
            let route_type = s.action || "direct";
            
            if (s.action == "zapret" && s.zapret_strategy) {
                route_type = "zapret (" + s.zapret_strategy + ")";
            } else if (s.action == "zapret2" && s.zapret2_strategy) {
                route_type = "zapret2 (" + s.zapret2_strategy + ")";
            } else if (s.action == "byedpi" && s.byedpi_strategy) {
                route_type = "byedpi (" + s.byedpi_strategy + ")";
            }
            
            let res = perform_curl_check(domain);
            let check_result = {
                section: label,
                route_type: route_type,
                domain: domain,
                ip: res ? res.remote_ip : "",
                dns_ms: res ? res.dns_ms : 0,
                tcp_ms: res ? res.tcp_ms : 0,
                tls_ms: res ? res.tls_ms : 0,
                http_ms: res ? res.http_ms : 0,
                status_class: res ? res.status_class : "Error",
                success: res ? res.success : false
            };
            push(results, check_result);
        }
    });
    
    print(sprintf("%J", results), "\n");
}

function process_custom_domain(domain) {
    let res = perform_curl_check(domain);
    let results = [{
        section: "Custom",
        route_type: "auto",
        domain: domain,
        ip: res ? res.remote_ip : "",
        dns_ms: res ? res.dns_ms : 0,
        tcp_ms: res ? res.tcp_ms : 0,
        tls_ms: res ? res.tls_ms : 0,
        http_ms: res ? res.http_ms : 0,
        status_class: res ? res.status_class : "Error",
        success: res ? res.success : false
    }];
    print(sprintf("%J", results), "\n");
}

if (ARGV[0] == "check-custom" && ARGV[1]) {
    process_custom_domain(ARGV[1]);
} else {
    process_sections();
}
