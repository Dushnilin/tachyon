// Deterministic curl fixture: valid DNS, one timeout, and separate warm-up timings.
let fs = require("fs");
fs.writefile(getenv("DNS_SPEED_FIXTURE_TRACE"), sprintf("%J", ARGV));
let output = "", url = "", format = "";
function emit() {
    let encoded = replace(replace(split(url, "?dns=")[1], /-/g, "+"), /_/g, "/");
    while (length(encoded) % 4) encoded += "=";
    let query = b64dec(encoded);
    let failed = substr(query, 13, 4) == "fail";
    let body = failed ? "" : hexdec("000081800001000100000000") + substr(query, 12) + hexdec("c00c000100010000003c000401020304");
    fs.writefile(output, body);
    let index_value = int(split(format, "|")[0]);
    printf("%d|%s|%s|application/dns-message|%d|%d\n", index_value,
        failed ? "000" : "200", index_value < 2 ? "0.900" : "0.025", length(body), failed ? 28 : 0);
}
for (let i = 0; i < length(ARGV); i++) {
    if (ARGV[i] == "--next") emit();
    else if (ARGV[i] == "--output") output = ARGV[++i];
    else if (ARGV[i] == "--write-out") format = ARGV[++i];
    else if (ARGV[i] == "--url") url = ARGV[++i];
}
emit();
