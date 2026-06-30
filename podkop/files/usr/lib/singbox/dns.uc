#!/usr/bin/env ucode

let common = require("core.common");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");

let as_string = common.as_string;
let option = common.option;

function valid_ipv4_octet(value) {
    value = as_string(value);
    return match(value, /^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$/) != null;
}

function valid_ipv4(value) {
    value = as_string(value);
    if (length(value) > 0 && substr(value, length(value) - 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts)
        if (!valid_ipv4_octet(part))
            return false;

    return true;
}

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port, 10);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port, 10) : 853;
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!valid_ipv4(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function server_config(settings) {
    return server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        option(settings, "dns_type", "doh"),
        option(settings, "dns_server", "1.1.1.1"),
        ""
    );
}

return {
    server_from_options,
    server_config
};
