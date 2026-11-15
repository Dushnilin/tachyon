#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ucode -L "$TACHYON_LIB" - <<'UC'
let plus = require("service.smart_detect_plus");

function assert(ok, msg) {
    if (!ok) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

let fake_nslookup =
    "Server:         77.88.8.8\n" +
    "Address:        77.88.8.8:53\n" +
    "\n" +
    "Name:      blocked.example.com\n" +
    "Address 1: 198.18.0.42\n" +
    "Address 2: fc00::123\n" +
    "Address 3: 127.0.0.1\n" +
    "Address 4: 2001:db8::2\n" +
    "Address 5: 93.184.216.34\n";

let parsed = plus.parse_nslookup_ips(fake_nslookup, "77.88.8.8", "198.18.0.0/15", "fc00::/18");
assert(length(parsed) == 2 && parsed[0] == "93.184.216.34" && parsed[1] == "2001:db8::2",
    "parse_nslookup_ips skips FakeIP/private/server and prefers IPv4");

// Scenario 1: FakeIP enabled; first resolver returns FakeIP 198.18.x.x, second returns real IP.
// Direct probe succeeds cleanly via --resolve and must NOT add proxy rule.
let calls = [];
let mock_exec = function(opts) {
    let srv = opts.argv[2];
    if (srv == "1.1.1.1") {
        return {
            status: 0,
            output: "Server: 1.1.1.1\nAddress: 1.1.1.1:53\n\nName: app.example.com\nAddress 1: 198.18.1.9\n"
        };
    }
    return {
        status: 0,
        output: "Server: " + srv + "\nAddress: " + srv + ":53\n\nName: app.example.com\nAddress 1: 93.184.216.34\n"
    };
};
let mock_run = function(argv) {
    push(calls, argv);
    if (index(argv, "--proxy") >= 0) return { status: 0, output: "200" };
    return (index(argv, "app.example.com:443:93.184.216.34") >= 0)
        ? { status: 0, output: "200" }
        : { status: 28, output: "000" };
};
let d1 = plus.probe("app.example.com", { scheme: "https" }, "127.0.0.1:4534", ["--interface", "eth0"], mock_run, {
    settings: { fakeip_enabled: "1", bootstrap_dns_server: "https://1.1.1.1/dns-query" },
    exec_run: mock_exec
});
assert(d1.act == false && d1.seen == true && d1.defer == false,
    "FakeIP direct probe with --resolve passes instead of timing out");
assert(length(calls) == 1 && index(calls[0], "--resolve") >= 0,
    "direct curl receives --resolve real IP when FakeIP is enabled");

// Scenario 2: FakeIP enabled; direct --resolve hits transport timeout (28), proxy curl runs WITHOUT --resolve and succeeds -> act=true.
calls = [];
let mock_run_blocked = function(argv) {
    push(calls, argv);
    if (index(argv, "--proxy") >= 0) return { status: 0, output: "200" };
    return { status: 28, output: "000" };
};
let d2 = plus.probe("app.example.com", { scheme: "https" }, "127.0.0.1:4534", [], mock_run_blocked, {
    settings: { fakeip_enabled: "1", bootstrap_dns_server: "8.8.8.8" },
    exec_run: mock_exec
});
assert(d2.act == true && d2.seen == true, "real direct failure with FakeIP still flags blocked domain");
assert(length(calls) == 3, "two direct retries + one proxy probe");
assert(index(calls[0], "app.example.com:443:93.184.216.34") >= 0, "direct leg pins real IP");
assert(index(calls[2], "--resolve") < 0 && index(calls[2], "--proxy") >= 0, "proxy leg must not receive --resolve");

// Scenario 3: FakeIP enabled and ALL external resolvers fail / return only FakeIP -> must defer cleanly, never bare curl FakeIP.
calls = [];
let mock_exec_fail = function(opts) {
    return { status: 0, output: "Server: 8.8.8.8\nAddress: 8.8.8.8:53\n\nName: app.example.com\nAddress 1: 198.18.0.77\n" };
};
let d3 = plus.probe("app.example.com", { scheme: "https" }, "127.0.0.1:4534", [], mock_run_blocked, {
    settings: { fakeip_enabled: "1", bootstrap_dns_server: "8.8.8.8" },
    exec_run: mock_exec_fail
});
assert(d3.act == false && d3.defer == true && d3.dns_error == true && length(calls) == 0,
    "unresolved FakeIP returns dns_error without running bare curl");

print("PASS: smart_detect FakeIP direct probe checks\n");
UC
