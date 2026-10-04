#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let ip = require("core.ip");
let speed = require("dns.speed_test");

// Only metadata for this job's names is retained. No PCAP or unrelated DNS log.
function capture_start(iface, token, dir) {
    let result = { status: "unavailable", scope: "wan_port_53", interface: iface, queries: 0 };
    if (match(common.as_string(iface), /^[a-zA-Z0-9_.:-]+$/) == null ||
        match(common.as_string(token), /^[a-zA-Z0-9-]{1,63}$/) == null)
        return result;
    if (!exec.run_success({ argv: ["sh", "-c", "command -v tcpdump >/dev/null && command -v timeout >/dev/null"], timeout: 2 }))
        return result;
    let ready = dir + "/capture-ready", output = dir + "/capture-matches", done = dir + "/capture-done";
    let capture = common.command_from_args(["timeout", "-s", "INT", "-k", "1", "7", "tcpdump", "-n", "-l", "-s", "512", "-i", iface,
        "(ip or ip6) and (udp or tcp) and dst port 53"]);
    let filter = common.command_from_args(["grep", "-F", "--", "." + token + ".bash.ws."]);
    let command = capture + " 2>" + common.shell_quote(ready) + " | " + filter + " >" + common.shell_quote(output) +
        "; printf done >" + common.shell_quote(done);
    exec.run_background({ argv: ["sh", "-c", command], env: { LC_ALL: "C" }, name: "dns-leak-capture" });
    for (let attempt = 0; attempt < 10; attempt++) {
        if (index(common.as_string(fs.readfile(ready)), "listening on") >= 0) {
            result.status = "running";
            result.ready = ready; result.output = output; result.done = done;
            return result;
        }
        if (fs.stat(done)) break;
        exec.run({ argv: ["sleep", "0.1"], timeout: 1 });
    }
    result.status = "capture_failed";
    return result;
}

function capture_result(text, token, ready, completed, observed) {
    let result = { status: "inconclusive", queries: 0, scope: "wan_port_53" };
    if (type(token) != "string" || match(token, /^[a-zA-Z0-9-]{1,63}$/) == null) return result;
    for (let line in split(common.as_string(text), "\n")) {
        if (index(line, "." + token + ".bash.ws.") >= 0 && match(line, /[[:space:]](A|AAAA)\?[[:space:]]/))
            result.queries++;
    }
    // A positive observation remains useful even if capture was incomplete.
    if (result.queries > 0) result.status = "plaintext_observed";
    else if (completed && observed && index(common.as_string(ready), "listening on") >= 0 &&
        match(common.as_string(ready), /(^|\n)0 packets dropped by kernel([[:space:]]|$)/))
        result.status = "not_observed";
    return result;
}

function capture_finish(capture, token, observed) {
    if (capture.status != "running") return capture;
    for (let attempt = 0; attempt < 9 && !fs.stat(capture.done); attempt++)
        exec.run({ argv: ["sleep", "1"], timeout: 2 });
    let result = capture_result(fs.readfile(capture.output), token, fs.readfile(capture.ready), fs.stat(capture.done) != null, observed);
    result.interface = capture.interface;
    return result;
}

function doh_target(config) {
    if (type(config) != "object" || type(config.dns) != "object") return null;
    for (let s in config.dns.servers || []) {
        if (type(s) != "object") continue;
        if (s.tag != "dns-server" || s.type != "https") continue;
        let tls = type(s.tls) == "object" ? s.tls : {};
        let host = common.as_string(tls.server_name || s.server);
        let upstream = common.as_string(s.server);
        if ((!ip.valid_ip(host) && !speed.valid_domain(lc(host))) ||
            (!ip.valid_ip(upstream) && !speed.valid_domain(lc(upstream)))) return null;
        let port = int(s.server_port || 443);
        let path = common.as_string(s.path || "/dns-query");
        if (port < 1 || port > 65535 || substr(path, 0, 1) != "/" || match(path, /[[:space:][:cntrl:]]/)) return null;
        let authority = ip.valid_ipv6(host) ? "[" + host + "]" : host;
        let result = { host: host, address: "https://" + authority + ":" + port + path,
            router_verification_disabled: tls.insecure == true, resolve: null, connect_to: null };
        if (host != upstream) {
            if (ip.valid_ip(upstream)) result.resolve = host + ":" + port + ":" + (ip.valid_ipv6(upstream) ? "[" + upstream + "]" : upstream);
            else result.connect_to = host + ":" + port + ":" + upstream + ":" + port;
        }
        return result;
    }
    return null;
}

function doh_result(status, report, body, query) {
    let fields = split(trim(common.as_string(report)), "|");
    let result = { status: "failed", scope: "independent_doh_probe", tls_verified: false, dns_answer_valid: false };
    if (status != 0 || length(fields) != 5 || fields[0] != "0" || fields[1] != "200" ||
        lc(trim(split(fields[2], ";")[0])) != "application/dns-message") return result;
    result.tls_verified = true;
    result.dns_answer_valid = speed.valid_answer(body, query);
    result.http_version = fields[3];
    result.status = result.dns_answer_valid ? "verified" : "invalid_dns_response";
    return result;
}

function check_doh(config, token, dir) {
    let target = doh_target(config);
    if (target == null) return { status: "unsupported", scope: "independent_doh_probe", tls_verified: false, dns_answer_valid: false };
    if (match(common.as_string(token), /^[a-zA-Z0-9-]{1,63}$/) == null)
        return { status: "unavailable", scope: "independent_doh_probe", tls_verified: false, dns_answer_valid: false };
    let query = speed.dns_query("5." + token + ".bash.ws");
    let encoded = replace(replace(replace(b64enc(query), /\+/g, "-"), /\//g, "_"), /=+$/, "");
    let address = target.address + (index(target.address, "?") >= 0 ? "&" : "?") + "dns=" + encoded;
    // Keep private DoH paths/profile IDs out of process arguments and output.
    let cfg = dir + "/tls-curl.conf", output = dir + "/tls-answer";
    if (!fs.writefile(cfg, "url = " + sprintf("%J", address) + "\n"))
        return { status: "unavailable", scope: "independent_doh_probe", tls_verified: false, dns_answer_valid: false };
    let args = ["curl", "--disable", "--silent", "--globoff", "--noproxy", "*", "--proto", "=https",
        "--connect-timeout", "3", "--max-time", "5", "--max-filesize", "65535", "--config", cfg,
        "--header", "accept: application/dns-message", "--header", "cache-control: no-cache",
        "--output", output, "--write-out", "%{ssl_verify_result}|%{http_code}|%{content_type}|%{http_version}|%{remote_ip}"];
    if (target.resolve) push(args, "--resolve", target.resolve);
    if (target.connect_to) push(args, "--connect-to", target.connect_to);
    let run = exec.run({ argv: args, timeout: 7 });
    let result = doh_result(run.status, run.output, fs.readfile(output), query);
    result.server = target.host;
    result.router_verification_disabled = target.router_verification_disabled;
    fs.unlink(cfg); fs.unlink(output);
    return result;
}

return { capture_start, capture_finish, capture_result, doh_target, doh_result, check_doh };
