let parser = require("subscription.parser");
let checks = 0;
function check(ok, message) { if (!ok) die("FAIL: " + message + "\n"); checks++; }

let quic = parser.parse_share_link("hysteria2://secret@hy.example.com:443/?sni=hy.example.com&fm=%7B%22quicParams%22%3A%7B%22debug%22%3Afalse%2C%22congestion%22%3A%22bbr%22%7D%7D#HY");
check(quic != null && quic.type == "hysteria2", "link with quicParams-only fm parses");
check(quic.obfs == null, "quicParams-only fm does not enable obfuscation");

let sal = parser.parse_share_link("hysteria2://secret@hy.example.com:443/?sni=hy.example.com&fm=%7B%22udp%22%3A%5B%7B%22settings%22%3A%7B%22password%22%3A%22pw%22%7D%7D%5D%7D#HY");
check(sal.obfs != null && sal.obfs.type == "salamander" && sal.obfs.password == "pw", "untyped udp item still defaults to salamander");

let typed = parser.parse_share_link("hysteria2://secret@hy.example.com:443/?sni=hy.example.com&fm=%7B%22type%22%3A%22salamander%22%2C%22password%22%3A%22pw2%22%7D#HY");
check(typed.obfs != null && typed.obfs.password == "pw2", "typed bare fm object keeps salamander");

print("OK subscription_hysteria2_finalmask (" + checks + " checks)\n");
