#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;

function first_index_any(value, needles, start) {
    value = as_string(value);
    start = int(start || 0);

    for (let i = start; i < length(value); i++) {
        let c = substr(value, i, 1);
        for (let needle in needles)
            if (c == needle)
                return i;
    }

    return -1;
}

function hex_digit_value(code) {
    if (code >= 48 && code <= 57)
        return code - 48;
    if (code >= 97 && code <= 102)
        return code - 87;
    if (code >= 65 && code <= 70)
        return code - 55;
    return -1;
}

function decode(value) {
    value = as_string(value);
    if (index(value, "%") < 0 && index(value, "+") < 0)
        return value;

    let result = "";
    let len = length(value);

    for (let i = 0; i < len; i++) {
        let code = ord(value, i);
        if (code == 43) {
            result += " ";
            continue;
        }
        if (code == 37) {
            if (i + 2 < len) {
                let high = hex_digit_value(ord(value, i + 1));
                let low = hex_digit_value(ord(value, i + 2));
                if (high >= 0 && low >= 0) {
                    result += chr(high * 16 + low);
                    i += 2;
                    continue;
                }
            }
        }
        result += chr(code);
    }

    return result;
}

function scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? lc(substr(value, 0, marker)) : "";
}

function fragment(value) {
    value = as_string(value);
    let marker = index(value, "#");
    return marker >= 0 ? decode(substr(value, marker + 1)) : "";
}

function strip_fragment(value) {
    value = as_string(value);
    let marker = index(value, "#");
    return marker >= 0 ? substr(value, 0, marker) : value;
}

function strip_anchored_scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    if (marker < 0)
        return value;

    let prefix = substr(value, 0, marker);
    if (index(prefix, "/") >= 0 || index(prefix, "?") >= 0)
        return value;

    return substr(value, marker + 3);
}

function strip_first_scheme_marker(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? substr(value, marker + 3) : value;
}

function authority(value) {
    value = strip_first_scheme_marker(value);
    let at = rindex(value, "@");
    if (at >= 0)
        value = substr(value, at + 1);

    let end = first_index_any(value, ["/", "?", "#"], 0);
    return end >= 0 ? substr(value, 0, end) : value;
}

function host(value) {
    let value_authority = authority(value);
    if (substr(value_authority, 0, 1) == "[") {
        let end = index(value_authority, "]");
        return end > 0 ? substr(value_authority, 1, end - 1) : value_authority;
    }

    let colon = index(value_authority, ":");
    if (colon < 0)
        return value_authority;

    return rindex(value_authority, ":") == colon ? substr(value_authority, 0, colon) : value_authority;
}

function port(value) {
    let value_authority = authority(value);
    if (substr(value_authority, 0, 1) == "[") {
        let end = index(value_authority, "]");
        if (end > 0 && substr(value_authority, end + 1, 1) == ":")
            return substr(value_authority, end + 2);
        return "";
    }

    let colon = index(value_authority, ":");
    if (colon < 0 || rindex(value_authority, ":") != colon)
        return "";

    return substr(value_authority, colon + 1);
}

function userinfo(value) {
    let value_authority = strip_first_scheme_marker(strip_fragment(value));
    let end = first_index_any(value_authority, ["/", "?", "#"], 0);
    value_authority = end >= 0 ? substr(value_authority, 0, end) : value_authority;
    let at = rindex(value_authority, "@");
    return at >= 0 ? decode(substr(value_authority, 0, at)) : "";
}

function path(value) {
    value = strip_anchored_scheme(value);
    let slash = index(value, "/");
    value = slash >= 0 ? substr(value, slash) : "";

    let query = index(value, "?");
    if (query >= 0)
        value = substr(value, 0, query);

    return value;
}

function query_params(value) {
    let result = {};
    value = as_string(value);
    let question = index(value, "?");
    if (question < 0)
        return result;

    let query = substr(value, question + 1);
    let hash = index(query, "#");
    if (hash >= 0)
        query = substr(query, 0, hash);

    for (let pair in split(query, "&")) {
        if (pair == "")
            continue;
        let equals = index(pair, "=");
        let key = decode(equals >= 0 ? substr(pair, 0, equals) : pair);
        let value = equals >= 0 ? decode(substr(pair, equals + 1)) : "";
        if (key != "")
            result[key] = value;
    }
    return result;
}

