let speed = require("dns.speed_test");
let fs = require("fs");
function check(ok, label) {
    if (!ok) { warn("FAIL: " + label + "\n"); exit(1); }
}

let request = { protocol: "doh", servers: [ "https://dns.example/dns-query" ], domains: [ "example.com", "fail.example" ] };
check(speed.validate_request(request) != null, "valid selected servers and hosts");
check(speed.validate_request({ ...request, protocol: "doq" }) == null, "do not measure DoH for another selected protocol");
check(speed.validate_request({ ...request, servers: [ "http://dns.example/dns-query" ] }) == null, "HTTPS only");
check(speed.validate_request({ ...request, servers: [ "https://user:pass@dns.example/dns-query" ] }) == null, "reject URL credentials");
check(speed.validate_request({ ...request, domains: [ "a.example;touch /tmp/injected" ] }) == null, "reject shell input");
check(speed.validate_request({ ...request, domains: [ "a..example" ] }) == null, "reject empty labels");
check(speed.validate_request({ ...request, domains: [] }) == null, "reject empty host list");
check(speed.endpoint("1.1.1.1").resolve == "cloudflare-dns.com:443:1.1.1.1", "IP aliases preserve TLS SNI and target IP");
check(speed.endpoint("https://dns.example/profile").address == "https://dns.example:443/profile", "preserve custom profile path");
let stats = speed.summarize([ { ok: true, ms: 10 }, { ok: true, ms: 30 }, { ok: false, ms: null }, { ok: true, ms: 20 } ]);
check(stats.success == 3 && stats.total == 4 && stats.min == 10 && stats.median == 25 && stats.avg == 1265 && stats.max == 5000, "timeouts penalize statistics instead of biasing them down");
check(speed.summarize([ { ok: false } ]).median == null, "all failures are unavailable, not a measured ping");
let query = speed.dns_query("example.com");
let valid = hexdec("000081800001000100000000") + substr(query, 12) + hexdec("c00c000100010000003c000401020304");
check(speed.valid_answer(valid, query), "valid RFC8484 DNS wire answer");
check(!speed.valid_answer(substr(valid, 0, length(valid) - 1), query), "truncated DNS body rejected");
check(!speed.valid_answer(valid, speed.dns_query("other.example")), "wrong question rejected");
check(!speed.valid_answer(hexdec("000081820001000100000000") + substr(valid, 12), query), "SERVFAIL rejected");
check(!speed.valid_answer("<html>success</html>", query), "HTTP 200 HTML is not DNS success");

fs.mkdir(getenv("TACHYON_UI_STATE_DIR") + "/dns-speed-test", 0700);
let result = speed.measure(speed.endpoint("https://dns.example/dns-query"), request.domains);
check(result.stats.success == 1 && result.stats.total == 2, "real curl batch parsing and per-host errors");
check(result.samples[0].ms == 25 && !result.samples[1].ok, "only measured pass included; warm-up excluded");
let trace = fs.readfile(getenv("DNS_SPEED_FIXTURE_TRACE"));
check(index(trace, "--insecure") < 0 && index(trace, "\"-k\"") < 0, "TLS validation remains enabled");
check(index(trace, "--next") >= 0 && index(trace, "--max-time") >= 0, "same curl process reuses connections and bounds transfers");
let started = speed.start(request);
check(started.success && started.id, "asynchronous worker starts");
for (let i = 0; i < 100; i++) {
    let state = speed.status();
    if (!state.running) {
        check(state.id == started.id && !state.error && length(state.results) == 1 && state.results[0].stats.success == 1, "worker completes with matching result snapshot");
        print("PASS: DNS speed test\n");
        exit(0);
    }
    sleep(100);
}
check(false, "worker deadline");
