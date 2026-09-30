#!/usr/bin/env ucode
// Выполнять на OpenWrt с установленным Tachyon; маршруты и UCI не изменяет.
let controller = require("service.event_controller");
let module = require("service.smart_detect_plus");
let checks = 0;
function check(ok, name) {
    if (!ok) die("FAIL: " + name + "\n");
    checks++;
}
function connection(id, host, bytes, chains, port) {
    return {
        id,
        metadata: { host, network: "tcp", type: "tproxy/tproxy-in", destinationPort: port || "443" },
        download: bytes,
        upload: 500,
        chains: chains || [ "direct-out" ]
    };
}
let stalled = module.stalled_candidates;
let host = "deepswe.datacurve.ai";
let values = module.domain_values;
check(join("|", values("eshentai.tv\nrule34.world\nr34.app")) == "eshentai.tv|rule34.world|r34.app", "LuCI multiline string split");
check(join("|", values(["eshentai.tv\nrule34.world", "ESHENTAI.TV"])) == "eshentai.tv|rule34.world", "mixed UCI list multiline and case duplicate");
check(length(values("\r\n eshentai.tv , rule34.world\t\n\n")) == 2, "blank lines and separators");
check(join("|", values(["regex:^some pattern$", "# keep this comment", "full:example.com"])) == "regex:^some pattern$|# keep this comment|full:example.com", "prefixed conditions and comments preserved");
check(length(values(null)) == 0, "unset domains are empty");
let conn = connection("partial", host, 35831);
let first = stalled({}, [conn], 100);
check(length(first.domains) == 0, "fresh connection");
let early = stalled(first.tracked, [conn], 114);
check(length(early.domains) == 0, "stall threshold");
let stop = stalled(early.tracked, [conn], 115);
check(stop.domains[host] == "https", "partial HTTPS body stall");
check(length(stalled(stop.tracked, [conn], 145).domains) == 0, "emit once while stalled");
check(length(stalled(stop.tracked, [conn], 414).domains) == 0, "persistent stall cooldown");
check(stalled(stop.tracked, [conn], 415).domains[host] == "https", "persistent stall retried");
conn.download = 60000;
let progress = stalled(stop.tracked, [conn], 145);
check(length(progress.domains) == 0, "progress resumes");
check(stalled(progress.tracked, [conn], 160).domains[host] == "https", "new stall after progress");
check(length(stalled(progress.tracked, [], 160).tracked) == 0, "closed connections removed");
conn.id = "new";
check(length(stalled(first.tracked, [conn], 200).domains) == 0, "new connection is not old stall");
for (let route in [ "vpn-out", "bypass-out", "zapret-out", "discord_zapret2-out" ]) {
    let routed = connection("exception", host, 35831, [route]);
    check(length(stalled({}, [routed], 100).tracked) == 0, "preserve " + route);
}
let tailscale = connection("tailscale", host, 35831);
tailscale.metadata.type = "tailscale/server-in";
check(length(stalled({}, [tailscale], 100).tracked) == 0, "Tailscale inbound excluded");
let udp = connection("udp", host, 0);
udp.metadata.network = "udp";
check(length(stalled({}, [udp], 100).tracked) == 0, "UDP excluded");
let nonweb = connection("game", host, 0, null, "27015");
check(length(stalled({}, [nonweb], 100).tracked) == 0, "non-web excluded");
let http = connection("http", "example.com", 0, null, "80");
let initialHttp = stalled({}, [http], 100);
check(stalled(initialHttp.tracked, [http], 115).domains["example.com"] == "http", "HTTP scheme");
for (let invalid in [ "216.150.1.193", "bad..example.com", "bad.-example.com", "bad-.example.com", "bad.example.com?x", "", "localhost" ]) {
    check(length(stalled({}, [connection("invalid", invalid, 0)], 100).tracked) == 0, "invalid host: " + invalid);
}
let many = [];
for (let i = 0; i < 600; i++) push(many, connection("id" + i, host, 0));
check(length(stalled({}, many, 100).tracked) == 512, "bounded tracking");
let unanswered = connection("unanswered", "blocked.example.com", 0);
let unansweredFirst = stalled({}, [unanswered], 100);
check(length(stalled(unansweredFirst.tracked, [unanswered], 104).domains) == 0, "no reply threshold");
let unansweredStop = stalled(unansweredFirst.tracked, [unanswered], 105);
check(unansweredStop.domains["blocked.example.com"] == "https", "no reply detected at five seconds");
check(unansweredStop.priorities["blocked.example.com"] == 3, "no reply gets high priority");
let preconnect = connection("preconnect", "blocked.example.com", 0);
preconnect.upload = 0;
check(length(stalled({}, [preconnect], 100).tracked) == 0, "unused browser preconnect excluded");
check(stop.priorities[host] == 2, "partial body gets lower priority");
let sameHost = [connection("idle", host, 35831), connection("newBlocked", host, 0)];
let sameFirst = stalled({}, sameHost, 100);
check(stalled(sameFirst.tracked, sameHost, 115).priorities[host] == 3, "multiple connections retain strongest priority");
let queue = {};
let enqueue = module.queue_candidate;
let order = module.queue_order;
check(enqueue(queue, {domain: "idle.example.com", scheme: "https", priority: 2}, 100, 2), "enqueue idle");
check(enqueue(queue, {domain: "new.example.com", scheme: "http", priority: 2}, 110, 2), "enqueue second");
check(order(queue, keys(queue))[0] == "idle.example.com", "equal priority FIFO");
check(!enqueue(queue, {domain: "late.example.com", priority: 2}, 120, 2), "full equal-priority queue preserved");
check(enqueue(queue, {domain: "blocked.example.com", priority: 3}, 125, 2), "high priority replaces weakest newest");
check(length(queue) == 2 && !queue["new.example.com"] && queue["idle.example.com"], "replacement keeps cap and oldest idle");
check(order(queue, keys(queue))[0] == "blocked.example.com", "blocked request precedes older idle");
check(enqueue(queue, {domain: "idle.example.com", scheme: "http", priority: 3}, 130, 2), "duplicate priority upgraded at capacity");
check(queue["idle.example.com"].queued == 100 && queue["idle.example.com"].scheme == "http", "upgrade retains FIFO age and failing scheme");
check(order(queue, keys(queue))[0] == "idle.example.com", "upgraded candidate FIFO");
check(enqueue(queue, {domain: "idle.example.com", scheme: "https", priority: 1}, 140, 2), "lower priority duplicate accepted");
check(queue["idle.example.com"].priority == 3 && queue["idle.example.com"].scheme == "http", "weaker observation cannot downgrade candidate");
check(!enqueue(queue, {domain: "192.0.2.1", priority: 3}, 150, 2), "queue rejects non-domain");
check(module.extract_domain('direct timeout target=example.com') == "example.com", "legacy target log");
check(module.extract_domain('direct failed "EXAMPLE.COM:443"') == "example.com", "quoted log normalization");
check(module.extract_domain('connection: open connection to deepswe.datacurve.ai:443 using outbound/direct[direct-out]: i/o timeout') == host, "plain sing-box destination");
check(module.extract_domain('direct timeout dial tcp 216.150.1.193:443') == null, "IP is not a domain");
check(length(controller.classify_log_line('connection: open connection to deepswe.datacurve.ai:443 using outbound/direct[direct-out]: i/o timeout', true)) == 1, "log candidate publication");
function candidate(line) {
    let facts = controller.classify_log_line(line, true);
    for (let fact in facts)
        if (fact.type == controller.EV.SMARTDETECT_CANDIDATE) return fact.payload;
    return null;
}
for (let reason in [ "connection refused", "network is unreachable", "no route to host", "unexpected EOF", "EOF", "broken pipe", "TLS: handshake failure", "read: operation timed out" ]) {
    let line = "connection: open connection to broken.example.com:443 using outbound/direct[direct-out]: " + reason;
    check(candidate(line)?.domain == "broken.example.com", "direct transport failure: " + reason);
}
check(candidate('connection: open connection to broken.example.com:80 using outbound/direct[direct-out]: EOF')?.scheme == "http", "HTTP log retains scheme");
check(candidate('Direct timeout target=example.com')?.domain == "example.com", "mixed-case Direct log");
check(candidate('Direct timeout target=example.com')?.priority == 3, "direct failure gets high priority");
let long_host = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij.example.com";
check(candidate('direct timeout "' + long_host + ':443"')?.domain == long_host, "long quoted hostname");
check(candidate('direct timeout target=api.xn--e1afmkfd.xn--p1ai')?.domain == "api.xn--e1afmkfd.xn--p1ai", "IDNA log hostname");
check(candidate('connection: open connection to broken.example.com:443 using outbound/direct[direct-out]: remote certificate "other.example.net" failed')?.domain == "broken.example.com", "explicit destination wins");
for (let route in [ "bypass-out", "discord_zapret2-out", "youtube_zapret2-out", "vpn-out" ])
    check(candidate('connection: open connection to broken.example.com:443 using outbound/direct[' + route + ']: i/o timeout') == null, "log preserves " + route);
