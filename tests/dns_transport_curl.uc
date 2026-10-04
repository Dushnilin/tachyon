let fs = require("fs");
fs.writefile(getenv("DNS_TRANSPORT_TRACE"), sprintf("%J", ARGV));
let config = "", output = "";
for (let i = 0; i < length(ARGV); i++) {
    if (ARGV[i] == "--config") config = ARGV[++i];
    else if (ARGV[i] == "--output") output = ARGV[++i];
}
let address = json(trim(substr(fs.readfile(config), 6)));
let encoded = replace(replace(split(address, "dns=")[1], /-/g, "+"), /_/g, "/");
while (length(encoded) % 4) encoded += "=";
let query = b64dec(encoded);
let body = hexdec("000081800001000100000000") + substr(query, 12) + hexdec("c00c000100010000003c000401020304");
fs.writefile(output, body);
print("0|200|application/dns-message|2|192.0.2.53");
