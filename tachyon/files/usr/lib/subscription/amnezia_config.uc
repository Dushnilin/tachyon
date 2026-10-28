// Named .conf imports reuse the same WG/AWG parser as vpn:// links.
let wireguard = require("subscription.wireguard");

function parse(value) {
    if (type(value) != "string" || length(value) > 262144)
        return null;

    let data = null;
    try { data = json(value); } catch (e) { return null; }
    if (type(data) != "object" || type(data.name) != "string" || type(data.config) != "string")
        return null;

    let name = trim(data.name);
    if (!length(name) || length(name) > 200 || index(name, "\u0000") >= 0 || match(name, /[[:cntrl:]]/) != null ||
        !length(data.config) || length(data.config) > 65536 || index(data.config, "\u0000") >= 0)
        return null;

    let trimmed_cfg = trim(data.config);
    if (substr(trimmed_cfg, 0, 6) == "vpn://") {
        let eps = wireguard.from_vpn_endpoints(trimmed_cfg);
        if (eps == null || length(eps) == 0)
            return null;
        return { name, config: data.config, link: trimmed_cfg };
    }

    // Reject ambiguous files before using the shared data-only parser. Several
    // [Peer] blocks are fine: each peer becomes its own endpoint.
    let interfaces = 0, peers = 0;
    for (let line in split(data.config, "\n")) {
        line = lc(trim(line));
        if (line == "[interface]") interfaces++;
        if (line == "[peer]") peers++;
    }
    if (interfaces != 1 || peers < 1)
        return null;

    let text = "# " + name + "\n" + data.config;
    let link = "vpn://" + replace(replace(replace(b64enc(text), /\+/g, "-"), /\//g, "_"), /=+$/, "");
    if (length(text) > 65536 || length(wireguard.from_conf_endpoints(text, link, name)) == 0)
        return null;

    return { name, config: data.config, link };
}

return { parse };
