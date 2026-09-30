let sd = require("service.smart_detect");
let plus = require("service.smart_detect_plus");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }
check(plus.mode({}) == "default", "missing mode defaults to upstream");
check(plus.mode({smart_detect_mode:"bad"}) == "default", "unknown mode is conservative");
check(plus.mode({smart_detect_mode:"plus"}) == "plus", "Plus explicit opt-in");
check(!plus.capture_enabled({smart_detect:"0",smart_detect_mode:"plus"}), "disabled Plus never captures");
check(!plus.capture_enabled({smart_detect:"1"}), "Default never captures extra web traffic");
check(plus.capture_enabled({smart_detect:"1",smart_detect_mode:"plus"}), "enabled Plus captures");
check(sd.CONFIRM_WINDOW == 120, "Default confirmation window retained");
check(!sd.verdict("example.com",{direct:"transport",proxy:"ok",now:119},{first_fail:0}).act, "Default not confirmed early");
check(sd.verdict("example.com",{direct:"transport",proxy:"ok",now:120},{first_fail:0}).act, "Default confirmed at window");
check(sd.verdict("example.com",{direct:"dns",proxy:"ok",now:120},{first_fail:0}).act, "Default allows confirmed censored names");
let calls=[]; let codes=[];
function run(argv) { push(calls,argv); return shift(codes); }
function probe(statuses,scheme) {
    calls=[]; codes=statuses;
    return plus.probe("api.example.com",{scheme:scheme||"https"},"127.0.0.1:4534",["--interface","wan","--sockopt-mark","0x40000000"],run);
}
check(probe([28,28,0]).act && length(calls)==3, "Plus requires two failed GETs and successful proxy");
for (let argv in calls) check(index(argv,"-I")<0 && index(argv,"--range")<0, "full body GET, no HEAD/range");
check(index(calls[0],"--sockopt-mark")>=0 && index(calls[2],"--sockopt-mark")<0, "Direct exemption only on Direct probes");
check(!probe([28,0]).act && length(calls)==2, "recovering Direct remains Direct");
check(!probe([0]).act && length(calls)==1, "healthy Direct does not probe proxy");
check(!probe([28,28,28]).act, "both paths broken: no rule");
for (let status in [5,6,60,77,23]) {
    let d=probe([status]);
    check(d.defer && !d.act && !d.seen && length(calls)==1, "DNS/local failures deferred: " + status);
}
check(probe([28,6]).dns_error && length(calls)==2, "second Direct DNS error deferred");
let controller = require("service.event_controller");
controller.classify_log_line('[123455 0ms] outbound/direct[direct-out]: outbound connection to default.example.com:443');
let default_facts = controller.classify_log_line('[123455 4s] outbound/direct[direct-out]: dial tcp 192.0.2.1:443: i/o timeout');
check(length(default_facts) == 1 && default_facts[0].payload.domain == "default.example.com", "Default trace correlation retained");
controller.classify_log_line('[123456 0ms] outbound/direct[direct-out]: outbound connection to api.example.com:443', true);
let facts = controller.classify_log_line('[123456 4s] outbound/direct[direct-out]: dial tcp 192.0.2.1:443: i/o timeout', true);
check(length(facts) == 1 && facts[0].payload.domain == "api.example.com", "Plus correlates hostname with IP-only failure");
controller.classify_log_line('[123457 0ms] outbound/direct[direct-out]: outbound connection to api.example.com:80', true);
facts = controller.classify_log_line('[123457 4s] outbound/direct[direct-out]: dial tcp 192.0.2.1:80: connection refused', true);
check(length(facts) == 1 && facts[0].payload.scheme == "http", "correlated HTTP failure keeps its scheme");
probe([28,28,0],"http");
check(calls[0][-1]=="http://api.example.com" && calls[2][-1]=="http://api.example.com", "HTTP scheme preserved");
// Exercise the actual exported collector, including its closure over run_probe.
let controller_errors = [];
let live_controller = controller.controller({ emit: function(){}, emit_once: function(){ return 0; } },
    { log: function(msg) { push(controller_errors, msg); } });
for (let gate in [
    { settings: { smart_detect: "0", smart_detect_mode: "plus" }, now: 100 },
    { settings: { smart_detect: "1", smart_detect_mode: "default" }, now: 100 },
    { settings: { smart_detect: "1", smart_detect_mode: "plus" }, now: 100, reload_in_progress: true }
]) {
    live_controller.probe_smart_detect(gate);
    check(length(controller_errors) == 0, "actual collector gate works without a closure error");
}
print(sprintf("PASS: %d mode/probe checks\n",checks));
