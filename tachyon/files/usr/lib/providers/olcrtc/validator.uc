let common = require("core.common");
let fs = require("fs");

let as_string = common.as_string;

const OLCRTC_PROVIDERS = [ "jitsi", "telemost", "wbstream" ];
const OLCRTC_TRANSPORTS = [ "datachannel", "vp8channel", "seichannel", "videochannel" ];

function yaml_quote(value) {
    value = as_string(value);
    if (value == "")
        return "''";
    if (match(value, /^[a-zA-Z0-9_./:-]+$/) != null)
        return value;
    return "'" + replace(value, "'", "''") + "'";
}

function parse_uri(value) {
    value = trim(as_string(value));
    if (substr(value, 0, 9) != "olcrtc://")
        return { valid: false, reason: "URI must start with olcrtc://" };

    let rest = substr(value, 9);

    let dollar_idx = rindex(rest, "$");
    let mimo = "";
    if (dollar_idx >= 0) {
        mimo = substr(rest, dollar_idx + 1);
        rest = substr(rest, 0, dollar_idx);
    }

    let hash_idx = rindex(rest, "#");
    let crypto_key = "";
    if (hash_idx >= 0) {
        crypto_key = substr(rest, hash_idx + 1);
        rest = substr(rest, 0, hash_idx);
    }

    let at_idx = index(rest, "@");
    let room_id = "";
    let provider_transport = rest;
    if (at_idx >= 0) {
        provider_transport = substr(rest, 0, at_idx);
        room_id = substr(rest, at_idx + 1);
    }

    let q_idx = index(provider_transport, "?");
    let provider = "";
    let transport_with_payload = provider_transport;
    if (q_idx >= 0) {
        provider = substr(provider_transport, 0, q_idx);
        transport_with_payload = substr(provider_transport, q_idx + 1);
    }

    let payload = "";
    let transport = transport_with_payload;
    let lt_idx = index(transport_with_payload, "<");
    let gt_idx = index(transport_with_payload, ">");
    if (lt_idx >= 0 && gt_idx > lt_idx) {
        transport = substr(transport_with_payload, 0, lt_idx);
        payload = substr(transport_with_payload, lt_idx + 1, gt_idx - lt_idx - 1);
    }

    if (!array_contains(OLCRTC_PROVIDERS, provider))
        return { valid: false, reason: "provider must be one of: " + join(", ", OLCRTC_PROVIDERS) };
    if (!array_contains(OLCRTC_TRANSPORTS, transport))
        return { valid: false, reason: "transport must be one of: " + join(", ", OLCRTC_TRANSPORTS) };
    if (room_id == "")
        return { valid: false, reason: "room_id is required" };
    if (crypto_key != "" && length(crypto_key) != 64)
        return { valid: false, reason: "crypto_key must be 64 hex characters" };

    return {
        valid: true,
        provider: provider,
        transport: transport,
        room_id: room_id,
        crypto_key: crypto_key,
        mimo: mimo,
        payload: payload
    };
}

function valid_hex_key(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return length(value) == 64 && match(value, /^[0-9a-fA-F]+$/) != null;
}

function valid_number(value, min, max) {
    value = as_string(value);
    if (value == "" || value == null)
        return true;
    let num = int(value);
    if (num == null || isNaN(num))
        return false;
    return num >= min && num <= max;
}

function valid_url(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^https?:\/\/[^ \t\r\n]+$/) != null;
}

function valid_host_port(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^[^ \t\r\n:]+:[0-9]{1,5}$/) != null;
}

function list_values(value) {
    if (type(value) == "array")
        return value;
    value = trim(as_string(value));
    if (value == "" || value == null)
        return [];
    return split(value, " \t\n\r");
}

function validation_result(valid, message, options) {
    let result = { valid: valid, message: message || "" };
    if (options != null)
        for (let key in options)
            result[key] = options[key];
    return result;
}

function validate_section(section) {
    let errors = [];

    let provider = as_string(section.provider || "");
    if (provider != "" && !array_contains(OLCRTC_PROVIDERS, provider))
        push(errors, "provider must be one of: " + join(", ", OLCRTC_PROVIDERS));

    let transport = as_string(section.transport || "");
    if (transport != "" && !array_contains(OLCRTC_TRANSPORTS, transport))
        push(errors, "transport must be one of: " + join(", ", OLCRTC_TRANSPORTS));

    let crypto_key = as_string(section.crypto_key || "");
    if (crypto_key != "" && !valid_hex_key(crypto_key))
        push(errors, "crypto_key must be 64 hex characters");

    let socks_port = as_string(section.socks_port || "");
    if (socks_port != "" && !valid_number(socks_port, 1, 65535))
        push(errors, "socks_port must be 1-65535");

    let dns_server = as_string(section.dns_server || "");
    if (dns_server != "" && !valid_host_port(dns_server))
        push(errors, "dns_server must be in HOST:PORT format");

    let subscription_links = list_values(section.subscription_links);
    for (let link in subscription_links) {
        link = trim(as_string(link));
        if (link == "")
            continue;
        if (substr(link, 0, 9) == "olcrtc://") {
            let parsed = parse_uri(link);
            if (!parsed.valid)
                push(errors, "invalid olcrtc:// URI: " + parsed.reason);
        }
        else if (!valid_url(link))
            push(errors, "subscription link must be olcrtc:// URI or HTTP URL: " + link);
    }

    return errors;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function write_json(value) {
    printf("%s\n", sprintf("%J", value));
}

function validate_section_json() {
    let input = read_stdin();
    let data = object_or_empty(json(input));
    let errors = validate_section(data);
    if (length(errors) > 0)
        write_json({ valid: false, message: join("; ", errors) });
    else
        write_json({ valid: true, message: "" });
    return length(errors) == 0;
}

return {
    validate_section,
    validate_section_json,
    parse_uri,
    valid_hex_key,
    providers: OLCRTC_PROVIDERS,
    transports: OLCRTC_TRANSPORTS
};
