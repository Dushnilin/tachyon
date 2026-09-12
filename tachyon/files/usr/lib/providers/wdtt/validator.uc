let common = require("core.common");
let fs = require("fs");

let as_string = common.as_string;

const WDTT_MODES = [ "selective", "lan-all", "full" ];
const QWDTT_MODES = [ "rawtun", "socks", "vpn" ];
const WDTT_COMMUNITY_LISTS = [
    "russia-inside", "russia-outside", "ukraine", "telegram", "meta",
    "youtube", "discord", "tiktok", "twitter", "hdrezka", "roblox",
    "cloudflare", "cloudfront", "google_ai", "google_meet", "google_play",
    "hetzner", "ovh", "digitalocean", "anime", "news", "geoblock",
    "block", "porn", "hodca"
];

function url_decode(value) {
    let result = "";
    let len = length(value);
    let i = 0;
    while (i < len) {
        if (value[i] == '%' && i + 2 < len) {
            let hex = substr(value, i + 1, 2);
            let code = parseInt(hex, 16);
            if (code != null && !isNaN(code))
                result += chr(code);
            else
                result += '%';
            i += 3;
        }
        else if (value[i] == '+') {
            result += ' ';
            i += 1;
        }
        else {
            result += value[i];
            i += 1;
        }
    }
    return result;
}

function parse_query_string(query) {
    let params = {};
    if (query == "" || query == null)
        return params;
    let pairs = split(query, "&");
    for (let pair in pairs) {
        let kv = split(pair, "=", 2);
        if (length(kv) == 2)
            params[kv[0]] = url_decode(kv[1]);
        else if (length(kv) == 1)
            params[kv[0]] = "";
    }
    return params;
}

function parse_wdtt_uri(value) {
    value = trim(as_string(value));
    if (substr(value, 0, 7) != "wdtt://")
        return { valid: false, reason: "URI must start with wdtt://" };

    let rest = substr(value, 7);
    let hash_idx = index(rest, "#");
    let label = "";
    if (hash_idx >= 0) {
        label = substr(rest, hash_idx + 1);
        rest = substr(rest, 0, hash_idx);
    }

    let params = parse_query_string(rest);
    let peer = params.peer || "";
    let hashes = params.hashes || "";
    let pass = params.pass || "";
    let workers = params.workers || "";
    let port = params.port || "";

    if (peer == "")
        return { valid: false, reason: "wdtt:// URI must contain peer parameter" };

    return {
        valid: true,
        peer: peer,
        hashes: hashes,
        pass: pass,
        workers: workers,
        port: port,
        label: label
    };
}

function valid_peer(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^[^ \t\r\n:]+:[0-9]{1,5}$/) != null;
}

function valid_url(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^https?:\/\/[^ \t\r\n]+$/) != null;
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

function valid_mode(value) {
    if (value == "" || value == null)
        return true;
    return array_contains(WDTT_MODES, value);
}

function valid_qwdtt_mode(value) {
    if (value == "" || value == null)
        return true;
    return array_contains(QWDTT_MODES, value);
}

function valid_community_list(value) {
    return array_contains(WDTT_COMMUNITY_LISTS, value);
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

    let peer = as_string(section.peer || "");
    if (peer != "" && !valid_peer(peer))
        push(errors, "peer must be in HOST:PORT format");

    let mode = as_string(section.mode || "");
    if (!valid_mode(mode))
        push(errors, "mode must be one of: " + join(", ", WDTT_MODES));

    let qwdtt_mode = as_string(section.qwdtt_mode || "");
    if (!valid_qwdtt_mode(qwdtt_mode))
        push(errors, "qwdtt_mode must be one of: " + join(", ", QWDTT_MODES));

    let workers = as_string(section.workers || "");
    if (workers != "" && !valid_number(workers, 1, 1024))
        push(errors, "workers must be 1-1024");

    let max_hashes = as_string(section.max_hashes || "");
    if (max_hashes != "" && !valid_number(max_hashes, 1, 64))
        push(errors, "max_hashes must be 1-64");

    let mtu = as_string(section.mtu || "");
    if (mtu != "" && !valid_number(mtu, 576, 1500))
        push(errors, "mtu must be 576-1500");

    let subscription_links = list_values(section.subscription_links);
    for (let link in subscription_links) {
        link = trim(as_string(link));
        if (link == "")
            continue;
        if (substr(link, 0, 7) == "wdtt://") {
            let parsed = parse_wdtt_uri(link);
            if (!parsed.valid)
                push(errors, "invalid wdtt:// URI: " + parsed.reason);
        }
        else if (substr(link, 0, 1) == "/") {
            /* local file — ok */
        }
        else if (!valid_url(link))
            push(errors, "subscription link must be HTTP URL, wdtt:// URI, or local file path: " + link);
    }

    let community_lists = list_values(section.community_lists);
    for (let cl in community_lists) {
        if (!valid_community_list(cl))
            push(errors, "unknown community list: " + cl);
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
    parse_wdtt_uri,
    url_decode,
    valid_peer,
    valid_mode,
    valid_qwdtt_mode,
    valid_url,
    valid_community_list,
    list_values,
    modes: WDTT_MODES,
    qwdtt_modes: QWDTT_MODES,
    community_lists: WDTT_COMMUNITY_LISTS
};