for (let line in [
    'connection: open connection to game.example.com:27015 using outbound/direct[direct-out]: i/o timeout',
    'connection: dial udp game.example.com:443 using outbound/direct[direct-out]: i/o timeout',
    'direct: open packet connection to "game.example.com:443": EOF',
    'direct udp connection timeout target=game.example.com',
    'direct timeout target=game.example.com:50000',
    'connection: open connection to example.com:443 using outbound/direct[direct-out]: context canceled',
    'connection: open connection to example.com:443 using outbound/direct[direct-out]: TLS handshake completed',
    'direct timeout target=bad.example.com?secret',
    'connection: open connection to 192.0.2.1:443 using outbound/direct[direct-out]: EOF'
]) check(candidate(line) == null, "irrelevant log excluded: " + line);
for (let item in [
    [ "deepswe.datacurve.ai", "datacurve.ai" ],
    [ "a.b.example.com", "example.com" ],
    [ "api.example.co.uk", "example.co.uk" ],
    [ "cdn.team.github.io", "team.github.io" ],
    [ "a.city.kawasaki.jp", "city.kawasaki.jp" ],
    [ "a.b.ck", "a.b.ck" ],
    [ "a.www.ck", "www.ck" ],
    [ "co.uk", null ],
    [ "github.io", null ],
    [ "b.ck", null ],
    [ "www.xn--e1afmkfd.xn--p1ai", "xn--e1afmkfd.xn--p1ai" ]
]) check(module.main_domain(item[0]) == item[1], "main domain: " + item[0]);
print(sprintf("PASS: %d Smart Detect checks\n", checks));
