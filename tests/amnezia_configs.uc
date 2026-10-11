// Synthetic keys only. No live UCI or network changes.
let importer = require("subscription.amnezia_config");
let wg = require("subscription.wireguard");
let connections = require("config.connections");
let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";
let count = 0;
function check(ok, label) { assert(ok, label); count++; }
let base = "[Interface]\nPrivateKey = " + key + "\nAddress = 10.77.0.2/32, fd00::2/128\nMTU = 1280\n" +
    "[Peer]\nPublicKey = " + key + "\nPresharedKey = " + key + "\nEndpoint = [2001:db8::1]:51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25-35\n";
let versions = [
    {name:"AWG 2.0", fields:"Jc = 4\nJmin = 40\nJmax = 70\nS1 = 20\nS2 = 30\nH1 = 100\nH2 = 200\nH3 = 300\nH4 = 400\nI1 = <b 0x010203>\n"},
    {name:"AWG 3.0", fields:"S3 = 40\nS4 = 50\nH1 = 100-200\nI2 = <r 20>\nI3 = <b 0x03>\nI4 = <b 0x04>\nI5 = <b 0x05>\n"},
    {name:"AWG 3.1", fields:"HeaderProtectionKey = " + key + "\nContentPaddingAddition = 20-30\nRekeyAfterTime = 120\nRekeyTimeout = 5\nRejectAfterTime = 180\nKeepaliveTimeout = 10\nMaxHandshakeAttempts = 20\nRandomTrailers = on\nDisableCookies = false\n"}
];
for (let version in versions) {
    let conf = replace(base,"[Peer]",version.fields + "[Peer]");
    let encoded = sprintf("%J",{name:version.name,config:conf});
    let imported = importer.parse(encoded);
    check(imported && imported.name == version.name && imported.config == conf,"lossless named import");
    let endpoint = wg.from_vpn(imported.link);
    let expected = wg.from_conf(conf,"",version.name);
    for (let field in ["private_key","address","mtu","peers",...wg.awg_fields])
        check(sprintf("%J",endpoint[field]) == sprintf("%J",expected[field]),"preserve " + field);
    check(endpoint.tag == version.name,"display name survives internal URI");
    let links = connections.connection_urls({selector_proxy_links:["hy2://test@example.com:443"],
        selector_amnezia_configs:[encoded],selector_proxy_links_text:"vless://test@example.net:443"});
    check(length(links)==3 && links[1]==imported.link,"integrated sources preserve order");
    check(connections.has_connection_sources({selector_amnezia_configs:[encoded]}),"import-only section is a source");
}
for (let value in [null,"bad","[]","{}",sprintf("%J",{name:"",config:base}),
    sprintf("%J",{name:"line\nname",config:base}),sprintf("%J",{name:"test",config:base+"[Peer]\n"}),
    sprintf("%J",{name:"test",config:base+"[Interface]\n"}),
    sprintf("%J",{name:"test",config:replace(base,key,"bad")}),
    sprintf("%J",{name:"test",config:replace(base,"51820","65536")}),
    sprintf("%J",{name:"test",config:replace(base,"1280","10")}),
    sprintf("%J",{name:"test",config:replace(base,"[Peer]","Jc = 1-2\n[Peer]")}),
    sprintf("%J",{name:"test",config:replace(base,"[Peer]","H1 = 200-100\n[Peer]")}),
    sprintf("%J",{name:"test",config:replace(base,"[Peer]","RandomTrailers = maybe\n[Peer]")}),
    sprintf("%J",{name:"test",config:base+"\u0000"})]) check(importer.parse(value)==null,"invalid import rejected");
let large = "x";
while (length(large) < 65536) large += large;
check(importer.parse(sprintf("%J", {name:"Large",config:base+"#"+large})) == null, "oversized configuration rejected");
check(importer.parse(sprintf("%J", {name:substr(large,0,201),config:base})) == null, "oversized name rejected");
check(importer.parse(sprintf("%J", {name:"bad\u0000name",config:base})) == null, "NUL in name rejected");
check(importer.parse(sprintf("%J", {name:"bad\tname",config:base})) == null, "tab in name rejected");
let unicode = importer.parse(sprintf("%J",{name:"Тест AWG",config:base}));
check(unicode && wg.from_vpn(unicode.link).tag == "Тест AWG","UTF-8 name preserved");
let single = sprintf("%J",{name:"Single",config:base});
check(length(connections.connection_urls({selector_amnezia_configs:single}))==1,"single scalar UCI value");
let failed=false;
try { connections.connection_urls({selector_amnezia_configs:["invalid"]}); } catch(e) { failed=true; }
check(failed,"invalid stored import fails closed");
let hooks=importer.parse(sprintf("%J",{name:"Hooks",config:replace(base,"[Peer]","DNS = 1.1.1.1\nPostUp = touch /tmp/never-run\n[Peer]")}));
check(hooks && wg.from_vpn(hooks.link).dns == null && wg.from_vpn(hooks.link).post_up == null,"DNS and command hooks are not executed or applied");
print("PASS: ",count," named Amnezia import checks\n");
