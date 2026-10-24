// Read-only subscription endpoint. Disabled until explicitly configured in LuCI.
let links = require("server.links");
let common = require("core.common");
let str = common.as_string;

function token_matches(expected, actual) {
    if (!match(expected || "", /^[0-9a-f]{64}$/) || length(actual || "") != 64)
        return false;
    let diff = 0;
    for (let i = 0; i < 64; i++)
        diff |= ord(expected, i) ^ ord(actual, i);
    return diff == 0;
}

function selected(settings, server) {
    if (!common.bool_value(server.enabled ?? "1")) return false;
    if (settings.server_subscription_mode && index([ "all", "selected" ], settings.server_subscription_mode) < 0)
        return false;
    if (settings.server_subscription_mode != "selected") return true;
    let ids = settings.server_subscription_servers;
    if (type(ids) != "array") ids = ids ? [ ids ] : [];
    return index(ids, server[".name"]) >= 0;
}

function collect(settings, servers, certificate_pin) {
    let result = { links: [], skipped: [] };
    for (let server in servers) {
        if (!selected(settings, server)) continue;
        if (!links.supported(server)) {
            push(result.skipped, server[".name"]);
            continue;
        }
        let pin = certificate_pin ? certificate_pin(server) : "";
        let uri = links.build(server, settings.server_subscription_host || "", pin);
        if (uri != "") push(result.links, uri);
        else push(result.skipped, server[".name"]);
    }
    return result;
}

function certificate_pin(server) {
    if (index([ "vless", "trojan", "hysteria2", "tuic", "anytls", "naive", "trusttunnel", "tewfai", "masque", "openconnect", "vmess" ], server.protocol) < 0)
        return "";
    let output = common.command_output_from_args([
        getenv("TACHYON_BIN") || "/usr/bin/tachyon", "get_tls_certificate_sha256", server[".name"]
    ]);
    try { return json(output || "{}").sha256 || ""; } catch (e) { return ""; }
}

function response(settings, servers, request, pin_reader) {
    let denied = { code: 404, status: "Not Found", body: "Not found\n" };
    if (settings.server_subscription_enabled != "1") return denied;
    let path = request.path || "";
    if (!match(path, /^\/[0-9a-f]{64}$/) || !token_matches(settings.server_subscription_token, substr(path, 1)))
        return denied;
    if (request.method != "GET" && request.method != "HEAD")
        return { code: 405, status: "Method Not Allowed", body: "Method not allowed\n" };
    let format = settings.server_subscription_format || "base64";
    if (request.query != "" && request.query != null) {
        if (request.query == "format=plain") format = "plain";
        else if (request.query == "format=base64") format = "base64";
        else return { code: 400, status: "Bad Request", body: "Unsupported format\n" };
    }
    if (format != "plain" && format != "base64")
        return { code: 400, status: "Bad Request", body: "Unsupported format\n" };
    let data = collect(settings, servers, pin_reader);
    if (!length(data.links))
        return { code: 422, status: "Unprocessable Content", body: "No exportable servers\n" };
    let plain = join("\n", data.links) + "\n";
    return { code: 200, status: "OK", body: request.method == "HEAD" ? "" : (format == "base64" ? b64enc(plain) + "\n" : plain) };
}

function detect_default_country(uci, settings) {
    let explicit = uc(trim(str(settings.server_default_country || settings.server_country || "")));
    if (match(explicit, /^[A-Z]{2}$/)) return explicit;
    let zonename = trim(str(uci.get("system", "@system[0]", "zonename") || ""));
    let tz = trim(str(uci.get("system", "@system[0]", "timezone") || ""));
    if (match(zonename, /^(Europe\/(Moscow|Kaliningrad|Samara|Volgograd|Saratov|Ulyanovsk|Kirov|Astrakhan)|Asia\/(Yekaterinburg|Omsk|Novosibirsk|Barnaul|Tomsk|Novokuznetsk|Krasnoyarsk|Irkutsk|Chita|Yakutsk|Khandyga|Vladivostok|Ust-Nera|Magadan|Sakhalin|Srednekolymsk|Kamchatka|Anadyr))$/) || match(tz, /^(MSK|RTZ|<[+-]0[2-9]>|[+-]03)/))
        return "RU";
    if (zonename == "Europe/Minsk") return "BY";
    if (match(zonename, /^Asia\/(Almaty|Qyzylorda|Qostanay|Aqtobe|Aqtau|Atyrau|Oral)$/)) return "KZ";
    if (zonename == "Europe/Kyiv" || zonename == "Europe/Kiev") return "UA";
    if (zonename == "Europe/Berlin") return "DE";
    if (zonename == "Europe/Amsterdam") return "NL";
    if (zonename == "Europe/Helsinki") return "FI";
    if (zonename == "Europe/Istanbul") return "TR";
    return "RU";
}

function serve() {
    let uci = require("core.uci");
    let name = getenv("TACHYON_CONFIG_NAME") || "tachyon";
    let settings = uci.get_all(name, "settings") || {};
    let servers = uci.section_objects(name, "server");
    let fallback_country = detect_default_country(uci, settings);
    for (let s in servers) {
        if (!s.server_country) s.server_country = fallback_country;
    }
    // Authentication precedes certificate reads and URI generation.
    let result = response(settings, servers, {
        method: getenv("REQUEST_METHOD") || "GET", path: getenv("PATH_INFO") || "",
        query: getenv("QUERY_STRING") || ""
    }, certificate_pin);
    printf("Status: %d %s\r\n", result.code, result.status);
    print("Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n");
    if (result.code == 405) print("Allow: GET, HEAD\r\n");
    print("\r\n", result.body);
}

return { collect, response, selected, serve, token_matches };