function normalize_github_raw(url) {
    url = as_string(url);
    let marker = "github.com/";
    let marker_idx = index(url, marker);
    if (marker_idx < 0)
        return url;

    let path_part = substr(url, marker_idx + length(marker));
    let slash1 = index(path_part, "/");
    if (slash1 < 0) return url;
    let owner = substr(path_part, 0, slash1);
    let rest = substr(path_part, slash1 + 1);
    let slash2 = index(rest, "/");
    if (slash2 < 0) return url;
    let repo = substr(rest, 0, slash2);
    let tail = substr(rest, slash2 + 1);

    let clean_tail = tail;
    let q = index(clean_tail, "?");
    if (q >= 0) clean_tail = substr(clean_tail, 0, q);
    let h = index(clean_tail, "#");
    if (h >= 0) clean_tail = substr(clean_tail, 0, h);

    if (index(clean_tail, "blob/") == 0) {
        let subpath = substr(clean_tail, 5);
        return "https://raw.githubusercontent.com/" + owner + "/" + repo + "/" + subpath;
    }
    if (index(clean_tail, "raw/") == 0) {
        let subpath = substr(clean_tail, 4);
        return "https://raw.githubusercontent.com/" + owner + "/" + repo + "/" + subpath;
    }

    return url;
}

function github_to_jsdelivr(url) {
    url = as_string(url);
    let marker_gh = "github.com/";
    let marker_raw = "raw.githubusercontent.com/";
    let idx_gh = index(url, marker_gh);
    let idx_raw = index(url, marker_raw);

    if (idx_gh < 0 && idx_raw < 0)
        return "";

    let owner = "", repo = "", ref = "", file = "";

    if (idx_raw >= 0) {
        let path_part = substr(url, idx_raw + length(marker_raw));
        let slash1 = index(path_part, "/");
        if (slash1 < 0) return "";
        owner = substr(path_part, 0, slash1);
        let rest = substr(path_part, slash1 + 1);
        let slash2 = index(rest, "/");
        if (slash2 < 0) return "";
        repo = substr(rest, 0, slash2);
        let tail = substr(rest, slash2 + 1);
        let slash3 = index(tail, "/");
        if (slash3 < 0) return "";
        ref = substr(tail, 0, slash3);
        file = substr(tail, slash3 + 1);
    } else {
        let path_part = substr(url, idx_gh + length(marker_gh));
        let slash1 = index(path_part, "/");
        if (slash1 < 0) return "";
        owner = substr(path_part, 0, slash1);
        let rest = substr(path_part, slash1 + 1);
        let slash2 = index(rest, "/");
        if (slash2 < 0) return "";
        repo = substr(rest, 0, slash2);
        let tail = substr(rest, slash2 + 1);

        let slash3 = index(tail, "/");
        if (slash3 < 0) return "";
        let segment3 = substr(tail, 0, slash3);
        let remainder = substr(tail, slash3 + 1);
        if (remainder == "") return "";

        if (segment3 == "releases" && index(tail, "releases/download/") == 0) {
            let dl_path = substr(tail, 17);
            let dl_slash = index(dl_path, "/");
            if (dl_slash < 0) return "";
            ref = substr(dl_path, 0, dl_slash);
            file = substr(dl_path, dl_slash + 1);
        } else if (segment3 == "raw" || segment3 == "blob") {
            let raw_slash = index(remainder, "/");
            if (raw_slash < 0) return "";
            ref = substr(remainder, 0, raw_slash);
            file = substr(remainder, raw_slash + 1);
        } else {
            ref = segment3;
            file = remainder;
        }
    }

    if (ref == "" || file == "")
        return "";
    return "https://cdn.jsdelivr.net/gh/" + owner + "/" + repo + "@" + ref + "/" + file;
}

function download_candidates(value) {
    value = as_string(value);
    if (value == "")
        return [];

    value = normalize_github_raw(value);

    let candidates = [ value ];
    let is_github = index(value, "github.com") >= 0 ||
                    index(value, "raw.githubusercontent.com") >= 0 ||
                    index(value, "githubusercontent.com") >= 0;
    let is_http = substr(value, 0, 7) == "http://" || substr(value, 0, 8) == "https://";

    if (is_github || is_http) {
        let jsd = github_to_jsdelivr(value);
        if (jsd != "")
            push(candidates, jsd);

        let mirrors = [
            "https://ghproxy.net/",
            "https://mirror.ghproxy.com/",
            "https://gh-proxy.com/"
        ];
        for (let prefix in mirrors) {
            if (index(value, prefix) != 0)
                push(candidates, prefix + value);
        }
    }

    return candidates;
}

return {
    decode,
    scheme,
    fragment,
    strip_fragment,
    strip_anchored_scheme,
    host,
    port,
    userinfo,
    path,
    query_params,
    normalize_github_raw,
    github_to_jsdelivr,
    download_candidates
};