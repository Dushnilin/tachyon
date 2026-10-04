let m = require("diagnostics.leak_check");
function check(ok, label) {
    if (!ok) { warn("FAIL: " + label + "\n"); exit(1); }
}
let raw = [
    {type:"ip", ip:"198.51.100.10"},
    {type:"dns", ip:"2001:db8::53", asn:"AS64500 Example"},
    {type:"dns", ip:"2001:DB8::53"},
    {type:"conclusion", ip:"DNS may be leaking."},
    {type:"dns", ip:"999.1.1.1"},
    {type:"dns", ip:"not an IP"},
    {type:"dns", ip:"1:2:3"},
    {ip:"8.8.8.8"},
    {type:"dns", ip:"1.1.1.1", asn:"Cloudflare"}
];
let filtered = m.filter_dns_records(raw);
check(length(filtered) == 2, "only distinct valid typed DNS records survive");
check(filtered[0].ip == "2001:db8::53", "IPv6 case normalized");
check(length(m.filter_dns_records({error:"unavailable"})) == 0, "malformed response has no observations");
let a = m.analyse_resolvers(raw, {"2001:db8::53":true}, {}, "Unknown");
check(!a.leaked && a.has_unknown && a.servers[0].verdict == "shared", "shared resolver is inconclusive, not an ISP leak");
let b = m.analyse_resolvers(raw, {}, {"2001:db8::53":true}, "Unknown");
check(b.leaked && b.servers[0].verdict == "isp", "exact configured WAN resolver gives warning");
check(a.servers[1].verdict == "public", "known public DNS remains public");
let c = m.dns_configuration_evidence({dns:{servers:[
    {tag:"dns", type:"https", server:"dns.example.com", path:"/private-profile", password:"secret", detour:"vpn"},
    {tag:"bootstrap", type:"udp", server:"1.1.1.1"},
    {tag:"bad", type:"https", server:"https://user:secret@example.com/private"}
]}});
check(length(c) == 3 && c[0].encrypted && !c[1].encrypted, "configured encrypted transport is separate from bootstrap");
let text = sprintf("%J", c);
check(index(text, "secret") < 0 && index(text, "private-profile") < 0 && c[2].server == "", "credentials and profile paths excluded");
check(length(m.dns_configuration_evidence(null)) == 0, "missing config is not secure evidence");
print("PASS: DNS Leak Plus parsing, classification and redaction\n");

let t = require("diagnostics.dns_transport");
let ready = "tcpdump: listening on eth1\n0 packets dropped by kernel\n";
let open_v4 = "14:00:00 IP 192.0.2.1.45123 > 192.0.2.53.53: 123+ A? 1.test123.bash.ws. (41)";
let open_v6 = "14:00:00 IP6 2001:db8::1.45123 > 2001:db8::53.53: 124+ AAAA? 2.test123.bash.ws. (41)";
check(t.capture_result(open_v4 + "\n" + open_v6, "test123", ready, true, true).queries == 2, "IPv4 and IPv6 plaintext observations counted");
check(t.capture_result(open_v4, "test123", "", false, false).status == "plaintext_observed", "positive packet evidence survives incomplete capture");
check(t.capture_result("A? 1.other.bash.ws.", "test123", ready, true, true).status == "not_observed", "unrelated DNS names do not count");
check(t.capture_result("", "test123", ready, true, false).status == "inconclusive", "missing router observations cannot pass");
check(t.capture_result("", "test123", "listening on eth1\n2 packets dropped by kernel", true, true).status == "inconclusive", "capture loss cannot pass");
check(t.capture_result("", "test123", ready, false, true).status == "inconclusive", "unfinished capture cannot pass");
let query = require("dns.speed_test").dns_query("example.com");
let answer = hexdec("000081800001000100000000") + substr(query, 12) + hexdec("c00c000100010000003c000401020304");
check(t.doh_result(0, "0|200|application/dns-message|2|192.0.2.53", answer, query).status == "verified", "real DoH answer and certificate success verified");
check(t.doh_result(60, "0|200|application/dns-message|2|192.0.2.53", answer, query).status == "failed", "curl TLS failure cannot pass");
check(t.doh_result(0, "1|200|application/dns-message|2|192.0.2.53", answer, query).status == "failed", "certificate validation error cannot pass");
check(t.doh_result(0, "0|200|text/html|2|192.0.2.53", answer, query).status == "failed", "HTTP success without DNS content cannot pass");
check(t.doh_result(0, "0|200|application/dns-message|2|192.0.2.53", "", query).status == "invalid_dns_response", "empty DNS response cannot pass");
check(t.doh_target({dns:{servers:[{tag:"dns-server",type:"udp",server:"1.1.1.1"}]}}) == null, "UDP is not silently tested as DoH");
let target = t.doh_target({dns:{servers:[{tag:"dns-server",type:"https",server:"192.0.2.53",path:"/profile",tls:{server_name:"dns.example.com",insecure:true}}]}});
check(target.resolve == "dns.example.com:443:192.0.2.53" && target.router_verification_disabled, "TLS server-name override and insecure setting retained as evidence");
print("PASS: WAN DNS capture and DoH TLS evidence\n");

// Optional integration fixture supplied by the shell runner, never a public network call.
let dir = getenv("DNS_TRANSPORT_TEST_DIR");
if (dir) {
    let result = t.check_doh({dns:{servers:[{tag:"dns-server",type:"https",server:"dns.example.com",path:"/private-profile"}]}}, "test123", dir);
    check(result.status == "verified" && result.server == "dns.example.com", "DoH probe executes with validated DNS response");
    let argv = json(require("fs").readfile(getenv("DNS_TRANSPORT_TRACE")));
    let args_text = sprintf("%J", argv);
    check(index(args_text, "--disable") >= 0 && index(args_text, "--config") >= 0 && index(args_text, "private-profile") < 0 && index(args_text, "--insecure") < 0, "profile path excluded from arguments and certificate checks retained");
    check(require("fs").stat(dir + "/tls-curl.conf") == null && require("fs").stat(dir + "/tls-answer") == null, "private curl config and answer removed");
    print("PASS: DoH execution and private path cleanup\n");
}
