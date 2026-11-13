#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let happ = require("subscription.happ");
let wireguard = require("subscription.wireguard");
let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let write_json = common.write_json;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let shell_quote = common.shell_quote;

function first_non_ws_char(value) {
    let m = match(as_string(value), /^[ \t\r\n]*([^ \t\r\n])/);
    return m ? m[1] : "";
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function is_supported_share_link(line) {
    return starts_with(line, "vpn://") ||
        starts_with(line, "amneziawg://") ||
        starts_with(line, "awg://") ||
        starts_with(line, "wireguard://") ||
        starts_with(line, "wg://") ||
        starts_with(line, "ss://") ||
        starts_with(line, "vmess://") ||
        starts_with(line, "vless://") ||
        starts_with(line, "trojan://") ||
        starts_with(line, "trojan-go://") ||
        starts_with(line, "hysteria2://") ||
        starts_with(line, "hy2://") ||
        starts_with(line, "hysteria://") ||
        starts_with(line, "hy://") ||
        starts_with(line, "tuic://") ||
        starts_with(line, "tuic5://") ||
        starts_with(line, "socks://") ||
        starts_with(line, "socks4://") ||
        starts_with(line, "socks4a://") ||
        starts_with(line, "socks5://") ||
        starts_with(line, "http://") ||
        starts_with(line, "https://") ||
        starts_with(line, "fptn:") ||
        starts_with(line, "fptnb:") ||
        starts_with(line, "fptn://") ||
        starts_with(line, "fptnb://") ||
        starts_with(line, "anytls://") ||
        starts_with(line, "naive://") ||
        starts_with(line, "naive+https://") ||
        starts_with(line, "naive+http2://") ||
        starts_with(line, "naive+h2://") ||
        starts_with(line, "naive+quic://") ||
        starts_with(line, "naive+h3://") ||
        starts_with(line, "snell://") ||
        starts_with(line, "mieru://") ||
        starts_with(line, "mierus://") ||
        starts_with(line, "tg://proxy?") ||
        starts_with(line, "mtproto://") ||
        starts_with(line, "tewfai://") ||
        starts_with(line, "trusttunnel://") ||
        starts_with(line, "masque://") ||
        starts_with(line, "openconnect://") ||
        starts_with(line, "anyconnect://") ||
        starts_with(line, "shadowtls://") ||
        starts_with(line, "stls://") ||
        starts_with(line, "sudoku://") ||
        starts_with(line, "ssh://") ||
        starts_with(lc(line), "csqtt://") ||
        starts_with(lc(line), "wdtt://") ||
        starts_with(lc(line), "qwdtt://") ||
        happ.is_encrypted(line);
}

function split_csv(value) {
    let result = [];
    for (let item in split(as_string(value), ",")) {
        if (item != "")
            push(result, item);
    }
    return result;
}

function tls_alpn_for_transport(alpn, transport) {
    transport = lc(as_string(transport));
    if (transport == "xhttp" && length(alpn) == 0)
        return ["h2", "http/1.1"];
    if (transport == "ws" || transport == "httpupgrade")
        return ["http/1.1"];
    return alpn;
}

function is_dummy_server(server, port) {
    server = trim(lc(as_string(server)));
    if (server == "" || server == "0.0.0.0" || server == "::" ||
        substr(server, 0, 8) == "0.0.0.0:")
        return true;
    if (port != null && int(port) == 0)
        return true;
    return false;
}

function is_true(value) {
    if (value == null || value == "")
        return false;
    let normalized = lc(as_string(value));
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on";
}

function is_integer_string(value) {
    return type(value) == "string" && match(value, /^[0-9]+$/) != null;
}

function xhttp_value_present(value) {
    return value != null && as_string(value) != "";
}

function xhttp_object_arg(value) {
    if (type(value) == "object")
        return value;

    try {
        let parsed = json(as_string(value));
        return type(parsed) == "object" ? parsed : {};
    }
    catch (e) {
        return {};
    }
}

function xhttp_copy_known_settings(target, source) {
    if (type(source) != "object")
        return;

    for (let key in [
        "xPaddingBytes",
        "x_padding_bytes",
        "noGRPCHeader",
        "noGrpcHeader",
        "no_grpc_header",
        "noSSEHeader",
        "noSseHeader",
        "no_sse_header",
        "scMaxEachPostBytes",
        "sc_max_each_post_bytes",
        "scMinPostsIntervalMs",
        "sc_min_posts_interval_ms",
        "scStreamUpServerSecs",
        "sc_stream_up_server_secs",
        "scMaxBufferedPosts",
        "sc_max_buffered_posts",
        "scMaxConcurrentPosts",
        "sc_max_concurrent_posts",
        "serverMaxHeaderBytes",
        "server_max_header_bytes",
        "sessionPlacement",
        "SessionIDPlacement",
        "sessionIDPlacement",
        "sessionIdPlacement",
        "session_placement",
        "session_id_placement",
        "sessionKey",
        "SessionIDKey",
        "sessionIDKey",
        "sessionIdKey",
        "session_key",
        "session_id_key",
        "sessionTable",
        "SessionIDTable",
        "sessionIDTable",
        "sessionIdTable",
        "session_table",
        "session_id_table",
        "sessionLength",
        "SessionIDLength",
        "sessionIDLength",
        "sessionIdLength",
        "session_length",
        "session_id_length",
        "seqPlacement",
        "seq_placement",
        "seqKey",
        "seq_key",
        "uplinkDataPlacement",
        "uplink_data_placement",
        "uplinkDataKey",
        "uplink_data_key",
        "uplinkChunkSize",
        "uplink_chunk_size",
        "uplinkHttpMethod",
        "uplinkHTTPMethod",
        "uplink_http_method",
        "xPaddingObfsMode",
        "x_padding_obfs_mode",
        "xPaddingPlacement",
        "x_padding_placement",
        "xPaddingKey",
        "x_padding_key",
        "xPaddingHeader",
        "x_padding_header",
        "xPaddingMethod",
        "x_padding_method",
        "xmux"
    ]) {
        if (xhttp_value_present(source[key]))
            target[key] = source[key];
    }

    if (type(source.headers) == "object" && length(keys(source.headers)) > 0)
        target.headers = source.headers;
}

function xhttp_merge_extra_settings(target, value) {
    let extra = xhttp_object_arg(value);
    if (type(extra) != "object")
        return;

    xhttp_copy_known_settings(target, extra);

    let xhttp_settings = xhttp_object_arg(extra.xhttpSettings);
    xhttp_copy_known_settings(target, xhttp_settings);
    xhttp_copy_known_settings(target, xhttp_object_arg(xhttp_settings.extra));

    let download_settings = xhttp_object_arg(extra.downloadSettings);
    let download_xhttp_settings = xhttp_object_arg(download_settings.xhttpSettings);
    xhttp_copy_known_settings(target, download_xhttp_settings);
    xhttp_copy_known_settings(target, xhttp_object_arg(download_xhttp_settings.extra));
}

function xhttp_extra_settings(query) {
    let result = {};
    query = type(query) == "object" ? query : {};
    xhttp_merge_extra_settings(result, query.extra);
    return result;
}

// Xray/Remnawave spell a few xHTTP settings differently from sing-box:
// `uplinkHTTPMethod` (capital HTTP), and the session id fields are
// `SessionIDPlacement` / `sessionIDPlacement` / `SessionIDKey` /
// `sessionIDKey`. Reading only the sing-box spellings dropped them, so a node
// that needed them silently lost its session config and timed out.
// Each alias argument accepts a list; the first present value wins.
function xhttp_alias_keys(value) {
    if (type(value) == "array")
        return value;
    return value == null || value == "" ? [] : [ value ];
}

function xhttp_setting_value(query, extra_settings, camel_key, snake_key) {
    query = type(query) == "object" ? query : {};
    extra_settings = type(extra_settings) == "object" ? extra_settings : {};
    for (let key in xhttp_alias_keys(camel_key))
        for (let value in [ query[key], extra_settings[key] ])
            if (xhttp_value_present(value))
                return value;
    for (let key in xhttp_alias_keys(snake_key))
        for (let value in [ query[key], extra_settings[key] ])
            if (xhttp_value_present(value))
                return value;
    return null;
}

function xhttp_non_negative_integer_value(value) {
    if (type(value) == "int" || type(value) == "double") {
        let number = int(value);
        return number == value && number >= 0 ? number : null;
    }

    value = trim(as_string(value));
    if (!is_integer_string(value))
        return null;

    return int(value, 10);
}

function xhttp_positive_integer_value(value) {
    let number = xhttp_non_negative_integer_value(value);
    return number != null && number > 0 ? number : null;
}

function xhttp_range_value(value, positive) {
    if (!xhttp_value_present(value))
        return null;

    if (type(value) == "object") {
        let from = positive ? xhttp_positive_integer_value(value.from) : xhttp_non_negative_integer_value(value.from);
        let to = positive ? xhttp_positive_integer_value(value.to) : xhttp_non_negative_integer_value(value.to);
        return from != null && to != null && from <= to ? (from == to ? as_string(from) : from + "-" + to) : null;
    }

    if (type(value) == "array" && length(value) == 2) {
        let from = positive ? xhttp_positive_integer_value(value[0]) : xhttp_non_negative_integer_value(value[0]);
        let to = positive ? xhttp_positive_integer_value(value[1]) : xhttp_non_negative_integer_value(value[1]);
        return from != null && to != null && from <= to ? (from == to ? as_string(from) : from + "-" + to) : null;
    }

    let number = positive ? xhttp_positive_integer_value(value) : xhttp_non_negative_integer_value(value);
    if (number != null)
        return as_string(number);

    value = trim(as_string(value));
    let dash = index(value, "-");
    if (dash < 0 || index(substr(value, dash + 1), "-") >= 0)
        return null;

    let from = positive ? xhttp_positive_integer_value(substr(value, 0, dash)) : xhttp_non_negative_integer_value(substr(value, 0, dash));
    let to = positive ? xhttp_positive_integer_value(substr(value, dash + 1)) : xhttp_non_negative_integer_value(substr(value, dash + 1));
    return from != null && to != null && from <= to ? from + "-" + to : null;
}

function xhttp_optional_range(object, key, value) {
    let normalized = xhttp_range_value(value, false);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_optional_positive_range(object, key, value) {
    let normalized = xhttp_range_value(value, true);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_positive_range_or_default(value, default_value) {
    let normalized = xhttp_range_value(value, true);
    return normalized != null ? normalized : default_value;
}

function xhttp_present_positive_range_or_default(value, default_value) {
    if (!xhttp_value_present(value))
        return null;

    return xhttp_positive_range_or_default(value, default_value);
}

function xhttp_optional_bool(object, key, value) {
    if (xhttp_value_present(value))
        object[key] = is_true(value);
}

function xhttp_object_setting_value(source, camel_key, snake_key) {
    source = type(source) == "object" ? source : {};
    for (let value in [source[camel_key], source[snake_key]]) {
        if (xhttp_value_present(value))
            return value;
    }
    return null;
}

function xhttp_optional_xmux_range(object, key, value) {
    let normalized = xhttp_range_value(value, false);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_optional_xmux_integer(object, key, value) {
    let normalized = xhttp_non_negative_integer_value(value);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_normalize_xmux(value) {
    let source = xhttp_object_arg(value);
    if (type(source) != "object")
        return null;

    let result = {};
    xhttp_optional_xmux_range(result, "max_concurrency", xhttp_object_setting_value(source, "maxConcurrency", "max_concurrency"));
    xhttp_optional_xmux_range(result, "max_connections", xhttp_object_setting_value(source, "maxConnections", "max_connections"));
    xhttp_optional_xmux_range(result, "c_max_reuse_times", xhttp_object_setting_value(source, "cMaxReuseTimes", "c_max_reuse_times"));
    xhttp_optional_xmux_range(result, "h_max_request_times", xhttp_object_setting_value(source, "hMaxRequestTimes", "h_max_request_times"));
    let max_reusable = xhttp_object_setting_value(source, "hMaxReusableSecs", "h_max_reusable_secs");
    if (max_reusable == null)
        max_reusable = source.maxReusableSecs;
    xhttp_optional_xmux_range(result, "h_max_reusable_secs", max_reusable);
    xhttp_optional_xmux_integer(result, "h_keep_alive_period", xhttp_object_setting_value(source, "hKeepAlivePeriod", "h_keep_alive_period"));

    if (result.max_connections == "0" || result.max_connections == "0-0")
        delete result.max_connections;
    if (result.max_connections != null && (result.max_concurrency == "0" || result.max_concurrency == "0-0"))
        delete result.max_concurrency;

    return length(keys(result)) > 0 ? result : null;
}

function xhttp_normalize_headers(value) {
    let source = xhttp_object_arg(value);
    if (type(source) != "object")
        return null;

    let result = {};
    for (let k, v in source) {
        let key = trim(as_string(k));
        if (key == "")
            continue;
        if (type(v) == "array") {
            for (let item in v) {
                let s = trim(as_string(item));
                if (s != "") {
                    result[key] = s;
                    break;
                }
            }
        } else if (v != null) {
            let s = trim(as_string(v));
            if (s != "")
                result[key] = s;
        }
    }

    return length(keys(result)) > 0 ? result : null;
}

function xhttp_optional_string(object, key, value) {
    if (!xhttp_value_present(value))
        return;
    value = trim(as_string(value));
    if (value != "")
        object[key] = value;
}

function xhttp_optional_positive_integer(object, key, value) {
    let number = xhttp_positive_integer_value(value);
    if (number != null)
        object[key] = number;
}

function xhttp_optional_enum(object, key, value, allowed) {
    if (!xhttp_value_present(value))
        return;
    let normalized = lc(trim(as_string(value)));
    for (let candidate in allowed) {
        if (normalized == lc(as_string(candidate))) {
            object[key] = as_string(candidate);
            return;
        }
    }
}

function xhttp_apply_v2_settings(result, primary, extra) {
    // XHTTP v2 keys (session/seq placement, uplink-data placement, X-Padding
    // obfuscation). Every field is opt-in per the sing-box-lx contract; the
    // v1 wire shape stays byte-identical when none are present.
    xhttp_optional_enum(result, "session_placement", xhttp_setting_value(primary, extra, [ "sessionPlacement", "SessionIDPlacement", "sessionIDPlacement", "sessionIdPlacement" ], [ "session_placement", "session_id_placement" ]), [ "path", "query", "header", "cookie" ]);
    xhttp_optional_string(result, "session_key", xhttp_setting_value(primary, extra, [ "sessionKey", "SessionIDKey", "sessionIDKey", "sessionIdKey" ], [ "session_key", "session_id_key" ]));
    xhttp_optional_string(result, "session_table", xhttp_setting_value(primary, extra, [ "sessionTable", "SessionIDTable", "sessionIDTable", "sessionIdTable" ], [ "session_table", "session_id_table" ]));
    xhttp_optional_positive_range(result, "session_length", xhttp_setting_value(primary, extra, [ "sessionLength", "SessionIDLength", "sessionIDLength", "sessionIdLength" ], [ "session_length", "session_id_length" ]));
    xhttp_optional_enum(result, "seq_placement", xhttp_setting_value(primary, extra, "seqPlacement", "seq_placement"), [ "path", "query", "header", "cookie" ]);
    xhttp_optional_string(result, "seq_key", xhttp_setting_value(primary, extra, "seqKey", "seq_key"));
    xhttp_optional_enum(result, "uplink_data_placement", xhttp_setting_value(primary, extra, "uplinkDataPlacement", "uplink_data_placement"), [ "body", "auto", "header", "cookie" ]);
    xhttp_optional_string(result, "uplink_data_key", xhttp_setting_value(primary, extra, "uplinkDataKey", "uplink_data_key"));
    xhttp_optional_positive_range(result, "uplink_chunk_size", xhttp_setting_value(primary, extra, "uplinkChunkSize", "uplink_chunk_size"));
    xhttp_optional_enum(result, "uplink_http_method", xhttp_setting_value(primary, extra, [ "uplinkHttpMethod", "uplinkHTTPMethod" ], "uplink_http_method"), [ "POST", "GET" ]);
    xhttp_optional_bool(result, "no_sse_header", xhttp_setting_value(primary, extra, [ "noSSEHeader", "noSseHeader" ], "no_sse_header"));
    xhttp_optional_positive_integer(result, "sc_max_buffered_posts", xhttp_setting_value(primary, extra, "scMaxBufferedPosts", "sc_max_buffered_posts"));
    xhttp_optional_positive_integer(result, "sc_max_concurrent_posts", xhttp_setting_value(primary, extra, "scMaxConcurrentPosts", "sc_max_concurrent_posts"));
    xhttp_optional_positive_integer(result, "server_max_header_bytes", xhttp_setting_value(primary, extra, "serverMaxHeaderBytes", "server_max_header_bytes"));
    xhttp_optional_bool(result, "x_padding_obfs_mode", xhttp_setting_value(primary, extra, "xPaddingObfsMode", "x_padding_obfs_mode"));
    xhttp_optional_enum(result, "x_padding_placement", xhttp_setting_value(primary, extra, "xPaddingPlacement", "x_padding_placement"), [ "cookie", "header", "query", "queryInHeader" ]);
    xhttp_optional_string(result, "x_padding_key", xhttp_setting_value(primary, extra, "xPaddingKey", "x_padding_key"));
    xhttp_optional_string(result, "x_padding_header", xhttp_setting_value(primary, extra, "xPaddingHeader", "x_padding_header"));
    xhttp_optional_enum(result, "x_padding_method", xhttp_setting_value(primary, extra, "xPaddingMethod", "x_padding_method"), [ "repeat-x", "tokenish" ]);
    let headers = xhttp_normalize_headers(xhttp_setting_value(primary, extra, "headers", "headers"));
    if (headers)
        result.headers = headers;
}

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function read_file(path) {
    let stat = fs.stat(path);
    if (stat != null && stat.size != null && stat.size > 15728640) {
        warn(sprintf("File %s exceeds maximum size limit (15MB)\n", path));
        return null;
    }
    return fs.readfile(path);
}


function reality_public_key_valid(value) {
    return match(as_string(value), /^[A-Za-z0-9_-]{43}=?$/) != null;
}

function outbound_is_unsupported_stub(outbound) {
    if (type(outbound) != "object")
        return false;

    let tag = lc(as_string(outbound.tag || outbound.name || outbound.remark || ""));
    let server = lc(trim(as_string(outbound.server || "")));

    if (index(tag, "не поддерживается") >= 0 ||
        index(tag, "неподдерживаем") >= 0 ||
        index(tag, "клиент не поддерживается") >= 0 ||
        index(tag, "приложение не поддерживается") >= 0 ||
        index(tag, "unsupported") >= 0 ||
        index(tag, "not supported") >= 0 ||
        index(tag, "update app") >= 0 ||
        index(tag, "update client") >= 0 ||
        index(tag, "обновите приложение") >= 0 ||
        index(tag, "обновите клиент") >= 0 ||
        index(tag, "скачайте happ") >= 0 ||
        index(tag, "скачать happ") >= 0 ||
        index(tag, "используйте happ") >= 0 ||
        index(tag, "use happ") >= 0 ||
        index(tag, "download happ") >= 0 ||
        index(tag, "скачайте v2box") >= 0 ||
        index(tag, "используйте v2box") >= 0 ||
        index(tag, "скачайте v2rayn") >= 0 ||
        index(tag, "используйте v2rayn") >= 0)
        return true;

    let is_dummy_server = (
        server == "" ||
        server == "127.0.0.1" ||
        server == "0.0.0.0" ||
        server == "localhost" ||
        server == "::1" ||
        server == "0.0.0.1"
    );

    if (is_dummy_server && (
        index(tag, "⚠️") >= 0 ||
        index(tag, "❗") >= 0 ||
        index(tag, "❌") >= 0 ||
        index(tag, "📊") >= 0 ||
        index(tag, "📈") >= 0 ||
        index(tag, "📉") >= 0 ||
        index(tag, "📅") >= 0 ||
        index(tag, "⏳") >= 0 ||
        index(tag, "⏰") >= 0 ||
        index(tag, "|") >= 0 ||
        index(tag, "warning") >= 0 ||
        index(tag, "error") >= 0 ||
        index(tag, "notice") >= 0 ||
        index(tag, "attention") >= 0 ||
        index(tag, "внимание") >= 0 ||
        index(tag, "ошибка") >= 0 ||
        index(tag, "traffic") >= 0 ||
        index(tag, "трафик") >= 0 ||
        index(tag, "expire") >= 0 ||
        index(tag, "истекает") >= 0 ||
        index(tag, "осталось") >= 0 ||
        match(tag, /[0-9]+(\.[0-9]+)?[ \t]*(gb|mb|tb|гб|мб|тб)/) != null
    ))
        return true;

    return false;
}

function validate_subscription(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || type(value.outbounds) != "array" || length(value.outbounds) == 0)
        return false;

    let usable_count = 0;
    let filtered = [];
    let dropped_invalid_reality = false;
    for (let outbound in value.outbounds) {
        if (outbound_is_unsupported_stub(outbound)) {
            push(filtered, outbound);
            continue;
        }

        let tls = type(outbound) == "object" && type(outbound.tls) == "object" ? outbound.tls : {};
        let reality = tls.reality;
        if (type(reality) == "object" && reality.enabled != false && !reality_public_key_valid(reality.public_key)) {
            dropped_invalid_reality = true;
            continue;
        }

        push(filtered, outbound);
        usable_count++;
    }

    if (usable_count == 0)
        return false;

    if (dropped_invalid_reality) {
        value.outbounds = filtered;
        write_json_file(path, value);
    }

    return true;
}


function canonical_runtime_value(value, parent_name) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, canonical_runtime_value(item));
        return result;
    }

    if (type(value) == "object") {
        let result = {};
        let names = keys(value);
        sort(names, function(a, b) {
            return a < b ? -1 : (a > b ? 1 : 0);
        });

        for (let name in names) {
            if (name == "share_link")
                continue;
            // Panels (Marzban, Remnawave, 3x-ui) hand out a random Reality short_id from
            // the server's list on every fetch; that alone must not reload tachyon-core.
            if (parent_name == "reality" && name == "short_id")
                continue;
            result[name] = canonical_runtime_value(value[name], name);
        }

        return result;
    }

    return value;
}

function runtime_outbounds_signature(path) {
    let subscription = read_json_file(path);
    if (type(subscription) != "object" || type(subscription.outbounds) != "array")
        return null;

    let result = [];
    for (let outbound in subscription.outbounds)
        push(result, sprintf("%J", canonical_runtime_value(outbound)));

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });

    return result;
}

function runtime_outbounds_equal(left_path, right_path) {
    let left = runtime_outbounds_signature(left_path);
    let right = runtime_outbounds_signature(right_path);

    if (left == null || right == null)
        return false;

    return sprintf("%J", left) == sprintf("%J", right);
}

function base64_decode(value) {
    value = as_string(value);
    if (index(value, "\n") >= 0 || index(value, "\r") >= 0 || index(value, "\t") >= 0 || index(value, " ") >= 0)
        value = replace(value, /\s+/g, "");
    if (index(value, "-") >= 0)
        value = replace(value, /-/g, "+");
    if (index(value, "_") >= 0)
        value = replace(value, /_/g, "/");
    if (value == "")
        return null;

    let remainder = length(value) % 4;
    if (remainder == 1)
        return null;
    if (remainder > 1) {
        for (let i = 0; i < 4 - remainder; i++)
            value += "=";
    }

    return b64dec(value);
}

function urldecode(value) {
    value = as_string(value);
    if (index(value, "%") < 0 && index(value, "+") < 0)
        return value;

    if (index(value, "+") >= 0)
        value = replace(value, /\+/g, " ");
    if (index(value, "%") < 0)
        return value;
    return replace(value, /%([0-9A-Fa-f][0-9A-Fa-f])/g, function(all, hex_value) {
        return chr(hex(hex_value));
    });
}

let fragment_prefix_decode_cache = {};
let fragment_decode_cache = {};
let query_parse_cache = {};

function urldecode_fragment(value) {
    value = as_string(value);
    if (index(value, "%") < 0 && index(value, "+") < 0)
        return value;
    if (value in fragment_decode_cache)
        return fragment_decode_cache[value];

    let marker = rindex(value, "%23");
    if (marker >= 0) {
        let suffix = substr(value, marker + 3);
        if (is_integer_string(suffix)) {
            let prefix = substr(value, 0, marker + 3);
            if (!(prefix in fragment_prefix_decode_cache))
                fragment_prefix_decode_cache[prefix] = urldecode(prefix);
            let decoded = fragment_prefix_decode_cache[prefix] + suffix;
            fragment_decode_cache[value] = decoded;
            return decoded;
        }
    }

    let decoded = urldecode(value);
    fragment_decode_cache[value] = decoded;
    return decoded;
}

function subscription_url_fragment(url) {
    url = as_string(url);
    let marker = index(url, "#");
    if (marker < 0) {
        print("\n");
        return true;
    }

    let fragment = substr(url, marker + 1);
    if (index(fragment, "%") >= 0 || index(fragment, "+") >= 0)
        print(urldecode_fragment(fragment));
    else
        print(fragment, "\n");
    return true;
}

function parse_query(query) {
    let params = {};
    query = as_string(query);
    if (query == "")
        return params;
    if (query in query_parse_cache)
        return query_parse_cache[query];

    for (let pair in split(query, "&")) {
        if (pair == "")
            continue;
        let equals = index(pair, "=");
        let key = equals >= 0 ? substr(pair, 0, equals) : pair;
        let value = equals >= 0 ? substr(pair, equals + 1) : "";
        key = urldecode(key);
        if (key != "")
            params[key] = urldecode(value);
    }

    query_parse_cache[query] = params;
    return params;
}

function parse_port_value(value) {
    value = as_string(value);
    return is_integer_string(value) ? int(value, 10) : value;
}

function parse_host_port(value) {
    value = as_string(value);
    if (length(value) > 0 && substr(value, length(value) - 1) == "/")
        value = substr(value, 0, length(value) - 1);
    if (starts_with(value, "[")) {
        let m = match(value, /^\[([^\]]+)\]:(.+)$/);
        if (m)
            return [m[1], parse_port_value(m[2])];
        let m_host = match(value, /^\[([^\]]+)\]$/);
        return m_host ? [m_host[1], null] : ["", null];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return [value, null];

    let host = substr(value, 0, colon);
    let port = substr(value, colon + 1);
    return [host, parse_port_value(port)];
}

function parse_url(url) {
    let scheme_pos = index(url, "://");
    if (scheme_pos <= 0)
        return null;

    let scheme = lc(substr(url, 0, scheme_pos));
    let rest = substr(url, scheme_pos + 3);
    let fragment = "";
    let hash_pos = index(rest, "#");
    if (hash_pos >= 0) {
        fragment = urldecode_fragment(substr(rest, hash_pos + 1));
        rest = substr(rest, 0, hash_pos);
    }

    let query = "";
    let question_pos = index(rest, "?");
    if (question_pos >= 0) {
        query = substr(rest, question_pos + 1);
        rest = substr(rest, 0, question_pos);
    }

    let slash_pos = index(rest, "/");
    let authority = slash_pos >= 0 ? substr(rest, 0, slash_pos) : rest;
    let userinfo = "";
    let hostport = authority;
    let at_pos = rindex(authority, "@");
    if (at_pos >= 0) {
        userinfo = urldecode(substr(authority, 0, at_pos));
        hostport = substr(authority, at_pos + 1);
    }

    let host_port = parse_host_port(hostport);
    return {
        scheme: scheme,
        userinfo: userinfo,
        host: host_port[0] || "",
        port: host_port[1],
        query: parse_query(query),
        fragment: fragment
    };
}

function normalize_utls_fingerprint(value) {
    if (value == null || value == "")
        return "";

    let allowed = {
        "": true,
        chrome: true,
        firefox: true,
        edge: true,
        safari: true,
        "360": true,
        ios: true,
        android: true,
        randomized: true,
        randomizedalpn: true,
        randomizednoalpn: true
    };

    value = lc(trim(as_string(value)));
    if (allowed[value])
        return value;
    if (value == "random" || starts_with(value, "hellorandomized") || starts_with(value, "randomized"))
        return "randomized";
    if (starts_with(value, "hellochrome") || starts_with(value, "chrome"))
        return "chrome";
    if (starts_with(value, "hellofirefox") || starts_with(value, "firefox"))
        return "firefox";
    if (starts_with(value, "hellosafari") || starts_with(value, "safari"))
        return "safari";
    if (starts_with(value, "helloios") || starts_with(value, "ios"))
        return "ios";
    if (starts_with(value, "helloandroid") || starts_with(value, "android"))
        return "android";
    if (starts_with(value, "helloedge") || starts_with(value, "edge"))
        return "edge";
    if (starts_with(value, "hello360") || starts_with(value, "360"))
        return "360";
    return "chrome";
}

function finalmask_has_tcp_fragment(fm_val) {
    if (type(fm_val) != "object")
        return false;
    let tcp_val = fm_val.tcp != null ? fm_val.tcp : fm_val;
    let items = type(tcp_val) == "array" ? tcp_val : (type(tcp_val) == "object" ? [ tcp_val ] : []);
    for (let item in items) {
        if (type(item) == "object" && lc(as_string(item.type || "")) == "fragment")
            return true;
    }
    return false;
}

function add_tls(url, security, default_tls) {
    let query = object_or_empty(url.query);
    let sni = query.sni || query.peer || "";
    let insecure = query.allowInsecure || query.insecure || "";
    let transport = query.type || "";
    let raw_alpn = split_csv(query.alpn || "");
    let alpn = tls_alpn_for_transport(raw_alpn, transport);

    let fingerprint = normalize_utls_fingerprint(query.fp || "");
    let public_key = query.pbk || "";
    let short_id = query.sid || "";
    let certificate_pin = common.certificate_pin_base64(query.pcs || "");

    if (security == "reality" && public_key == "")
        return [null, false];
    if ((security == "reality" || public_key != "") && fingerprint == "")
        fingerprint = "chrome";

    let tls_enabled = false;
    let forced_tls_443 = false;
    if (security == "tls" || security == "xtls" || security == "reality")
        tls_enabled = true;
    else if (security == "none") {
        if (int(url.port) == 443) {
            tls_enabled = true;
            forced_tls_443 = true;
        }
    }
    else if (security == null || security == "")
        tls_enabled = default_tls || (int(url.port) == 443) || sni != "" || length(raw_alpn) > 0 || fingerprint != "" || public_key != "" || certificate_pin != "";

    if (!tls_enabled)
        return [null, true];

    let tls = { enabled: true };
    if (sni != "")
        tls.server_name = sni;
    else if (forced_tls_443 && url.host != "")
        tls.server_name = url.host;
    if (is_true(insecure) || forced_tls_443)
        tls.insecure = true;
    if (length(alpn) > 0)
        tls.alpn = alpn;
    if (fingerprint != "")
        tls.utls = { enabled: true, fingerprint: fingerprint };
    else if (forced_tls_443)
        tls.utls = { enabled: true, fingerprint: "chrome" };
    if (security == "reality" || public_key != "") {
        tls.reality = { enabled: true };
        if (public_key != "")
            tls.reality.public_key = public_key;
        if (short_id != "")
            tls.reality.short_id = short_id;
        // Three spellings of the same flag are in the wild: the sing-box
        // snake_case one, the camelCase one some panels emit, and the
        // kebab-case one a share link carries. Priority order is kept: the
        // first one that is present wins, and an explicit false is never
        // turned into true by a later spelling.
        let mlkem_preference = query.support_x25519mlkem768;
        if (mlkem_preference == null)
            mlkem_preference = query.supportX25519MLKEM768;
        if (mlkem_preference == null)
            mlkem_preference = query["support-x25519mlkem768"];
        if (mlkem_preference == null)
            mlkem_preference = query.pq;
        if (mlkem_preference == null)
            mlkem_preference = query.post_quantum;
        if (mlkem_preference == null) {
            let extra = xhttp_extra_settings(query);
            mlkem_preference = extra.support_x25519mlkem768;
            if (mlkem_preference == null)
                mlkem_preference = extra.supportX25519MLKEM768;
            if (mlkem_preference == null)
                mlkem_preference = extra["support-x25519mlkem768"];
            if (mlkem_preference == null && trim(as_string(extra.pqv || extra.mldsa65Verify || "")) != "")
                mlkem_preference = "true";
        }
        if (mlkem_preference == null && trim(as_string(query.pqv || query.mldsa65Verify || "")) != "")
            mlkem_preference = "true";
        if (mlkem_preference != null)
            tls.reality.support_x25519mlkem768 = is_true(mlkem_preference);
    }
    if (certificate_pin != "")
        tls.certificate_sha256 = [ certificate_pin ];
    let fm_raw = as_string(query.fm || query.finalmask || "");
    if (is_true(query.fragment || query.tls_fragment) ||
        (fm_raw != "" && finalmask_has_tcp_fragment(json_decode_text(fm_raw))))
        tls.fragment = true;

    return [tls, true];
}

function add_transport(url) {
    let query = object_or_empty(url.query);
    let transport = query.type || "";
    if (transport == "" || transport == "tcp")
        return null;

    let path = query.path || "";
    let host = query.host || "";
    let early_data = query.ed || "";
    let grpc_service_name = query.serviceName || query.service_name || "";
    let xhttp_mode = query.mode || "auto";
    let sni = query.sni || "";

    if (xhttp_mode != "auto" && xhttp_mode != "packet-up" && xhttp_mode != "stream-up" && xhttp_mode != "stream-one")
        xhttp_mode = "auto";

    if (transport == "ws") {
        let result = { type: "ws", path: path != "" ? path : "/" };
        if (host != "")
            result.headers = { Host: host };
        if (is_integer_string(early_data))
            result.max_early_data = int(early_data);
        return result;
    }
    if (transport == "grpc") {
        let result = { type: "grpc" };
        if (grpc_service_name != "")
            result.service_name = grpc_service_name;
        return result;
    }
    if (transport == "http" || transport == "h2") {
        let result = { type: "http" };
        if (path != "")
            result.path = path;
        if (host != "")
            result.host = split_csv(host);
        return result;
    }
    if (transport == "httpupgrade") {
        let result = { type: "httpupgrade" };
        if (path != "")
            result.path = path;
        if (host != "")
            result.host = host;
        return result;
    }
    if (transport == "xhttp") {
        if (path == "")
            path = "/";
        if (host == "")
            host = sni;
        let result = {
            type: "xhttp",
            mode: xhttp_mode,
            path: path,
            x_padding_bytes: "100-1000",
            no_grpc_header: false,
            sc_max_each_post_bytes: "1000000",
            sc_min_posts_interval_ms: "30"
        };
        if (host != "")
            result.host = host;

        let extra_settings = xhttp_extra_settings(query);
        xhttp_optional_positive_range(result, "x_padding_bytes", xhttp_setting_value(query, extra_settings, "xPaddingBytes", "x_padding_bytes"));
        xhttp_optional_bool(result, "no_grpc_header", xhttp_setting_value(query, extra_settings, "noGRPCHeader", "no_grpc_header"));
        xhttp_optional_positive_range(result, "sc_max_each_post_bytes", xhttp_setting_value(query, extra_settings, "scMaxEachPostBytes", "sc_max_each_post_bytes"));
        xhttp_optional_range(result, "sc_min_posts_interval_ms", xhttp_setting_value(query, extra_settings, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"));
        xhttp_optional_range(result, "sc_stream_up_server_secs", xhttp_setting_value(query, extra_settings, "scStreamUpServerSecs", "sc_stream_up_server_secs"));
        let xmux = xhttp_normalize_xmux(xhttp_setting_value(query, extra_settings, "xmux", "xmux"));
        if (xmux)
            result.xmux = xmux;
        xhttp_apply_v2_settings(result, query, extra_settings);
        return result;
    }

    return null;
}

function valid_port(port) {
    let port_type = type(port);
    return (port_type == "int" || port_type == "double") && port >= 1 && port <= 65535 && int(port) == port;
}

function normalize_port_number(value) {
    value = trim(as_string(value));
    if (!is_integer_string(value))
        return "";

    let port = int(value, 10);
    if (port < 1 || port > 65535)
        return "";

    return "" + port;
}

function parse_hysteria2_server_ports(value) {
    value = as_string(value);
    if (index(value, ",") < 0 && index(value, "-") < 0)
        return null;

    let result = [];
    for (let entry in split(value, ",")) {
        entry = trim(entry);
        if (entry == "")
            return null;

        let dash = index(entry, "-");
        if (dash >= 0) {
            if (index(substr(entry, dash + 1), "-") >= 0)
                return null;

            let start = normalize_port_number(substr(entry, 0, dash));
            let end = normalize_port_number(substr(entry, dash + 1));
            if (start == "" || end == "" || int(start, 10) > int(end, 10))
                return null;

            push(result, start + ":" + end);
        }
        else {
            let port = normalize_port_number(entry);
            if (port == "")
                return null;

            push(result, port + ":" + port);
        }
    }

    return length(result) > 0 ? result : null;
}

function normalize_vless_encryption(value) {
    value = as_string(value);
    return value != "" && value != "none" ? value : "";
}

function normalize_packet_encoding(value) {
    value = lc(trim(as_string(value)));
    return value == "xudp" || value == "packetaddr" ? value : "";
}

function normalize_vless_flow(value) {
    let flow = lc(trim(as_string(value)));
    if (flow == "" || flow == "none")
        return "";
    if (flow == "xtls-rprx-vision" || flow == "xtls-rprx-vision-udp443")
        return "xtls-rprx-vision";
    return null;
}

function process_vless(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let flow = normalize_vless_flow(url.query.flow || "");
    if (flow == null)
        return null;

    let packet_encoding = normalize_packet_encoding(url.query.packetEncoding || url.query.packet_encoding || url.query["packet-encoding"] || url.query.packetencoding || "");
    let encryption = normalize_vless_encryption(url.query.encryption || "");

    let outbound = {
        type: "vless",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        uuid: url.userinfo
    };
    if (encryption != "")
        outbound.encryption = encryption;
    if (flow != "")
        outbound.flow = flow;
    if (packet_encoding != "")
        outbound.packet_encoding = packet_encoding;

    let tls_result = add_tls(url, url.query.security || "", false);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];

    let transport = add_transport(url);
    if (transport) {
        if (outbound.tls == null && int(url.port) == 443 && transport.type == "xhttp" && type(transport.headers) == "object") {
            let origin = as_string(transport.headers.Origin || transport.headers.origin || "");
            if (starts_with(lc(origin), "https://")) {
                let sni = as_string(transport.host || url.host);
                let fp = lc(trim(as_string(transport.headers["User-Agent"] || transport.headers["user-agent"] || "")));
                if (fp != "chrome" && fp != "firefox" && fp != "safari" && fp != "edge" && fp != "ios" && fp != "android")
                    fp = "chrome";
                outbound.tls = {
                    enabled: true,
                    server_name: sni,
                    alpn: [ "h2", "http/1.1" ],
                    utls: {
                        enabled: true,
                        fingerprint: fp
                    }
                };
            }
        }
        outbound.transport = transport;
    }
    return outbound;
}

function process_trojan(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    if (url.scheme == "trojan-go" && (url.query.type == null || url.query.type == "") &&
        ((url.path || "") != "" || (url.query.path || "") != "" || (url.query.host || "") != "")) {
        url.query.type = "ws";
    }

    let outbound = {
        type: "trojan",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        password: url.userinfo
    };

    let tls_result = add_tls(url, url.query.security || "", true);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];

    let transport = add_transport(url);
    if (transport) {
        if (outbound.tls == null && int(url.port) == 443 && transport.type == "xhttp" && type(transport.headers) == "object") {
            let origin = as_string(transport.headers.Origin || transport.headers.origin || "");
            if (starts_with(lc(origin), "https://")) {
                let sni = as_string(transport.host || url.host);
                let fp = lc(trim(as_string(transport.headers["User-Agent"] || transport.headers["user-agent"] || "")));
                if (fp != "chrome" && fp != "firefox" && fp != "safari" && fp != "edge" && fp != "ios" && fp != "android")
                    fp = "chrome";
                outbound.tls = {
                    enabled: true,
                    server_name: sni,
                    alpn: [ "h2", "http/1.1" ],
                    utls: {
                        enabled: true,
                        fingerprint: fp
                    }
                };
            }
        }
        outbound.transport = transport;
    }
    return outbound;
}

function process_socks(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port))
        return null;

    let username = "", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = substr(url.userinfo, 0, colon);
            password = substr(url.userinfo, colon + 1);
            if (username == password)
                password = "";
        }
        else {
            username = url.userinfo;
        }
    }

    let outbound = {
        type: "socks",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port
    };
    let version = substr(url.scheme, 5);
    if (version != "")
        outbound.version = version;
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;
    return outbound;
}

function process_http(raw, url) {
    let port = url.port;
    if (port == null || port == "")
        port = url.scheme == "https" ? 443 : 80;
    if (url.host == "" || is_dummy_server(url.host, port) || !valid_port(port))
        return null;

    let username = "", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = substr(url.userinfo, 0, colon);
            password = substr(url.userinfo, colon + 1);
            if (username == password)
                password = "";
        }
        else {
            username = url.userinfo;
        }
    }

    let outbound = {
        type: "http",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + port),
        share_link: raw,
        server: url.host,
        server_port: int(port)
    };
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;

    if (url.scheme == "https") {
        let tls = { enabled: true };
        if ((url.query.sni || "") != "")
            tls.server_name = url.query.sni;
        if (is_true(url.query.allowInsecure || url.query.insecure))
            tls.insecure = true;
        let certificate_pin = common.certificate_pin_base64(url.query.pcs || "");
        if (certificate_pin != "")
            tls.certificate_sha256 = [ certificate_pin ];
        outbound.tls = tls;
    }
    return outbound;
}

const SHADOWSOCKS_METHODS = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
    "aes-128-gcm": 0,
    "aes-192-gcm": 0,
    "aes-256-gcm": 0,
    "chacha20-ietf-poly1305": 0,
    "xchacha20-ietf-poly1305": 0,
    "none": 0,
    "aes-128-ctr": 0,
    "aes-192-ctr": 0,
    "aes-256-ctr": 0,
    "aes-128-cfb": 0,
    "aes-192-cfb": 0,
    "aes-256-cfb": 0,
    "rc4-md5": 0,
    "chacha20-ietf": 0,
    "xchacha20": 0
};

function normalize_shadowsocks_method(method) {
    let m = lc(trim(as_string(method)));
    if (m == "aead_aes_128_gcm") return "aes-128-gcm";
    if (m == "aead_aes_192_gcm") return "aes-192-gcm";
    if (m == "aead_aes_256_gcm") return "aes-256-gcm";
    if (m == "aead_chacha20_poly1305") return "chacha20-ietf-poly1305";
    if (m == "chacha20-poly1305") return "chacha20-ietf-poly1305";
    if (m == "xchacha20-poly1305") return "xchacha20-ietf-poly1305";
    if (m == "dummy" || m == "plain") return "none";
    return m;
}

function valid_shadowsocks_method(method) {
    return (normalize_shadowsocks_method(method) in SHADOWSOCKS_METHODS);
}

function valid_shadowsocks_password(method, password) {
    let m = normalize_shadowsocks_method(method);
    if (!(m in SHADOWSOCKS_METHODS))
        return false;
    if (m == "none")
        return true;
    if (password == "")
        return false;
    let req_len = SHADOWSOCKS_METHODS[m];
    if (req_len <= 0)
        return true;
    let parts = split(password, ":");
    if (m == "2022-blake3-chacha20-poly1305" && length(parts) > 1)
        return false;
    for (let i = 0; i < length(parts); i++) {
        let part = parts[i];
        if (part == "" || (length(part) % 4) != 0 || !match(part, /^[A-Za-z0-9+\/]+=*$/))
            return false;
        let decoded = b64dec(part);
        if (decoded == null || length(decoded) != req_len)
            return false;
    }
    return true;
}

function is_shadowsocks_userinfo_format(value) {
    if (type(value) != "string")
        return false;
    let first = index(value, ":");
    if (first <= 0)
        return false;
    let method = substr(value, 0, first);
    if (valid_shadowsocks_method(method))
        return true;
    if (first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function process_shadowsocks(raw) {
    if (!starts_with(raw, "ss://"))
        return null;

    let body = substr(raw, 5);
    let fragment = "";
    let hash_pos = index(body, "#");
    if (hash_pos >= 0) {
        fragment = urldecode(substr(body, hash_pos + 1));
        body = substr(body, 0, hash_pos);
    }

    let query = "";
    let question_pos = index(body, "?");
    if (question_pos >= 0) {
        query = substr(body, question_pos + 1);
        body = substr(body, 0, question_pos);
    }

    let userinfo, hostport;
    let at_pos = rindex(body, "@");
    if (at_pos >= 0) {
        userinfo = substr(body, 0, at_pos);
        hostport = substr(body, at_pos + 1);
    }
    else {
        let decoded = base64_decode(body);
        if (!decoded)
            return null;
        at_pos = rindex(decoded, "@");
        if (at_pos < 0)
            return null;
        userinfo = substr(decoded, 0, at_pos);
        hostport = substr(decoded, at_pos + 1);
    }

    userinfo = urldecode(userinfo);
    if (!is_shadowsocks_userinfo_format(userinfo)) {
        let decoded = base64_decode(userinfo);
        if (!decoded)
            return null;
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = parse_host_port(hostport);
    if (cred_colon <= 0)
        return null;
    let method = normalize_shadowsocks_method(substr(userinfo, 0, cred_colon));
    let password = substr(userinfo, cred_colon + 1);
    if (!valid_shadowsocks_password(method, password) || host_port[0] == "" || is_dummy_server(host_port[0], host_port[1]) || !valid_port(host_port[1]))
        return null;

    let params = parse_query(query);
    let plugin = params.plugin || "";
    let plugin_opts = params["plugin-opts"] || "";
    if (plugin != "" && plugin_opts == "") {
        let parsed_plugin = match(plugin, /^([^;]+);(.*)$/);
        if (parsed_plugin) {
            plugin = parsed_plugin[1];
            plugin_opts = parsed_plugin[2];
        }
    }

    let outbound = {
        type: "shadowsocks",
        tag: fragment != "" ? fragment : (host_port[0] + ":" + host_port[1]),
        share_link: raw,
        server: host_port[0],
        server_port: host_port[1],
        method: method,
        password: password
    };
    if (plugin != "")
        outbound.plugin = plugin;
    if (plugin_opts != "")
        outbound.plugin_opts = plugin_opts;
    if (is_true(params.uot || params.udp_over_tcp || params["udp-over-tcp"]))
        outbound.udp_over_tcp = true;
    return outbound;
}

function parse_hysteria2_packet_size_str(raw) {
    let s = trim(as_string(raw));
    if (s == "")
        return null;
    let dash = index(s, "-");
    if (dash >= 0) {
        let a = trim(substr(s, 0, dash));
        let b = trim(substr(s, dash + 1));
        if (!is_integer_string(a) || !is_integer_string(b))
            return null;
        let lo = int(a, 10);
        let hi = int(b, 10);
        return (hi > 0 && lo <= hi && hi <= 2048) ? [ lo, hi ] : null;
    }
    if (!is_integer_string(s))
        return null;
    let v = int(s, 10);
    return (v > 0 && v <= 2048) ? [ v, v ] : null;
}

function parse_hysteria2_packet_size_value(val) {
    if (val == null)
        return null;
    let vt = type(val);
    if (vt == "string")
        return parse_hysteria2_packet_size_str(val);
    if (vt == "int" || vt == "double") {
        let v = int(val);
        return (v == val && v > 0 && v <= 2048) ? [ v, v ] : null;
    }
    if (vt == "object") {
        let lo_raw = val.from != null ? val.from : val.min;
        let hi_raw = val.to != null ? val.to : val.max;
        let lo = xhttp_non_negative_integer_value(lo_raw);
        let hi = xhttp_positive_integer_value(hi_raw);
        return (lo != null && hi != null && lo <= hi && hi <= 2048) ? [ lo, hi ] : null;
    }
    return null;
}

function build_hysteria2_obfs(is_gecko, password, min_packet_size, max_packet_size) {
    password = as_string(password);
    let min_v = int(min_packet_size || 0);
    let max_v = int(max_packet_size || 0);
    if (is_gecko || min_v > 0 || max_v > 0) {
        let obfs = {
            type: "gecko",
            password: password
        };
        if (min_v > 0)
            obfs.min_packet_size = min_v;
        if (max_v > 0)
            obfs.max_packet_size = max_v;
        return obfs;
    }
    return {
        type: "salamander",
        password: password
    };
}

function parse_hysteria2_mbps(val) {
    if (val == null)
        return null;
    if (type(val) == "int" || type(val) == "double") {
        let n = int(val);
        return n > 0 ? n : null;
    }
    let m = match(trim(as_string(val)), /^([0-9]+)/);
    if (!m)
        return null;
    let n = int(m[1], 10);
    return n > 0 ? n : null;
}

function normalize_hysteria2_hop_interval(val) {
    if (val == null)
        return "";
    if (type(val) == "int" || type(val) == "double") {
        let n = int(val);
        return n > 0 ? ("" + n + "s") : "";
    }
    let s = trim(as_string(val));
    if (s == "")
        return "";
    let dash = index(s, "-");
    if (dash > 0)
        s = trim(substr(s, 0, dash));
    if (is_integer_string(s))
        return s + "s";
    return s;
}

function process_hysteria2(raw, url) {
    let mport = trim(as_string(url.query.mport || url.query.ports || url.query.server_ports || ""));
    let port_value = mport != "" ? mport : url.port;
    let server_ports = parse_hysteria2_server_ports(port_value);
    let server_port = normalize_port_number(as_string(port_value));
    if (url.host == "" || is_dummy_server(url.host, port_value) || (server_ports == null && server_port == "") || url.userinfo == "")
        return null;

    let password = url.userinfo;
    if (password == "")
        return null;

    let tls = { enabled: true };
    if ((url.query.sni || "") != "")
        tls.server_name = url.query.sni;
    if (is_true(url.query.allowInsecure || url.query.insecure))
        tls.insecure = true;
    if ((url.query.alpn || "") != "")
        tls.alpn = split_csv(url.query.alpn);
    let certificate_pin = common.certificate_pin_base64(url.query.pcs || url.query.pinSHA256 || "");
    if (certificate_pin != "")
        tls.certificate_sha256 = [ certificate_pin ];

    let outbound = {
        type: "hysteria2",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + as_string(port_value)),
        share_link: raw,
        server: url.host,
        password: password,
        tls: tls
    };
    if (server_ports != null) {
        outbound.server_ports = server_ports;
        let parts = split(server_ports[0], ":");
        let initial_port = normalize_port_number(url.port);
        outbound.server_port = initial_port != "" ? int(initial_port, 10) : int(parts[0], 10);
    }
    else {
        outbound.server_port = int(server_port, 10);
    }

    if ((url.query.network || "") != "")
        outbound.network = url.query.network;
    let up_mbps = parse_hysteria2_mbps(url.query.upmbps != null ? url.query.upmbps : (url.query.up_mbps != null ? url.query.up_mbps : url.query.up));
    if (up_mbps != null)
        outbound.up_mbps = up_mbps;
    let down_mbps = parse_hysteria2_mbps(url.query.downmbps != null ? url.query.downmbps : (url.query.down_mbps != null ? url.query.down_mbps : url.query.down));
    if (down_mbps != null)
        outbound.down_mbps = down_mbps;

    let obfs_pw = "";
    let has_obfs = false;
    let is_gecko = false;
    let min_ps = 0;
    let max_ps = 0;
    let obfs_type = lc(trim(as_string(url.query.obfs || url.query.obfs_type || url.query["obfs-type"] || "")));
    if (obfs_type != "" && obfs_type != "none") {
        has_obfs = true;
        if (obfs_type == "gecko")
            is_gecko = true;
        obfs_pw = as_string(url.query["obfs-password"] || url.query.obfs_password || url.query.obfspassword || "");
    }
    let ps_raw = url.query.packetSize != null ? url.query.packetSize : (url.query.packetsize != null ? url.query.packetsize : (url.query["packet-size"] != null ? url.query["packet-size"] : url.query.packet_size));
    let ps_pair = parse_hysteria2_packet_size_value(ps_raw);
    if (ps_pair != null) {
        min_ps = ps_pair[0];
        max_ps = ps_pair[1];
    }
    let lo_q = xhttp_positive_integer_value(url.query.min_packet_size != null ? url.query.min_packet_size : (url.query["min-packet-size"] != null ? url.query["min-packet-size"] : (url.query.minPacketSize != null ? url.query.minPacketSize : url.query.minpacketsize)));
    if (lo_q != null)
        min_ps = lo_q;
    let hi_q = xhttp_positive_integer_value(url.query.max_packet_size != null ? url.query.max_packet_size : (url.query["max-packet-size"] != null ? url.query["max-packet-size"] : (url.query.maxPacketSize != null ? url.query.maxPacketSize : url.query.maxpacketsize)));
    if (hi_q != null)
        max_ps = hi_q;

    let fm_raw = as_string(url.query.fm || url.query.finalmask || "");
    if (fm_raw != "") {
        let fm_val = json_decode_text(fm_raw);
        if (type(fm_val) == "object") {
            let has_udp_key = fm_val.udp != null;
            let udp_val = has_udp_key ? fm_val.udp : fm_val;
            let udp_items = type(udp_val) == "array" ? udp_val : (type(udp_val) == "object" ? [ udp_val ] : []);
            for (let u_obj in udp_items) {
                if (type(u_obj) != "object")
                    continue;
                // A bare finalmask object without "udp" or "type" (e.g. {"quicParams":{...}})
                // carries no obfuscation; defaulting it to salamander yields an obfs without password.
                let utype = lc(as_string(u_obj.type || (has_udp_key ? "salamander" : "")));
                let u_set = object_or_empty(u_obj.settings);
                if (utype == "salamander" || utype == "gecko") {
                    has_obfs = true;
                    if (utype == "gecko" || lc(as_string(u_set.mode || u_obj.mode || "")) == "gecko")
                        is_gecko = true;
                    let pw = as_string(u_set.password || u_obj.password || "");
                    if (pw != "")
                        obfs_pw = pw;
                    let fm_ps = parse_hysteria2_packet_size_value(u_set.packetSize != null ? u_set.packetSize : (u_set.packet_size != null ? u_set.packet_size : (u_obj.packetSize != null ? u_obj.packetSize : u_obj.packet_size)));
                    if (fm_ps != null) {
                        min_ps = fm_ps[0];
                        max_ps = fm_ps[1];
                    }
                    let fm_lo = xhttp_positive_integer_value(u_set.minPacketSize != null ? u_set.minPacketSize : (u_set.min_packet_size != null ? u_set.min_packet_size : (u_obj.minPacketSize != null ? u_obj.minPacketSize : u_obj.min_packet_size)));
                    if (fm_lo != null)
                        min_ps = fm_lo;
                    let fm_hi = xhttp_positive_integer_value(u_set.maxPacketSize != null ? u_set.maxPacketSize : (u_set.max_packet_size != null ? u_set.max_packet_size : (u_obj.maxPacketSize != null ? u_obj.maxPacketSize : u_obj.max_packet_size)));
                    if (fm_hi != null)
                        max_ps = fm_hi;
                } else if (utype == "udphop" || utype == "udp_hop") {
                    let hop_ports = parse_hysteria2_server_ports(as_string(u_set.ports || u_set.port || u_obj.ports || u_obj.port || ""));
                    if (hop_ports != null)
                        outbound.server_ports = hop_ports;
                    let hop_iv = normalize_hysteria2_hop_interval(u_set.interval != null ? u_set.interval : u_obj.interval);
                    if (hop_iv != "")
                        outbound.hop_interval = hop_iv;
                }
            }
        }
    }

    if (has_obfs) {
        if (is_gecko || min_ps > 0 || max_ps > 0) {
            outbound.obfs = build_hysteria2_obfs(true, obfs_pw, min_ps, max_ps);
        } else {
            outbound.obfs = { type: obfs_type != "" ? obfs_type : "salamander" };
            if (obfs_pw != "")
                outbound.obfs.password = obfs_pw;
        }
    }

    let hop_q = normalize_hysteria2_hop_interval(url.query.hop_interval != null ? url.query.hop_interval : (url.query["hop-interval"] != null ? url.query["hop-interval"] : (url.query.hopinterval != null ? url.query.hopinterval : (url.query.mporthopint != null ? url.query.mporthopint : url.query.mport_hop))));
    if (hop_q != "")
        outbound.hop_interval = hop_q;

    return outbound;
}

function process_tuic(raw, url) {
    let userinfo = as_string(url.userinfo || "");
    if (userinfo == "" || url.host == "" || is_dummy_server(url.host, url.port) || url.port == "")
        return null;

    let uuid = "";
    let password = "";
    let colon_index = index(userinfo, ":");
    if (colon_index >= 0) {
        uuid = substr(userinfo, 0, colon_index);
        password = substr(userinfo, colon_index + 1);
    } else {
        uuid = userinfo;
    }

    if (uuid == "")
        return null;

    let tls = { enabled: true };
    if ((url.query.sni || "") != "")
        tls.server_name = url.query.sni;
    if (is_true(url.query.allowInsecure || url.query.insecure))
        tls.insecure = true;
    if ((url.query.alpn || "") != "")
        tls.alpn = split_csv(url.query.alpn);
    let certificate_pin = common.certificate_pin_base64(url.query.pcs || url.query.pinSHA256 || "");
    if (certificate_pin != "")
        tls.certificate_sha256 = [ certificate_pin ];

    let outbound = {
        type: "tuic",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port),
        uuid: uuid,
        tls: tls
    };

    if (password != "")
        outbound.password = password;

    let cc = as_string(url.query.congestion_control || "");
    if (cc != "")
        outbound.congestion_control = cc;
    else
        outbound.congestion_control = "bbr";

    let udp_mode = as_string(url.query.udp_relay_mode || "");
    if (udp_mode != "")
        outbound.udp_relay_mode = udp_mode;

    if (is_true(url.query.zero_rtt_handshake))
        outbound.zero_rtt_handshake = true;

    let heartbeat = as_string(url.query.heartbeat || "");
    if (heartbeat != "")
        outbound.heartbeat = heartbeat;

    return outbound;
}

function string_value(value) {
    return value == null ? "" : as_string(value);
}

function process_vmess_json(raw, decoded, frag_override) {
    let vmess = json_decode_text(decoded);
    if (type(vmess) != "object")
        return null;

    let server = string_value(vmess.add);
    let port = int(vmess.port || 0);
    let uuid = string_value(vmess.id);
    if (server == "" || is_dummy_server(server, port) || !valid_port(port) || uuid == "")
        return null;

    let tag = trim(as_string(frag_override || ""));
    if (tag == "")
        tag = string_value(vmess.ps) != "" ? string_value(vmess.ps) : (server + ":" + port);

    let outbound = {
        type: "vmess",
        tag: tag,
        share_link: raw,
        server: server,
        server_port: port,
        uuid: uuid,
        security: string_value(vmess.scy) != "" ? string_value(vmess.scy) : "auto"
    };

    let alter_id = int(vmess.aid || 0);
    if (as_string(vmess.aid) != "")
        outbound.alter_id = alter_id;

    let packet_encoding = normalize_packet_encoding(vmess.packetEncoding || vmess["packet-encoding"] || vmess.packet_encoding || vmess.packetencoding || "");
    if (packet_encoding != "")
        outbound.packet_encoding = packet_encoding;

    let network = string_value(vmess.net);
    if (vmess.tls == true || vmess.tls == "tls" || vmess.tls == "true" || vmess.tls == "1") {
        let fingerprint = normalize_utls_fingerprint(string_value(vmess.fp));
        let tls = { enabled: true };
        if (string_value(vmess.sni) != "")
            tls.server_name = string_value(vmess.sni);
        if (is_true(vmess.allowInsecure || vmess.insecure))
            tls.insecure = true;
        let certificate_pin = common.certificate_pin_base64(string_value(vmess.pcs));
        if (certificate_pin != "")
            tls.certificate_sha256 = [ certificate_pin ];
        let alpn = tls_alpn_for_transport(split_csv(string_value(vmess.alpn)), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (fingerprint != "")
            tls.utls = { enabled: true, fingerprint: fingerprint };
        outbound.tls = tls;
    }

    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: string_value(vmess.path) != "" ? string_value(vmess.path) : "/"
        };
        if (string_value(vmess.host) != "")
            outbound.transport.headers = { Host: string_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        if (string_value(vmess.path) != "")
            outbound.transport.service_name = string_value(vmess.path);
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        if (string_value(vmess.path) != "")
            outbound.transport.path = string_value(vmess.path);
        if (string_value(vmess.host) != "")
            outbound.transport.host = split_csv(string_value(vmess.host));
    }

    return outbound;
}

function process_vmess_url(raw) {
    let url = parse_url(raw);
    if (url == null || url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let uuid = url.userinfo;
    let security = "";
    let colon = index(url.userinfo, ":");
    if (colon > 0) {
        security = substr(url.userinfo, 0, colon);
        uuid = substr(url.userinfo, colon + 1);
    }
    if (security == "") {
        let q_enc = trim(as_string(url.query.encryption || url.query.scy || ""));
        if (q_enc == "") {
            let q_sec = lc(trim(as_string(url.query.security || "")));
            if (q_sec != "" && q_sec != "tls" && q_sec != "reality" && q_sec != "xtls")
                q_enc = q_sec;
        }
        security = q_enc != "" ? q_enc : "auto";
    }

    let outbound = {
        type: "vmess",
        tag: url.fragment != "" ? url.fragment : ("vmess-" + url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port),
        uuid: uuid,
        security: security
    };

    let aid = int(url.query.alterId || url.query.aid || 0);
    if (aid > 0)
        outbound.alter_id = aid;

    let packet_encoding = normalize_packet_encoding(url.query.packetEncoding || url.query.packet_encoding || url.query["packet-encoding"] || url.query.packetencoding || "");
    if (packet_encoding != "")
        outbound.packet_encoding = packet_encoding;

    let tls_result = add_tls(url, url.query.security || "", false);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];

    let transport = add_transport(url);
    if (transport)
        outbound.transport = transport;

    return outbound;
}

function process_vmess(raw) {
    if (!starts_with(raw, "vmess://"))
        return null;

    let encoded = substr(raw, 8);
    let frag_override = "";
    let hash_pos = index(encoded, "#");
    if (hash_pos >= 0) {
        frag_override = urldecode_fragment(substr(encoded, hash_pos + 1));
        encoded = substr(encoded, 0, hash_pos);
    }
    if (index(encoded, "@") >= 0)
        return process_vmess_url(raw);

    let decoded = base64_decode(encoded);
    if (!decoded)
        return null;
    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    let trimmed = trim(decoded);
    if (substr(trimmed, 0, 1) != "{" || substr(trimmed, length(trimmed) - 1) != "}")
        return null;
    return process_vmess_json(raw, trimmed, frag_override);
}

function from_amneziawg_share_link(line) {
    line = trim(line);
    let hash_pos = index(line, "#");
    let link_part = hash_pos >= 0 ? substr(line, 0, hash_pos) : line;
    let name = hash_pos >= 0 ? urldecode_fragment(substr(line, hash_pos + 1)) : "";

    let scheme_marker = index(link_part, "://");
    if (scheme_marker < 0)
        return null;
    let payload = substr(link_part, scheme_marker + 3);
    if (payload == "")
        return null;

    if (index(payload, "?") >= 0 && index(payload, "@") >= 0) {
        let u = parse_url(line);
        if (u != null && u.host != "" && u.port != "" && !is_dummy_server(u.host, u.port)) {
            let priv_k = trim(as_string(u.userinfo || u.query.privatekey || u.query.private_key || u.query.privateKey || ""));
            let pub_k = trim(as_string(u.query.publickey || u.query.public_key || u.query.publicKey || u.query.peer_public_key || ""));
            if (priv_k != "" && pub_k != "") {
                let addr_v = trim(as_string(u.query.address || u.query.ip || "10.0.0.2/32"));
                let ep_host = index(u.host, ":") >= 0 && substr(u.host, 0, 1) != "[" ? ("[" + u.host + "]") : u.host;
                let synth = "[Interface]\nPrivateKey = " + priv_k + "\nAddress = " + addr_v + "\n";
                if ((u.query.mtu || "") != "")
                    synth += "MTU = " + as_string(u.query.mtu) + "\n";
                for (let ak in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5" ]) {
                    let av = u.query[ak] != null ? u.query[ak] : u.query[uc(ak)];
                    if (av != null && as_string(av) != "")
                        synth += uc(ak) + " = " + as_string(av) + "\n";
                }
                synth += "\n[Peer]\nPublicKey = " + pub_k + "\nEndpoint = " + ep_host + ":" + as_string(u.port) + "\n";
                let psk_v = trim(as_string(u.query.psk || u.query.presharedkey || u.query.pre_shared_key || ""));
                if (psk_v != "")
                    synth += "PresharedKey = " + psk_v + "\n";
                synth += "AllowedIPs = 0.0.0.0/0, ::/0\n";
                let ep_out = wireguard.from_conf(synth, line, name);
                if (ep_out)
                    return ep_out;
            }
        }
    }

    let conf_text = base64_decode(payload);
    if (conf_text == null || conf_text == "") {
        if (index(payload, "[Interface]") >= 0 || index(payload, "[interface]") >= 0)
            conf_text = payload;
        else
            return null;
    }

    let endpoint = wireguard.from_conf(conf_text, line, name);
    if (endpoint)
        return endpoint;

    try {
        let amnezia = require("subscription.amnezia");
        let decoded = amnezia.decode(conf_text);
        if (decoded && decoded.text)
            return wireguard.from_conf(decoded.text, line, name || decoded.name);
    } catch (e) {}

    return null;
}

function process_anytls(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let outbound = {
        type: "anytls",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        password: url.userinfo
    };

    if (is_integer_string(url.query.min_idle_session || ""))
        outbound.min_idle_session = int(url.query.min_idle_session, 10);
    if ((url.query.idle_session_check_interval || "") != "")
        outbound.idle_session_check_interval = url.query.idle_session_check_interval;
    if ((url.query.idle_session_timeout || "") != "")
        outbound.idle_session_timeout = url.query.idle_session_timeout;

    let tls_result = add_tls(url, url.query.security || "", true);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

function process_naive(raw, url) {
    let port = url.port;
    if (port == null || port == "")
        port = 443;
    if (url.host == "" || is_dummy_server(url.host, port) || !valid_port(port))
        return null;

    let username = "", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = substr(url.userinfo, 0, colon);
            password = substr(url.userinfo, colon + 1);
        } else {
            username = url.userinfo;
        }
    }

    let outbound = {
        type: "naive",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + port),
        share_link: raw,
        server: url.host,
        server_port: int(port)
    };
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;
    if (url.scheme == "naive+quic" || url.scheme == "naive+h3" || is_true(url.query.quic))
        outbound.quic = true;
    if ((url.query.quic_congestion_control || "") != "")
        outbound.quic_congestion_control = url.query.quic_congestion_control;
    if (is_integer_string(url.query.insecure_concurrency || ""))
        outbound.insecure_concurrency = int(url.query.insecure_concurrency, 10);
    if (is_true(url.query.uot || url.query.udp_over_tcp))
        outbound.udp_over_tcp = true;

    let tls = { enabled: true };
    if ((url.query.sni || "") != "")
        tls.server_name = url.query.sni;
    let certificate_pin = common.certificate_pin_base64(url.query.pcs || url.query.pinSHA256 || "");
    if (certificate_pin != "")
        tls.certificate_sha256 = [ certificate_pin ];
    outbound.tls = tls;
    return outbound;
}

function process_snell(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let version = int(url.query.version || url.query.v || 5);
    if (version < 1 || version > 6)
        version = 5;

    let outbound = {
        type: "snell",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        psk: url.userinfo,
        version: version
    };
    let obfs = lc(trim(as_string(url.query.obfs || url.query.plugin || "")));
    if (obfs == "http" || obfs == "tls") {
        outbound.obfs = { mode: obfs };
        if ((url.query["obfs-host"] || url.query.obfs_host || url.query.host || "") != "")
            outbound.obfs.host = url.query["obfs-host"] || url.query.obfs_host || url.query.host;
    }
    if (is_true(url.query.uot || url.query.udp_over_tcp))
        outbound.udp_over_tcp = true;
    if (is_true(url.query.reuse))
        outbound.reuse = true;
    return outbound;
}

function process_mieru(raw, url) {
    let port_val = url.port;
    let port_ranges = [];
    let raw_query_port = trim(as_string(url.query.port || ""));
    if (!valid_port(port_val) && raw_query_port != "") {
        let single_q = parse_port_value(raw_query_port);
        if (valid_port(single_q)) {
            port_val = single_q;
        } else {
            for (let token in split(replace(raw_query_port, /[,\s]+/g, " "), " ")) {
                token = trim(replace(token, ":", "-"));
                let m = match(token, /^([0-9]+)-([0-9]+)$/);
                if (m != null) {
                    let lo = int(m[1]), hi = int(m[2]);
                    if (lo >= 1 && hi <= 65535 && lo <= hi)
                        push(port_ranges, sprintf("%d-%d", lo, hi));
                } else if (valid_port(token)) {
                    push(port_ranges, as_string(int(token)));
                }
            }
        }
    }
    if (url.host == "" || url.userinfo == "")
        return null;
    if (length(port_ranges) == 0 && (is_dummy_server(url.host, port_val) || !valid_port(port_val)))
        return null;
    if (length(port_ranges) > 0 && is_dummy_server(url.host, 443))
        return null;

    let username = "", password = "";
    let colon = index(url.userinfo, ":");
    if (colon >= 0) {
        username = substr(url.userinfo, 0, colon);
        password = substr(url.userinfo, colon + 1);
    } else {
        username = url.userinfo;
    }
    if (username == "" || password == "")
        return null;

    let transport = uc(trim(as_string(url.query.protocol || url.query.transport || "TCP")));
    if (transport != "UDP")
        transport = "TCP";

    let display_port = length(port_ranges) > 0 ? port_ranges[0] : as_string(port_val);
    let tag_val = url.fragment != "" ? url.fragment : (url.query.profile || (url.host + ":" + display_port));
    let outbound = {
        type: "mieru",
        tag: tag_val,
        share_link: raw,
        server: url.host,
        username: username,
        password: password,
        transport: transport
    };
    if (length(port_ranges) > 0)
        outbound.server_ports = port_ranges;
    else
        outbound.server_port = int(port_val);
    if ((url.query.multiplexing || "") != "")
        outbound.multiplexing = url.query.multiplexing;
    return outbound;
}

function process_mtproto(raw, url) {
    let server = url.host;
    let port = url.port;
    let secret = url.userinfo;
    if (url.scheme == "tg" || url.scheme == "http" || url.scheme == "https") {
        server = as_string(url.query.server || "");
        port = parse_port_value(url.query.port || "");
        secret = as_string(url.query.secret || "");
    } else {
        if (secret == "")
            secret = as_string(url.query.secret || "");
    }
    if (server == "" || is_dummy_server(server, port) || !valid_port(port) || secret == "")
        return null;

    let norm_secret = lc(trim(as_string(secret)));
    let padded_prefix = false;
    let faketls_sni = "";
    if (length(norm_secret) >= 34 && match(norm_secret, /^(ee|dd)[0-9a-f]{32}/)) {
        padded_prefix = substr(norm_secret, 0, 2) == "dd";
        if (substr(norm_secret, 0, 2) == "ee" && length(norm_secret) > 34 && ((length(norm_secret) - 34) % 2) == 0) {
            let dhex = substr(norm_secret, 34);
            if (match(dhex, /^[0-9a-f]+$/)) {
                let dstr = "";
                for (let i = 0; i < length(dhex); i += 2) {
                    let b = int(substr(dhex, i, 2), 16);
                    if (b >= 32 && b < 127)
                        dstr += chr(b);
                }
                if (trim(dstr) != "")
                    faketls_sni = trim(dstr);
            }
        }
        secret = substr(norm_secret, 2, 32);
    } else if (length(norm_secret) == 32 && match(norm_secret, /^[0-9a-f]{32}$/)) {
        secret = norm_secret;
    }

    let outbound = {
        type: "mtproto",
        tag: url.fragment != "" ? url.fragment : (server + ":" + port),
        share_link: raw,
        server: server,
        server_port: int(port),
        secret: secret
    };
    let transport = lc(trim(as_string(url.query.transport || "")));
    if (transport == "abridged" || transport == "intermediate" || transport == "padded_intermediate" || transport == "full")
        outbound.transport = transport;
    else if (padded_prefix)
        outbound.transport = "padded_intermediate";
    let mode = lc(trim(as_string(url.query.mode || "")));
    if (mode == "mtproto" || mode == "mtproxy")
        outbound.mode = mode;
    let sni_val = as_string(url.query.sni || url.query.faketls || faketls_sni);
    if (sni_val != "")
        outbound.tls = { enabled: true, server_name: sni_val };
    return outbound;
}

function process_shadowtls(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let version = int(url.query.version || 3);
    if (version < 1 || version > 3)
        version = 3;

    let outbound = {
        type: "shadowtls",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port),
        version: version,
        password: url.userinfo
    };
    let tls_result = add_tls(url, url.query.security || "", true);
    if (tls_result[0])
        outbound.tls = tls_result[0];
    else
        outbound.tls = { enabled: true, server_name: url.query.sni || url.host };
    return outbound;
}

function process_tewfai(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port) || url.userinfo == "")
        return null;

    let uuid = "";
    let password = "";
    let colon = index(url.userinfo, ":");
    if (colon >= 0) {
        uuid = substr(url.userinfo, 0, colon);
        password = substr(url.userinfo, colon + 1);
    } else {
        uuid = url.userinfo;
    }
    if (uuid == "")
        return null;

    let outbound = {
        type: "tewfai",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port),
        uuid: uuid
    };
    if (password != "")
        outbound.password = password;
    if ((url.query.transport || "") != "") {
        let tr_list = [];
        for (let item in split_csv(url.query.transport)) {
            item = lc(trim(as_string(item)));
            if (item == "raw_tls" || item == "h2" || item == "ws") item = "tcp";
            else if (item == "h3_stream" || item == "h3_datagram") item = "quic";
            if (item == "tcp" || item == "quic") {
                if (index(tr_list, item) < 0)
                    push(tr_list, item);
            }
        }
        if (length(tr_list) > 0)
            outbound.transport = tr_list;
    }
    let cipher = as_string(url.query.inner_cipher || "");
    if (cipher == "aes-256-gcm" || cipher == "none" || cipher == "null")
        outbound.inner_cipher = cipher;
    let morph = as_string(url.query.morph_profile || "");
    if (morph == "auto" || morph == "adaptive" || morph == "transformer" ||
        morph == "browsing" || morph == "video" || morph == "webrtc" || morph == "bulk")
        outbound.morph_profile = morph;
    if (is_true(url.query.pqc))
        outbound.pqc = true;
    let rot_s = int(url.query.rotate_secs || 0);
    let rot_mb = int(url.query.rotate_mb || 0);
    if (is_true(url.query.handover) || rot_s > 0 || rot_mb > 0) {
        let ho = { enabled: true };
        if (rot_s > 0) ho.rotate_secs = rot_s;
        if (rot_mb > 0) ho.rotate_mb = rot_mb;
        outbound.handover = ho;
    }
    if (is_true(url.query.fec))
        outbound.fec = true;
    if (is_true(url.query.desync))
        outbound.desync = true;
    if (is_true(url.query.shaper)) {
        let sp = as_string(url.query.shaper_profile || "adaptive");
        let mode = (sp == "fixed" || sp == "off") ? sp : "adaptive";
        outbound.shaper = { mode };
    }
    let mtu = int(url.query.mtu || 0);
    if (mtu >= 256)
        outbound.mtu = mtu;

    let tls_result = add_tls(url, url.query.security || "", true);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

function process_trusttunnel(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port))
        return null;

    let username = "", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = substr(url.userinfo, 0, colon);
            password = substr(url.userinfo, colon + 1);
        } else {
            password = url.userinfo;
        }
    }

    let outbound = {
        type: "trusttunnel",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port)
    };
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;
    if (is_true(url.query.quic))
        outbound.quic = true;
    if ((url.query.quic_congestion_control || url.query.cc || "") != "")
        outbound.quic_congestion_control = url.query.quic_congestion_control || url.query.cc;

    let tls_result = add_tls(url, url.query.security || "", true);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

function process_masque(raw, url) {
    let port = url.port;
    if (port == null || port == "")
        port = 443;
    if (url.host == "" || is_dummy_server(url.host, port) || !valid_port(port))
        return null;

    let outbound = {
        type: "masque",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + port),
        share_link: raw,
        server: url.host,
        server_port: int(port)
    };
    if ((url.query.profile || "") != "")
        outbound.profile = url.query.profile;
    if ((url.query.vhttp || "") != "")
        outbound.vhttp = url.query.vhttp;
    if ((url.query.private_key || "") != "") {
        outbound.private_key = url.query.private_key;
    } else if ((url.userinfo || "") != "" && index(url.userinfo, ":") < 0) {
        outbound.private_key = url.userinfo;
    }
    if ((url.query.public_key || "") != "")
        outbound.public_key = url.query.public_key;
    if (outbound.profile == null) {
        outbound.profile = (outbound.private_key != null && outbound.public_key != null) ? "cloudflare" : "standard";
    }
    if ((url.query.ip || "") != "")
        outbound.ip = url.query.ip;
    if ((url.query.ipv6 || "") != "")
        outbound.ipv6 = url.query.ipv6;
    if ((url.query.uri || "") != "")
        outbound.uri = url.query.uri;
    else if (outbound.profile == "standard")
        outbound.uri = "https://" + (index(url.host, ":") >= 0 ? "[" + url.host + "]" : url.host) + ":" + int(port) + "/.well-known/masque/ip/*/*/";
    if (is_integer_string(url.query.mtu || ""))
        outbound.mtu = int(url.query.mtu, 10);

    let tls_result = add_tls(url, url.query.security || "", true);
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

function process_openconnect(raw, url) {
    let port = url.port;
    if (port == null || port == "")
        port = 443;
    if (url.host == "" || is_dummy_server(url.host, port) || !valid_port(port))
        return null;

    let username = "", password = "", cookie = as_string(url.query.cookie || "");
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = substr(url.userinfo, 0, colon);
            password = substr(url.userinfo, colon + 1);
        } else if (cookie == "") {
            cookie = url.userinfo;
        } else {
            username = url.userinfo;
        }
    }

    let outbound = {
        type: "openconnect",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + port),
        share_link: raw,
        server: url.host,
        server_port: int(port),
        flavor: as_string(url.query.flavor || "anyconnect")
    };
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;
    if (cookie != "")
        outbound.cookie = cookie;
    if ((url.query.urlpath || "") != "")
        outbound.urlpath = url.query.urlpath;
    if ((url.query.realm || "") != "")
        outbound.realm = url.query.realm;
    if ((url.query.region || "") != "")
        outbound.region = url.query.region;
    if ((url.query.user_agent || "") != "")
        outbound.user_agent = url.query.user_agent;
    if ((url.query.local_hostname || "") != "")
        outbound.local_hostname = url.query.local_hostname;
    if ((url.query.server_cert_pin || "") != "")
        outbound.server_cert_pin = url.query.server_cert_pin;
    if ((url.query.address || "") != "")
        outbound.address = split(as_string(url.query.address), "/")[0];
    if ((url.query.address_v6 || "") != "")
        outbound.address_v6 = split(as_string(url.query.address_v6), "/")[0];
    if (is_true(url.query.ip))
        outbound.ip = true;
    if (is_true(url.query.esp))
        outbound.esp = true;
    if (is_true(url.query.dtls))
        outbound.dtls = true;
    if (is_true(url.query.hip_report))
        outbound.hip_report = true;
    if (is_integer_string(url.query.mtu || ""))
        outbound.mtu = as_string(url.query.mtu);

    let tls_result = add_tls(url, url.query.security || "", true);
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

function process_sudoku(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port))
        return null;
    let key = as_string(url.userinfo || url.query.key || url.query.password || "");
    if (key == "")
        return null;

    let outbound = {
        type: "sudoku",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port),
        key: key
    };
    let aead = as_string(url.query.aead || url.query.cipher || url.query.method || "");
    if (aead != "")
        outbound.aead_method = aead;
    if (is_integer_string(url.query.padding_min || ""))
        outbound.padding_min = int(url.query.padding_min, 10);
    if (is_integer_string(url.query.padding_max || ""))
        outbound.padding_max = int(url.query.padding_max, 10);
    let table_type = as_string(url.query.table_type || url.query.ascii || "");
    if (table_type != "")
        outbound.table_type = table_type;
    if (url.query.enable_pure_downlink != null && url.query.enable_pure_downlink != "")
        outbound.enable_pure_downlink = is_true(url.query.enable_pure_downlink);
    if (url.query.http_mask != null && url.query.http_mask != "")
        outbound.disable_http_mask = !is_true(url.query.http_mask);
    else if (url.query.disable_http_mask != null && url.query.disable_http_mask != "")
        outbound.disable_http_mask = is_true(url.query.disable_http_mask);
    if ((url.query.http_mask_mode || "") != "")
        outbound.http_mask_mode = url.query.http_mask_mode;
    if ((url.query.http_mask_host || url.query.host || "") != "")
        outbound.http_mask_host = url.query.http_mask_host || url.query.host;
    if ((url.query.path_root || url.query.http_mask_path_root || "") != "")
        outbound.path_root = url.query.path_root || url.query.http_mask_path_root;
    if (url.query.http_mask_tls != null && url.query.http_mask_tls != "")
        outbound.http_mask_tls = is_true(url.query.http_mask_tls);
    if ((url.query.http_mask_multiplex || url.query.mux || "") != "")
        outbound.http_mask_multiplex = url.query.http_mask_multiplex || url.query.mux;
    return outbound;
}

function process_ssh(raw, url) {
    let port = url.port;
    if (port == null || port == "")
        port = 22;
    if (url.host == "" || is_dummy_server(url.host, port) || !valid_port(port))
        return null;

    let user = "root", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            let u = substr(url.userinfo, 0, colon);
            if (u != "")
                user = u;
            password = substr(url.userinfo, colon + 1);
        } else {
            user = url.userinfo;
        }
    }

    let outbound = {
        type: "ssh",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + port),
        share_link: raw,
        server: url.host,
        server_port: int(port),
        user: user
    };
    if (password != "")
        outbound.password = password;
    if ((url.query.private_key || "") != "")
        outbound.private_key = url.query.private_key;
    if ((url.query.private_key_path || "") != "")
        outbound.private_key_path = url.query.private_key_path;
    if ((url.query.private_key_passphrase || url.query.passphrase || "") != "")
        outbound.private_key_passphrase = url.query.private_key_passphrase || url.query.passphrase;
    if ((url.query.host_key || "") != "")
        outbound.host_key = split_csv(url.query.host_key);
    if ((url.query.host_key_algorithms || "") != "")
        outbound.host_key_algorithms = split_csv(url.query.host_key_algorithms);
    if ((url.query.client_version || "") != "")
        outbound.client_version = url.query.client_version;
    return outbound;
}

function process_hysteria1(raw, url) {
    if (url.host == "" || is_dummy_server(url.host, url.port) || !valid_port(url.port))
        return null;
    let outbound = {
        type: "hysteria",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: int(url.port)
    };
    let auth = as_string(url.query.auth || url.userinfo || "");
    if (auth != "")
        outbound.auth_str = auth;
    let up = parse_hysteria2_mbps(url.query.upmbps || url.query.up || "");
    if (up != null)
        outbound.up_mbps = up;
    let down = parse_hysteria2_mbps(url.query.downmbps || url.query.down || "");
    if (down != null)
        outbound.down_mbps = down;
    let obfs = as_string(url.query.obfsParam || url.query.obfs || "");
    if (obfs != "" && obfs != "none" && obfs != "plain")
        outbound.obfs = obfs;
    let tls_result = add_tls(url, url.query.security || "", true);
    if (tls_result[0])
        outbound.tls = tls_result[0];
    return outbound;
}

let parse_wdtt_via_core_cli;

function urldecode_raw_plus(value) {
    value = as_string(value);
    if (index(value, "%") < 0)
        return value;
    return replace(value, /%([0-9A-Fa-f][0-9A-Fa-f])/g, function(all, hex_value) {
        return chr(hex(hex_value));
    });
}

function split_wdtt_hashes(raw) {
    let out = [];
    for (let item in split(as_string(raw), /[,|;+\r\n\t ]+/)) {
        item = trim(item);
        if (item == "")
            continue;
        let join_idx = rindex(item, "/call/join/");
        if (join_idx >= 0) {
            let tail = substr(item, join_idx + 11);
            let parts = split(tail, /[?#\/]/);
            item = length(parts) > 0 ? trim(parts[0]) : "";
        }
        if (item != "")
            push(out, item);
    }
    return out;
}

function parse_wdtt_port_val(value) {
    if (type(value) == "int" || type(value) == "double") {
        let p = int(value);
        return (p >= 1 && p <= 65535) ? p : null;
    }
    let text = trim(as_string(value));
    if (text == "" || match(text, /^[0-9]+$/) == null)
        return null;
    let p = int(text);
    return (p >= 1 && p <= 65535) ? p : null;
}

function parse_wdtt_worker_val(value) {
    let p = parse_wdtt_port_val(value);
    return (p != null && p >= 1 && p <= 126) ? p : null;
}

function strip_brackets(host) {
    host = trim(as_string(host));
    if (substr(host, 0, 1) == "[" && substr(host, length(host) - 1) == "]")
        return substr(host, 1, length(host) - 2);
    return host;
}

function parse_csqtt_v2_peer(raw) {
    let s = trim(as_string(raw));
    if (s == "")
        return [ "", null ];
    if (match(s, /^[0-9]+$/) != null) {
        let p = parse_wdtt_port_val(s);
        if (p != null)
            return [ "", p ];
    }
    if (substr(s, 0, 1) == "[") {
        let end_br = index(s, "]:");
        if (end_br > 1) {
            let host = trim(substr(s, 1, end_br - 1));
            let port = parse_wdtt_port_val(substr(s, end_br + 2));
            return [ host, port ];
        }
        if (substr(s, length(s) - 1) == "]") {
            let host = trim(substr(s, 1, length(s) - 2));
            return [ host, null ];
        }
    }
    let last_colon = rindex(s, ":");
    if (last_colon > 0 && index(substr(s, 0, last_colon), ":") < 0) {
        let port = parse_wdtt_port_val(substr(s, last_colon + 1));
        if (port != null)
            return [ trim(substr(s, 0, last_colon)), port ];
    }
    return [ strip_brackets(s), null ];
}

function parse_csqtt_v2_pairs(query) {
    query = as_string(query);
    if (index(query, "&") >= 0) {
        let pairs = [];
        for (let part in split(query, "&")) {
            if (part == "")
                continue;
            let eq = index(part, "=");
            if (eq > 0)
                push(pairs, [ substr(part, 0, eq), substr(part, eq + 1) ]);
        }
        return pairs;
    }

    const KNOWN_KEYS = [
        "turn_transport=", "device_id=", "srtp_mode=", "vk_token=",
        "password=", "streams=", "workers=", "server=", "hashes=",
        "token=", "hash=", "host=", "peer=", "port=", "pass=",
        "obfs=", "srtp=", "mode=", "name=", "did=", "ip=", "v="
    ];

    let spans = [];
    let qlen = length(query);
    let i = 0;
    while (i < qlen) {
        let matched = null;
        let rest_lc = lc(substr(query, i, 16));
        for (let k in KNOWN_KEYS) {
            if (k == "v=" && i > 0)
                continue;
            if (substr(rest_lc, 0, length(k)) == k) {
                matched = k;
                break;
            }
        }
        if (matched != null) {
            push(spans, [ i, i + length(matched) ]);
            i += length(matched);
        } else {
            i += 1;
        }
    }

    if (length(spans) == 0) {
        let eq = index(query, "=");
        return eq > 0 ? [ [ substr(query, 0, eq), substr(query, eq + 1) ] ] : [];
    }

    let pairs = [];
    for (let idx = 0; idx < length(spans); idx++) {
        let k_start = spans[idx][0];
        let val_start = spans[idx][1];
        let val_end = (idx + 1 < length(spans)) ? spans[idx + 1][0] : qlen;
        let k_name = substr(query, k_start, val_start - k_start - 1);
        let val = substr(query, val_start, val_end - val_start);
        push(pairs, [ k_name, val ]);
    }
    return pairs;
}

function parse_csqtt_v2_connect_query(text, frag_tag, raw) {
    let trimmed = trim(as_string(text));
    let qpos = index(trimmed, "?");
    let query = qpos >= 0 ? substr(trimmed, qpos + 1) : trimmed;
    let params = {};
    for (let kv in parse_csqtt_v2_pairs(query)) {
        let k = trim(lc(kv[0]));
        if (k == "")
            continue;
        let v = (k == "hashes" || k == "hash") ? urldecode_raw_plus(kv[1]) : urldecode(kv[1]);
        params[k] = v;
    }

    let peer_info = params.peer != null ? parse_csqtt_v2_peer(params.peer) : [ "", null ];
    let server = strip_brackets(params.host || params.server || params.ip || peer_info[0] || "");
    if (server == "" || is_dummy_server(server, null))
        return null;

    let server_port = peer_info[1] || parse_wdtt_port_val(params.port) || 46000;
    let pass = as_string(params.password || params.pass || "");
    if (pass == "")
        return null;

    let mode_lc = trim(lc(as_string(params.mode || "")));
    let mode = "csqtt";
    if (mode_lc == "csqtt_v1" || mode_lc == "wg" || mode_lc == "raw")
        mode = mode_lc;
    else if (trim(as_string(params.v || "")) == "1")
        mode = "csqtt_v1";

    let tag = frag_tag != "" ? frag_tag : trim(as_string(params.name || ""));
    if (tag == "")
        tag = "csqtt-" + server + ":" + server_port;

    let outbound = {
        type: "wdtt",
        tag: tag,
        share_link: raw,
        server: server,
        server_port: server_port,
        password: pass,
        mode: mode
    };

    let did = trim(as_string(params.did || params.device_id || ""));
    if (did != "")
        outbound.device_id = did;
    let obfs = trim(lc(as_string(params.obfs || "")));
    if (obfs == "audio" || obfs == "video" || obfs == "unified")
        outbound.obfs = obfs;
    let srtp = trim(lc(as_string(params.srtp_mode || params.srtp || "")));
    if (srtp == "auto" || srtp == "dtls" || srtp == "wrap" || srtp == "dtls-srtp" || srtp == "wrap-srtp")
        outbound.srtp_mode = srtp;
    let tt = trim(lc(as_string(params.turn_transport || "")));
    if (tt == "auto" || tt == "tcp" || tt == "udp" || tt == "tcp_tls" || tt == "tls")
        outbound.turn_transport = tt;
    let token = trim(as_string(params.token || params.vk_token || ""));
    if (token != "")
        outbound.vk_token = token;
    let h_raw = params.hashes != null ? params.hashes : params.hash;
    if (h_raw != null) {
        let hashes = split_wdtt_hashes(h_raw);
        if (length(hashes) > 0)
            outbound.hashes = hashes;
    }
    let workers = parse_wdtt_worker_val(params.workers || params.streams);
    if (workers != null)
        outbound.workers = workers;
    return outbound;
}

function process_wdtt(raw) {
    let trimmed = trim(as_string(raw));
    let sep = index(trimmed, "://");
    if (sep <= 0)
        return null;
    let scheme = lc(substr(trimmed, 0, sep));
    let after = substr(trimmed, sep + 3);
    let hash_pos = index(after, "#");
    let body = hash_pos >= 0 ? trim(substr(after, 0, hash_pos)) : trim(after);
    let frag_tag = hash_pos >= 0 ? trim(urldecode_fragment(substr(after, hash_pos + 1))) : "";

    // 0. csqtt:// plaintext connect?v=2 or encrypted csqtt://<b64url>
    if (scheme == "csqtt") {
        if (lc(substr(body, 0, 8)) == "connect?")
            return parse_csqtt_v2_connect_query(body, frag_tag, raw);
        if (index(body, ":") < 0 && index(body, "?") < 0 && index(body, "@") < 0) {
            let b64_check = base64_decode(replace(body, /\/+$/, ""));
            let maybe_json = b64_check != null ? json_decode_text(b64_check) : null;
            if (type(maybe_json) != "object" && parse_wdtt_via_core_cli != null) {
                let cli_out = parse_wdtt_via_core_cli(raw);
                if (type(cli_out) == "object")
                    return cli_out;
            }
        }
    }

    // 1. qwdtt://config?ip=...&dtls=...&hashes=...&pass=<unencoded_password>
    if (scheme == "qwdtt") {
        let qpos = index(body, "?");
        let query_raw = qpos >= 0 ? substr(body, qpos + 1) : body;
        let params = {};
        let head_q = query_raw;
        let raw_pass = null;
        let amp_pass = index(query_raw, "&pass=");
        if (amp_pass >= 0) {
            head_q = substr(query_raw, 0, amp_pass);
            raw_pass = substr(query_raw, amp_pass + 6);
        } else if (substr(query_raw, 0, 5) == "pass=") {
            head_q = "";
            raw_pass = substr(query_raw, 5);
        }
        for (let pair in split(head_q, "&")) {
            if (pair == "")
                continue;
            let eq = index(pair, "=");
            let k = eq >= 0 ? trim(lc(substr(pair, 0, eq))) : trim(lc(pair));
            let v = eq >= 0 ? urldecode(substr(pair, eq + 1)) : "";
            if (k != "")
                params[k] = v;
        }
        if (raw_pass != null)
            params.pass = urldecode_raw_plus(raw_pass);

        let server = strip_brackets(params.ip || params.server || params.host || "");
        let pass = as_string(params.pass || params.password || "");
        if (server == "" || pass == "" || is_dummy_server(server, null))
            return null;

        let mode_lc = trim(lc(as_string(params.mode || params.vpn || "")));
        let mode = (mode_lc == "raw" || mode_lc == "csqtt" || mode_lc == "csqtt_v1") ? mode_lc : "wg";
        let dtls_port = parse_wdtt_port_val(params.dtls || params.port) ||
            ((mode == "csqtt" || mode == "csqtt_v1") ? 46000 : 56000);
        let raw_port = parse_wdtt_port_val(params.raw);
        let server_port = (mode == "raw" && raw_port != null) ? raw_port : dtls_port;
        let tag = frag_tag != "" ? frag_tag : trim(as_string(params.name || ""));
        if (tag == "")
            tag = "wdtt-" + server + ":" + server_port;

        let outbound = {
            type: "wdtt",
            tag: tag,
            share_link: raw,
            server: server,
            server_port: server_port,
            password: pass
        };
        if (raw_port != null)
            outbound.raw_port = raw_port;
        if (mode != "wg")
            outbound.mode = mode;
        let obfs = trim(lc(as_string(params.obfs || "")));
        if (obfs == "audio" || obfs == "video" || obfs == "unified")
            outbound.obfs = obfs;
        let srtp = trim(lc(as_string(params.srtp_mode || params.srtp || "")));
        if (srtp == "auto" || srtp == "dtls" || srtp == "wrap" || srtp == "dtls-srtp" || srtp == "wrap-srtp")
            outbound.srtp_mode = srtp;
        let h_raw = params.hashes != null ? params.hashes : params.hash;
        if (h_raw != null) {
            let hashes = split_wdtt_hashes(h_raw);
            if (length(hashes) > 0)
                outbound.hashes = hashes;
        }
        let workers = parse_wdtt_worker_val(params.streams || params.workers);
        if (workers != null)
            outbound.workers = workers;
        return outbound;
    }

    // 2. Base64 / RawBase64 JSON format: wdtt://eyJ... or csqtt://eyJ...
    let b64_candidate = replace(body, /\/+$/, "");
    if (index(b64_candidate, ":") < 0 && index(b64_candidate, "?") < 0 && index(b64_candidate, "@") < 0) {
        let decoded = base64_decode(b64_candidate);
        let jmap = decoded != null ? json_decode_text(decoded) : null;
        if (type(jmap) == "object") {
            let server = strip_brackets(jmap.ip || jmap.add || jmap.server || "");
            let pass = as_string(jmap.pass || jmap.id || jmap.password || "");
            if (server == "" || pass == "" || is_dummy_server(server, null))
                return null;
            let raw_mode = trim(lc(as_string(jmap.vpn || jmap.mode || "")));
            let mode = "wg";
            if (scheme == "csqtt")
                mode = raw_mode == "csqtt_v1" ? "csqtt_v1" : "csqtt";
            else if (raw_mode == "raw" || raw_mode == "csqtt" || raw_mode == "csqtt_v1")
                mode = raw_mode;
            let dtls_port = parse_wdtt_port_val(jmap.dtls || jmap.port) ||
                ((mode == "csqtt" || mode == "csqtt_v1") ? 46000 : 56000);
            let raw_port = parse_wdtt_port_val(jmap.raw);
            let server_port = (mode == "raw") ? (raw_port || (dtls_port + 3 <= 65535 ? dtls_port + 3 : dtls_port)) : dtls_port;
            let tag = frag_tag != "" ? frag_tag : trim(as_string(jmap.name || jmap.ps || ""));
            if (tag == "")
                tag = "wdtt-" + server + ":" + server_port;

            let outbound = {
                type: "wdtt",
                tag: tag,
                share_link: raw,
                server: server,
                server_port: server_port,
                password: pass
            };
            if (raw_port != null)
                outbound.raw_port = raw_port;
            if (mode != "wg")
                outbound.mode = mode;
            let did = trim(as_string(jmap.did || jmap.device_id || ""));
            if (did != "")
                outbound.device_id = did;
            let obfs = trim(lc(as_string(jmap.obfs || "")));
            if (obfs == "audio" || obfs == "video" || obfs == "unified")
                outbound.obfs = obfs;
            let srtp = trim(lc(as_string(jmap.srtp_mode || jmap.srtp || "")));
            if (srtp == "auto" || srtp == "dtls" || srtp == "wrap" || srtp == "dtls-srtp" || srtp == "wrap-srtp")
                outbound.srtp_mode = srtp;
            let workers = parse_wdtt_worker_val(jmap.workers || jmap.streams);
            if (workers != null)
                outbound.workers = workers;
            let h_val = jmap.hash != null ? jmap.hash : jmap.hashes;
            if (type(h_val) == "string") {
                let hashes = split_wdtt_hashes(h_val);
                if (length(hashes) > 0)
                    outbound.hashes = hashes;
            } else if (type(h_val) == "array") {
                let hashes = [];
                for (let item in h_val) {
                    if (type(item) == "string") {
                        for (let h in split_wdtt_hashes(item))
                            push(hashes, h);
                    }
                }
                if (length(hashes) > 0)
                    outbound.hashes = hashes;
            }
            return outbound;
        }
    }

    // 3. Colon format: wdtt://host:dtls_port:wg_port:local_port:pass:hash1,hash2#remark
    if (index(body, "?") < 0 && index(body, "@") < 0) {
        let host_part = "";
        let tail = "";
        if (substr(body, 0, 1) == "[") {
            let end_br = index(body, "]:");
            if (end_br > 1) {
                host_part = trim(substr(body, 1, end_br - 1));
                tail = substr(body, end_br + 2);
            }
        } else {
            let cpos = index(body, ":");
            if (cpos > 0) {
                host_part = trim(substr(body, 0, cpos));
                tail = substr(body, cpos + 1);
            }
        }
        if (host_part != "" && tail != "") {
            let parts = split(tail, ":", 5);
            let dtls_port = length(parts) == 5 ? parse_wdtt_port_val(parts[0]) : null;
            if (dtls_port != null && !is_dummy_server(host_part, dtls_port)) {
                let wg_port = parse_wdtt_port_val(parts[1]);
                let local_port = parse_wdtt_port_val(parts[2]);
                let pass = urldecode_raw_plus(trim(parts[3]));
                if (pass == "")
                    return null;
                let hashes = split_wdtt_hashes(urldecode_raw_plus(trim(parts[4])));
                let tag = frag_tag != "" ? frag_tag : ("wdtt-" + host_part + ":" + dtls_port);
                let outbound = {
                    type: "wdtt",
                    tag: tag,
                    share_link: raw,
                    server: host_part,
                    server_port: dtls_port,
                    password: pass
                };
                if (wg_port != null)
                    outbound.wg_port = wg_port;
                if (local_port != null)
                    outbound.local_port = local_port;
                if (scheme == "csqtt")
                    outbound.mode = "csqtt";
                if (length(hashes) > 0)
                    outbound.hashes = hashes;
                return outbound;
            }
        }
    }

    // 4. Standard query URI: wdtt://[pass@]host[:port]?pass=...&hashes=...&mode=...#remark
    let url = parse_url(trimmed);
    if (!url || url.host == "")
        return null;
    let default_port = (scheme == "csqtt") ? 46000 : 56000;
    let port = parse_wdtt_port_val(url.port) || default_port;
    if (is_dummy_server(url.host, port))
        return null;
    let pass = url.userinfo != "" ? url.userinfo : as_string(url.query.pass || url.query.password || url.query.id || "");
    if (pass == "")
        return null;
    let raw_mode = trim(lc(as_string(url.query.mode || url.query.vpn || "")));
    let mode = "wg";
    if (scheme == "csqtt")
        mode = raw_mode == "csqtt_v1" ? "csqtt_v1" : "csqtt";
    else if (raw_mode == "raw" || raw_mode == "csqtt" || raw_mode == "csqtt_v1")
        mode = raw_mode;
    let tag = frag_tag != "" ? frag_tag : trim(as_string(url.query.name || url.query.ps || ""));
    if (tag == "")
        tag = "wdtt-" + url.host + ":" + port;

    let outbound = {
        type: "wdtt",
        tag: tag,
        share_link: raw,
        server: strip_brackets(url.host),
        server_port: port,
        password: pass
    };
    let raw_port = parse_wdtt_port_val(url.query.raw_port || url.query.raw);
    if (raw_port != null)
        outbound.raw_port = raw_port;
    if (mode != "wg")
        outbound.mode = mode;
    let obfs = trim(lc(as_string(url.query.obfs || "")));
    if (obfs == "audio" || obfs == "video" || obfs == "unified")
        outbound.obfs = obfs;
    let srtp = trim(lc(as_string(url.query.srtp_mode || url.query.srtp || "")));
    if (srtp == "auto" || srtp == "dtls" || srtp == "wrap" || srtp == "dtls-srtp" || srtp == "wrap-srtp")
        outbound.srtp_mode = srtp;
    let token = trim(as_string(url.query.token || url.query.vk_token || ""));
    if (token != "")
        outbound.vk_token = token;
    let did = trim(as_string(url.query.did || url.query.device_id || ""));
    if (did != "")
        outbound.device_id = did;
    let h_raw = url.query.hashes != null ? url.query.hashes : url.query.hash;
    if (h_raw != null) {
        let hashes = split_wdtt_hashes(h_raw);
        if (length(hashes) > 0)
            outbound.hashes = hashes;
    }
    let workers = parse_wdtt_worker_val(url.query.workers || url.query.streams);
    if (workers != null)
        outbound.workers = workers;
    return outbound;
}

let parse_amnezia_vpn_container;

function parse_share_link(line) {
    if (starts_with(line, "vpn://")) {
        let wg_out = wireguard.from_vpn(line);
        if (wg_out != null)
            return wg_out;
        return parse_amnezia_vpn_container ? parse_amnezia_vpn_container(line) : null;
    }
    if (starts_with(line, "amneziawg://") || starts_with(line, "awg://") ||
        starts_with(line, "wireguard://") || starts_with(line, "wg://"))
        return from_amneziawg_share_link(line);
    if (starts_with(line, "vmess://"))
        return process_vmess(line);
    if (starts_with(line, "ss://"))
        return process_shadowsocks(line);
    if (starts_with(line, "fptn:") || starts_with(line, "fptnb:") || starts_with(line, "fptn://") || starts_with(line, "fptnb://")) {
        let hash_pos = index(line, "#");
        let clean_token = hash_pos >= 0 ? substr(line, 0, hash_pos) : line;
        let frag = hash_pos >= 0 ? urldecode_fragment(substr(line, hash_pos + 1)) : "";
        let res = { type: "fptn", token: clean_token, share_link: line };
        if (frag != "")
            res.tag = frag;
        return res;
    }
    if (starts_with(lc(line), "csqtt://") || starts_with(lc(line), "wdtt://") || starts_with(lc(line), "qwdtt://"))
        return process_wdtt(line);

    let url = parse_url(line);
    if (!url)
        return null;

    if (url.scheme == "vless")
        return process_vless(line, url);
    if (url.scheme == "trojan" || url.scheme == "trojan-go")
        return process_trojan(line, url);
    if (url.scheme == "hysteria2" || url.scheme == "hy2")
        return process_hysteria2(line, url);
    if (url.scheme == "hysteria" || url.scheme == "hy")
        return process_hysteria1(line, url);
    if (url.scheme == "tuic" || url.scheme == "tuic5")
        return process_tuic(line, url);
    if (url.scheme == "anytls")
        return process_anytls(line, url);
    if (url.scheme == "naive" || url.scheme == "naive+https" || url.scheme == "naive+http2" ||
        url.scheme == "naive+h2" || url.scheme == "naive+quic" || url.scheme == "naive+h3")
        return process_naive(line, url);
    if (url.scheme == "snell")
        return process_snell(line, url);
    if (url.scheme == "mieru" || url.scheme == "mierus")
        return process_mieru(line, url);
    if (url.scheme == "tg" || url.scheme == "mtproto")
        return process_mtproto(line, url);
    if (url.scheme == "shadowtls" || url.scheme == "stls")
        return process_shadowtls(line, url);
    if (url.scheme == "sudoku")
        return process_sudoku(line, url);
    if (url.scheme == "ssh")
        return process_ssh(line, url);
    if (url.scheme == "tewfai")
        return process_tewfai(line, url);
    if (url.scheme == "trusttunnel")
        return process_trusttunnel(line, url);
    if (url.scheme == "masque")
        return process_masque(line, url);
    if (url.scheme == "openconnect" || url.scheme == "anyconnect")
        return process_openconnect(line, url);
    if (match(url.scheme, /^socks/))
        return process_socks(line, url);
    if (url.scheme == "http" || url.scheme == "https") {
        if ((url.host == "t.me" || url.host == "telegram.me") && (url.query.secret || "") != "" && (url.query.server || "") != "")
            return process_mtproto(line, url);
        return process_http(line, url);
    }
    return null;
}

function share_link_outbound(raw, tag) {
    let outbound = parse_share_link(raw);
    if (type(outbound) != "object")
        return false;

    outbound.tag = as_string(tag);
    delete outbound.share_link;
    delete outbound.remark;
    write_json(outbound);
    return true;
}

function clean_scalar(value) {
    value = trim(value);
    let first = substr(value, 0, 1);
    let last = substr(value, length(value) - 1);
    if (length(value) >= 2 && ((first == "\"" && last == "\"") || (first == "'" && last == "'")))
        return substr(value, 1, length(value) - 2);
    return value;
}

function leading_indent(value) {
    let m = match(as_string(value), /^[ \t]*/);
    return m ? length(m[0]) : 0;
}

function find_top_level_colon(value) {
    let depth = 0, quote = "", escaped = false;
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        if (quote != "") {
            if (escaped)
                escaped = false;
            else if (char == "\\")
                escaped = true;
            else if (char == quote)
                quote = "";
        }
        else if (char == "\"" || char == "'")
            quote = char;
        else if (char == "{" || char == "[")
            depth++;
        else if (char == "}" || char == "]")
            depth--;
        else if (char == ":" && depth == 0)
            return i;
    }
    return null;
}

function split_top_level(value, separator) {
    let result = [], depth = 0, quote = "", escaped = false, start = 0;
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        if (quote != "") {
            if (escaped)
                escaped = false;
            else if (char == "\\")
                escaped = true;
            else if (char == quote)
                quote = "";
        }
        else if (char == "\"" || char == "'")
            quote = char;
        else if (char == "{" || char == "[")
            depth++;
        else if (char == "}" || char == "]")
            depth--;
        else if (char == separator && depth == 0) {
            push(result, substr(value, start, i - start));
            start = i + 1;
        }
    }
    push(result, substr(value, start));
    return result;
}

function set_record_field(record, key, value) {
    key = clean_scalar(key);
    value = clean_scalar(value);
    if (key == "")
        return;
    if (record.fields[key] == null)
        push(record.keys, key);
    record.fields[key] = value;
}

let parse_clash_map;

function parse_clash_pair(record, part, prefix) {
    part = trim(part);
    let colon = find_top_level_colon(part);
    if (colon == null)
        return;
    let key = clean_scalar(substr(part, 0, colon));
    let value = trim(substr(part, colon + 1));
    if (substr(value, 0, 1) == "{" && substr(value, length(value) - 1) == "}")
        parse_clash_map(record, value, prefix + key + ".");
    else
        set_record_field(record, prefix + key, value);
}

parse_clash_map = function(record, value, prefix) {
    value = trim(value);
    if (substr(value, 0, 1) == "{")
        value = substr(value, 1);
    if (substr(value, length(value) - 1) == "}")
        value = substr(value, 0, length(value) - 1);

    for (let part in split_top_level(value, ","))
        parse_clash_pair(record, part, prefix);
};

function empty_clash_record() {
    return {
        fields: {},
        keys: [],
        context: "",
        context_indent: -1,
        context_stack: []
    };
}

function clash_record_has_fields(record) {
    return length(record.keys) > 0;
}

function emit_clash_record(records, record) {
    if (!clash_record_has_fields(record))
        return empty_clash_record();

    let item = {};
    for (let key in record.keys) {
        if (record.fields[key] != null)
            item[key] = record.fields[key];
    }
    push(records, item);
    return empty_clash_record();
}

let clash_nested_keys = {
    "ws-opts": true,
    "httpupgrade-opts": true,
    "grpc-opts": true,
    "h2-opts": true,
    "http-opts": true,
    "xhttp-opts": true,
    "splithttp-opts": true,
    "reality-opts": true,
    "obfs-opts": true,
    "plugin-opts": true,
    "amnezia-wg-option": true,
    "amnezia_wg_option": true,
    "amnezia-wg-opts": true,
    "amnezia_wg_opts": true,
    headers: true,
    extra: true,
    xmux: true
};

function parse_clash_block_line(record, line) {
    let indent = leading_indent(line);
    let text = trim(line);
    if (text == "")
        return;

    let colon = index(text, ":");
    if (colon < 0)
        return;

    let key = clean_scalar(substr(text, 0, colon));
    let value = trim(substr(text, colon + 1));

    while (length(record.context_stack) > 0 && indent <= record.context_stack[length(record.context_stack) - 1][0]) {
        pop(record.context_stack);
    }
    if (length(record.context_stack) > 0) {
        let top = record.context_stack[length(record.context_stack) - 1];
        record.context_indent = top[0];
        record.context = top[1];
    } else {
        record.context = "";
        record.context_indent = -1;
    }

    if (value == "") {
        if (clash_nested_keys[key]) {
            let next_ctx = (record.context != "" && indent > record.context_indent) ? (record.context + "." + key) : key;
            record.context = next_ctx;
            record.context_indent = indent;
            push(record.context_stack, [ indent, next_ctx ]);
        }
        return;
    }

    let full_key = key;
    if (record.context != "" && indent > record.context_indent)
        full_key = record.context + "." + key;
    set_record_field(record, full_key, value);
}

function is_clash_proxies_header(line) {
    let text = trim(line);
    return text == "proxies:" || match(text, /^proxies:\s*#/);
}

function clash_yaml_records(input_file) {
    let data = read_file(input_file);
    if (data == null)
        return [];

    let records = [];
    let record = empty_clash_record();
    let in_proxies = false;

    for (let line in split(data, "\n")) {
        line = replace(line, /\r$/g, "");
        let proxies_header = is_clash_proxies_header(line);

        if (in_proxies && match(line, /^[^ \t]/) && !proxies_header && !match(line, /^-[ \t]/)) {
            record = emit_clash_record(records, record);
            in_proxies = false;
        }

        if (proxies_header) {
            record = emit_clash_record(records, record);
            in_proxies = true;
        }
        else if (in_proxies) {
            if (match(line, /^[ \t]*-[ \t]*\{/)) {
                record = emit_clash_record(records, record);
                record = empty_clash_record();
                let map_value = replace(line, /^[ \t]*-[ \t]*/g, "");
                parse_clash_map(record, map_value, "");
                record = emit_clash_record(records, record);
            }
            else if (match(line, /^[ \t]*-[ \t]*/)) {
                record = emit_clash_record(records, record);
                record = empty_clash_record();
                let rest = replace(line, /^[ \t]*-[ \t]*/g, "");
                if (trim(rest) != "")
                    parse_clash_block_line(record, rest);
            }
            else if (clash_record_has_fields(record)) {
                parse_clash_block_line(record, line);
            }
        }
    }

    emit_clash_record(records, record);
    return records;
}

function clash_vless_flow_supported(flow) {
    return normalize_vless_flow(flow) != null;
}

function normalized_clash_alpn(value) {
    return replace(replace(replace(as_string(value), /^\[/g, ""), /\]$/g, ""), /\s+/g, "");
}

function add_clash_tls(outbound, options) {
    let raw_alpn = split_csv(options.alpn);
    let enabled = options.always || is_true(options.tls) || options.sni != "" ||
        length(raw_alpn) > 0 ||
        options.fingerprint != "" || options.reality_public_key != "";
    if (!enabled)
        return;

    let tls = { enabled: true };
    if (options.sni != "")
        tls.server_name = options.sni;
    if (is_true(options.skip_verify))
        tls.insecure = true;
    let alpn = tls_alpn_for_transport(raw_alpn, options.network);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (options.reality_public_key != "") {
        tls.utls = {
            enabled: true,
            fingerprint: options.fingerprint != "" ? options.fingerprint : "chrome"
        };
        tls.reality = { enabled: true, public_key: options.reality_public_key };
        if (options.reality_short_id != "")
            tls.reality.short_id = options.reality_short_id;
        if (options.reality_support_mlkem != null && options.reality_support_mlkem != "")
            tls.reality.support_x25519mlkem768 = is_true(options.reality_support_mlkem);
    }
    else if (options.fingerprint != "") {
        tls.utls = { enabled: true, fingerprint: options.fingerprint };
    }

    outbound.tls = tls;
}

function add_clash_transport(outbound, options, record) {
    if (options.network == "ws") {
        outbound.transport = {
            type: "ws",
            path: options.ws_path != "" ? options.ws_path : "/"
        };
        if (options.ws_host != "")
            outbound.transport.headers = { Host: options.ws_host };
        if (record != null) {
            let ed = as_string(record["ws-opts.max-early-data"] || "");
            if (is_integer_string(ed) && int(ed, 10) > 0)
                outbound.transport.max_early_data = int(ed, 10);
            let eh = as_string(record["ws-opts.early-data-header-name"] || "");
            if (eh != "")
                outbound.transport.early_data_header_name = eh;
        }
    }
    else if (options.network == "grpc") {
        outbound.transport = { type: "grpc" };
        if (options.grpc_service_name != "")
            outbound.transport.service_name = options.grpc_service_name;
    }
    else if (options.network == "httpupgrade") {
        let tr = { type: "httpupgrade" };
        let path = record != null ? as_string(record["httpupgrade-opts.path"] || options.ws_path || "") : options.ws_path;
        let host = record != null ? as_string(record["httpupgrade-opts.host"] || record["httpupgrade-opts.headers.Host"] || options.ws_host || "") : options.ws_host;
        if (path != "")
            tr.path = path;
        if (host != "")
            tr.host = host;
        outbound.transport = tr;
    }
    else if (options.network == "h2" || options.network == "http") {
        let tr = { type: "http" };
        if (record != null) {
            let path = clean_scalar(as_string(record["h2-opts.path"] || record["http-opts.path"] || ""));
            if (substr(path, 0, 1) == "[" && substr(path, length(path) - 1) == "]") {
                let parts = split_csv(normalized_clash_alpn(path));
                path = length(parts) > 0 ? parts[0] : "";
            }
            if (path != "")
                tr.path = path;
            let host_raw = normalized_clash_alpn(record["h2-opts.host"] || record["http-opts.host"] || "");
            let hosts = split_csv(host_raw);
            if (length(hosts) > 0)
                tr.host = hosts;
        }
        outbound.transport = tr;
    }
    else if (options.network == "xhttp" || options.network == "splithttp") {
        let tr = { type: "xhttp" };
        if (record != null) {
            let path = as_string(record["xhttp-opts.path"] || record["splithttp-opts.path"] || "");
            let host = as_string(record["xhttp-opts.host"] || record["splithttp-opts.host"] || "");
            let mode = as_string(record["xhttp-opts.mode"] || record["splithttp-opts.mode"] || "");
            if (path != "")
                tr.path = path;
            if (host != "")
                tr.host = host;
            if (mode != "")
                tr.mode = mode;
        }
        outbound.transport = tr;
    }
}

function parse_clash_record(record) {
    let proxy_type = lc(as_string(record.type));
    let name = as_string(record.name);
    let server = as_string(record.server);
    let port = int(record.port || 0);
    if (name == "")
        name = server + ":" + as_string(record.port);
    if (proxy_type == "" || server == "" || is_dummy_server(server, port) || !valid_port(port))
        return null;

    let options = {
        tls: as_string(record.tls),
        skip_verify: as_string(record["skip-cert-verify"]),
        sni: as_string(record.sni || record.servername),
        network: lc(as_string(record.network)),
        ws_path: as_string(record["ws-opts.path"]),
        ws_host: as_string(record["ws-opts.headers.Host"]),
        grpc_service_name: as_string(record["grpc-opts.grpc-service-name"]),
        reality_public_key: as_string(record["reality-opts.public-key"]),
        reality_short_id: as_string(record["reality-opts.short-id"]),
        reality_support_mlkem: record["reality-opts.support_x25519mlkem768"] != null ? as_string(record["reality-opts.support_x25519mlkem768"]) :
            (record["reality-opts.supportX25519MLKEM768"] != null ? as_string(record["reality-opts.supportX25519MLKEM768"]) :
            (record["reality-opts.support-x25519mlkem768"] != null ? as_string(record["reality-opts.support-x25519mlkem768"]) : "")),
        alpn: normalized_clash_alpn(record.alpn || ""),
        fingerprint: normalize_utls_fingerprint(as_string(record["client-fingerprint"] || record.fingerprint))
    };

    if (proxy_type == "ss" || proxy_type == "shadowsocks") {
        let method = normalize_shadowsocks_method(record.cipher);
        let password = as_string(record.password);
        if (!valid_shadowsocks_password(method, password))
            return null;
        let outbound = { type: "shadowsocks", tag: name, server: server, server_port: port, method: method, password: password };
        if (is_true(record.uot) || is_true(record.udp_over_tcp) || is_true(record["udp-over-tcp"]))
            outbound.udp_over_tcp = true;
        return outbound;
    }
    if (proxy_type == "vmess") {
        let uuid = as_string(record.uuid);
        if (uuid == "")
            return null;
        let outbound = {
            type: "vmess",
            tag: name,
            server: server,
            server_port: port,
            uuid: uuid,
            security: as_string(record.cipher) != "" ? as_string(record.cipher) : "auto"
        };
        if (as_string(record.alterId || record["alter-id"]) != "")
            outbound.alter_id = int(record.alterId || record["alter-id"]);
        let packet_encoding = normalize_packet_encoding(record["packet-encoding"] || record.packetEncoding || record.packet_encoding || record.packetencoding || "");
        if (packet_encoding != "")
            outbound.packet_encoding = packet_encoding;
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options, record);
        return outbound;
    }
    if (proxy_type == "vless") {
        let uuid = as_string(record.uuid);
        let flow = normalize_vless_flow(record.flow);
        let packet_encoding = normalize_packet_encoding(record["packet-encoding"] || record.packetEncoding || record.packet_encoding || record.packetencoding || "");
        let encryption = normalize_vless_encryption(record.encryption || "");
        if (uuid == "" || flow == null)
            return null;
        let outbound = { type: "vless", tag: name, server: server, server_port: port, uuid: uuid };
        if (encryption != "")
            outbound.encryption = encryption;
        if (flow != "")
            outbound.flow = flow;
        if (packet_encoding != "")
            outbound.packet_encoding = packet_encoding;
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options, record);
        return outbound;
    }
    if (proxy_type == "trojan") {
        let password = as_string(record.password);
        if (password == "")
            return null;
        let outbound = { type: "trojan", tag: name, server: server, server_port: port, password: password };
        options.always = true;
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options, record);
        return outbound;
    }
    if (proxy_type == "hysteria2" || proxy_type == "hy2") {
        let password = as_string(record.password || record.auth || "");
        if (password == "")
            return null;
        let outbound = { type: "hysteria2", tag: name, server: server, server_port: port, password: password, tls: { enabled: true } };
        if (options.sni != "")
            outbound.tls.server_name = options.sni;
        else
            outbound.tls.server_name = server;
        if (is_true(options.skip_verify))
            outbound.tls.insecure = true;
        if (options.alpn != "")
            outbound.tls.alpn = split_csv(options.alpn);
        let obfs = lc(trim(as_string(record.obfs || "")));
        let obfs_password = as_string(record["obfs-password"] || record.obfs_password || record["obfs-opts.password"] || "");
        if (obfs != "" && obfs != "none") {
            let min_ps = xhttp_positive_integer_value(record["min-packet-size"] || record.min_packet_size) || 0;
            let max_ps = xhttp_positive_integer_value(record["max-packet-size"] || record.max_packet_size) || 0;
            let ps_pair = parse_hysteria2_packet_size_value(record["packet-size"] || record.packet_size || record.packetSize);
            if (ps_pair != null) {
                if (min_ps <= 0) min_ps = ps_pair[0];
                if (max_ps <= 0) max_ps = ps_pair[1];
            }
            if (obfs == "gecko" || min_ps > 0 || max_ps > 0)
                outbound.obfs = build_hysteria2_obfs(true, obfs_password, min_ps, max_ps);
            else {
                outbound.obfs = { type: obfs };
                if (obfs_password != "")
                    outbound.obfs.password = obfs_password;
            }
        }
        let sp = parse_hysteria2_server_ports(as_string(record.ports || record.mport || ""));
        if (sp != null)
            outbound.server_ports = sp;
        let hi = normalize_hysteria2_hop_interval(record["hop-interval"] || record.hop_interval);
        if (hi != "")
            outbound.hop_interval = hi;
        let up = parse_hysteria2_mbps(record.up);
        if (up != null)
            outbound.up_mbps = up;
        let down = parse_hysteria2_mbps(record.down);
        if (down != null)
            outbound.down_mbps = down;
        return outbound;
    }
    if (proxy_type == "hysteria" || proxy_type == "hy") {
        let outbound = { type: "hysteria", tag: name, server: server, server_port: port, tls: { enabled: true } };
        if (options.sni != "")
            outbound.tls.server_name = options.sni;
        else
            outbound.tls.server_name = server;
        if (is_true(options.skip_verify))
            outbound.tls.insecure = true;
        if (options.alpn != "")
            outbound.tls.alpn = split_csv(options.alpn);
        let auth_str = as_string(record["auth-str"] || record.auth_str || record.auth || "");
        if (auth_str != "")
            outbound.auth_str = auth_str;
        let obfs = as_string(record.obfs || "");
        if (obfs != "")
            outbound.obfs = obfs;
        let up = parse_hysteria2_mbps(record.up);
        if (up != null)
            outbound.up_mbps = up;
        let down = parse_hysteria2_mbps(record.down);
        if (down != null)
            outbound.down_mbps = down;
        return outbound;
    }
    if (proxy_type == "tuic") {
        let uuid = as_string(record.uuid || record.token || "");
        let password = as_string(record.password || record.token || "");
        if (uuid == "")
            return null;
        let outbound = { type: "tuic", tag: name, server: server, server_port: port, uuid: uuid, tls: { enabled: true } };
        if (password != "")
            outbound.password = password;
        if (options.sni != "")
            outbound.tls.server_name = options.sni;
        else
            outbound.tls.server_name = server;
        if (is_true(options.skip_verify) || is_true(record["skip-cert-verify"]))
            outbound.tls.insecure = true;
        if (options.alpn != "")
            outbound.tls.alpn = split_csv(options.alpn);
        let cc = as_string(record["congestion-controller"] || record["congestion-control"] || record.congestion_control || "");
        if (cc != "")
            outbound.congestion_control = cc;
        let udp_mode = as_string(record["udp-relay-mode"] || record.udp_relay_mode || "");
        if (udp_mode != "")
            outbound.udp_relay_mode = udp_mode;
        if (is_true(record["reduce-rtt"]) || is_true(record["fast-open"]) || is_true(record["zero-rtt-握手"]) || is_true(record["zero_rtt_handshake"]))
            outbound.zero_rtt_handshake = true;
        return outbound;
    }
    if (proxy_type == "wireguard" || proxy_type == "amneziawg" || proxy_type == "awg") {
        let priv_key = trim(as_string(record["private-key"] || record.private_key || ""));
        let pub_key = trim(as_string(record["public-key"] || record.public_key || ""));
        if (priv_key == "" || pub_key == "")
            return null;
        let addrs = [];
        for (let raw_ip in [ as_string(record.ip || ""), as_string(record.ipv6 || "") ]) {
            if (trim(raw_ip) == "")
                continue;
            for (let part in split(raw_ip, ",")) {
                part = trim(part);
                if (part == "")
                    continue;
                if (index(part, "/") < 0)
                    part = part + (index(part, ":") >= 0 ? "/128" : "/32");
                push(addrs, part);
            }
        }
        if (length(addrs) == 0)
            push(addrs, "10.0.0.2/32");
        let peer = {
            address: server,
            port: port,
            public_key: pub_key,
            allowed_ips: [ "0.0.0.0/0", "::/0" ]
        };
        let outbound = {
            type: "wireguard",
            tag: name,
            server: server,
            server_port: port,
            private_key: priv_key,
            peer_public_key: pub_key,
            local_address: addrs,
            address: addrs,
            peers: [ peer ]
        };
        let psk = trim(as_string(record["pre-shared-key"] || record["preshared-key"] || record.pre_shared_key || ""));
        if (psk != "") {
            outbound.pre_shared_key = psk;
            peer.pre_shared_key = psk;
        }
        let mtu_s = trim(as_string(record.mtu || ""));
        if (is_integer_string(mtu_s) && int(mtu_s, 10) > 0)
            outbound.mtu = int(mtu_s, 10);
        let prefixes = [ "amnezia-wg-option.", "amnezia_wg_option.", "amnezia-wg-opts.", "amnezia_wg_opts.", "" ];
        for (let ik in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4" ]) {
            for (let pref in prefixes) {
                let v = trim(as_string(record[pref + ik] || ""));
                if (is_integer_string(v)) {
                    outbound[ik] = int(v, 10);
                    break;
                }
            }
        }
        for (let hk in [ "h1", "h2", "h3", "h4" ]) {
            for (let pref in prefixes) {
                let v = trim(as_string(record[pref + hk] || ""));
                if (v != "") {
                    outbound[hk] = is_integer_string(v) ? int(v, 10) : v;
                    break;
                }
            }
        }
        for (let sk in [ "i1", "i2", "i3", "i4", "i5" ]) {
            for (let pref in prefixes) {
                let v = trim(as_string(record[pref + sk] || ""));
                if (v != "") {
                    outbound[sk] = v;
                    break;
                }
            }
        }
        return outbound;
    }
    if (proxy_type == "socks5" || proxy_type == "socks") {
        let outbound = { type: "socks", tag: name, server: server, server_port: port, version: "5" };
        if (as_string(record.username) != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password) != "")
            outbound.password = as_string(record.password);
        return outbound;
    }
    if (proxy_type == "http" || proxy_type == "https") {
        let outbound = { type: "http", tag: name, server: server, server_port: port };
        if (as_string(record.username) != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password) != "")
            outbound.password = as_string(record.password);
        if (proxy_type == "https" || is_true(record.tls))
            outbound.tls = { enabled: true };
        return outbound;
    }
    if (proxy_type == "anytls") {
        let password = as_string(record.password);
        if (password == "")
            return null;
        let outbound = { type: "anytls", tag: name, server: server, server_port: port, password: password };
        if (is_integer_string(as_string(record["min-idle-session"] || record.min_idle_session || "")))
            outbound.min_idle_session = int(record["min-idle-session"] || record.min_idle_session, 10);
        if (as_string(record["idle-session-check-interval"] || record.idle_session_check_interval || "") != "")
            outbound.idle_session_check_interval = as_string(record["idle-session-check-interval"] || record.idle_session_check_interval);
        if (as_string(record["idle-session-timeout"] || record.idle_session_timeout || "") != "")
            outbound.idle_session_timeout = as_string(record["idle-session-timeout"] || record.idle_session_timeout);
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "snell") {
        let psk = as_string(record.psk || record.password || "");
        if (psk == "")
            return null;
        let version = int(record.version || 5);
        if (version < 1 || version > 6)
            version = 5;
        let outbound = { type: "snell", tag: name, server: server, server_port: port, psk: psk, version: version };
        let obfs_mode = lc(as_string(record["obfs-opts.mode"] || record.obfs || ""));
        if (obfs_mode == "http" || obfs_mode == "tls") {
            outbound.obfs = { mode: obfs_mode };
            let obfs_host = as_string(record["obfs-opts.host"] || record["obfs-host"] || "");
            if (obfs_host != "")
                outbound.obfs.host = obfs_host;
        }
        if (is_true(record.uot) || is_true(record.udp_over_tcp) || is_true(record["udp-over-tcp"]))
            outbound.udp_over_tcp = true;
        if (is_true(record.reuse))
            outbound.reuse = true;
        return outbound;
    }
    if (proxy_type == "mieru") {
        let username = as_string(record.username || "");
        let password = as_string(record.password || "");
        if (username == "" || password == "")
            return null;
        let transport = uc(as_string(record.transport || "TCP"));
        if (transport != "UDP")
            transport = "TCP";
        let outbound = {
            type: "mieru",
            tag: name,
            server: server,
            server_port: port,
            username: username,
            password: password,
            transport: transport
        };
        if (as_string(record.multiplexing || "") != "")
            outbound.multiplexing = as_string(record.multiplexing);
        return outbound;
    }
    if (proxy_type == "shadow-tls" || proxy_type == "shadowtls") {
        let password = as_string(record.password || "");
        if (password == "")
            return null;
        let version = int(record.version || 3);
        if (version < 1 || version > 3)
            version = 3;
        let outbound = {
            type: "shadowtls",
            tag: name,
            server: server,
            server_port: port,
            version: version,
            password: password
        };
        options.always = true;
        if (options.sni == "" && as_string(record.host || "") != "")
            options.sni = as_string(record.host);
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "mtproto" || proxy_type == "tg") {
        let secret = as_string(record.secret || record.password || "");
        if (secret == "")
            return null;
        let outbound = {
            type: "mtproto",
            tag: name,
            server: server,
            server_port: port,
            secret: secret
        };
        if (as_string(record.transport || "") != "")
            outbound.transport = lc(as_string(record.transport));
        if (options.sni != "")
            outbound.tls = { enabled: true, server_name: options.sni };
        return outbound;
    }
    if (proxy_type == "tewfai") {
        let uuid = as_string(record.uuid || "");
        if (uuid == "")
            return null;
        let outbound = {
            type: "tewfai",
            tag: name,
            server: server,
            server_port: port,
            uuid: uuid
        };
        if (as_string(record.password || "") != "")
            outbound.password = as_string(record.password);
        if (as_string(record.transport || "") != "")
            outbound.transport = split_csv(as_string(record.transport));
        if (as_string(record["inner-cipher"] || record.inner_cipher || "") != "")
            outbound.inner_cipher = as_string(record["inner-cipher"] || record.inner_cipher);
        if (as_string(record["morph-profile"] || record.morph_profile || "") != "")
            outbound.morph_profile = as_string(record["morph-profile"] || record.morph_profile);
        if (is_true(record.pqc))
            outbound.pqc = true;
        if (is_true(record.fec))
            outbound.fec = true;
        if (is_true(record.desync))
            outbound.desync = true;
        if (is_true(record.handover))
            outbound.handover = { enabled: true };
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "trusttunnel") {
        let outbound = {
            type: "trusttunnel",
            tag: name,
            server: server,
            server_port: port
        };
        if (as_string(record.username || "") != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password || "") != "")
            outbound.password = as_string(record.password);
        if (is_true(record.quic))
            outbound.quic = true;
        if (as_string(record["congestion-control"] || record.quic_congestion_control || "") != "")
            outbound.quic_congestion_control = as_string(record["congestion-control"] || record.quic_congestion_control);
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "masque") {
        let outbound = {
            type: "masque",
            tag: name,
            server: server,
            server_port: port
        };
        if (as_string(record.profile || "") != "")
            outbound.profile = as_string(record.profile);
        if (as_string(record.vhttp || "") != "")
            outbound.vhttp = as_string(record.vhttp);
        if (as_string(record["private-key"] || record.private_key || "") != "")
            outbound.private_key = as_string(record["private-key"] || record.private_key);
        if (as_string(record["public-key"] || record.public_key || "") != "")
            outbound.public_key = as_string(record["public-key"] || record.public_key);
        if (as_string(record.ip || "") != "")
            outbound.ip = as_string(record.ip);
        if (as_string(record.ipv6 || "") != "")
            outbound.ipv6 = as_string(record.ipv6);
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "sudoku") {
        let key = as_string(record.key || record.password || "");
        if (key == "")
            return null;
        let outbound = {
            type: "sudoku",
            tag: name,
            server: server,
            server_port: port,
            key: key
        };
        let aead = as_string(record["aead-method"] || record.aead_method || record.aead || "");
        if (aead != "")
            outbound.aead = aead;
        let pmin = as_string(record["padding-min"] || record.padding_min || "");
        if (is_integer_string(pmin))
            outbound.padding_min = int(pmin, 10);
        let pmax = as_string(record["padding-max"] || record.padding_max || "");
        if (is_integer_string(pmax))
            outbound.padding_max = int(pmax, 10);
        let tt = as_string(record["table-type"] || record.table_type || record.ascii || "");
        if (tt != "")
            outbound.table_type = tt;
        let hm = record["http-mask"] != null ? record["http-mask"] : record.http_mask;
        if (hm != null)
            outbound.disable_http_mask = !is_true(hm);
        let hmode = as_string(record["http-mask-mode"] || record.http_mask_mode || "");
        let hhost = as_string(record["http-mask-host"] || record.http_mask_host || "");
        let hpath = as_string(record["http-mask-path"] || record.http_mask_path || record.path || "");
        if (hmode != "" || hhost != "" || hpath != "") {
            let mask = {};
            if (hmode != "") mask.mode = hmode;
            if (hhost != "") mask.host = hhost;
            if (hpath != "") mask.path_root = hpath;
            outbound.http_mask = mask;
        }
        return outbound;
    }
    if (proxy_type == "naive") {
        let outbound = {
            type: "naive",
            tag: name,
            server: server,
            server_port: port
        };
        if (as_string(record.username || "") != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password || "") != "")
            outbound.password = as_string(record.password);
        if (is_true(record.quic))
            outbound.quic = true;
        if (is_true(record.uot) || is_true(record["udp-over-tcp"]) || is_true(record.udp_over_tcp))
            outbound.udp_over_tcp = true;
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    if (proxy_type == "ssh") {
        let outbound = {
            type: "ssh",
            tag: name,
            server: server,
            server_port: port,
            user: as_string(record.username || record.user || "root")
        };
        if (as_string(record.password || "") != "")
            outbound.password = as_string(record.password);
        if (as_string(record["private-key"] || record.private_key || "") != "")
            outbound.private_key = as_string(record["private-key"] || record.private_key);
        if (as_string(record["client-version"] || record.client_version || "") != "")
            outbound.client_version = as_string(record["client-version"] || record.client_version);
        return outbound;
    }
    if (proxy_type == "openconnect" || proxy_type == "anyconnect") {
        let outbound = {
            type: "openconnect",
            tag: name,
            server: server,
            server_port: port,
            flavor: as_string(record.flavor || "anyconnect")
        };
        if (as_string(record.username || "") != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password || "") != "")
            outbound.password = as_string(record.password);
        if (as_string(record.cookie || "") != "")
            outbound.cookie = as_string(record.cookie);
        options.always = true;
        add_clash_tls(outbound, options);
        return outbound;
    }
    return null;
}

function normalize_clash_yaml(input_file, output_file) {
    let outbounds = [];
    let skipped = 0;

    for (let record in clash_yaml_records(input_file)) {
        let outbound = parse_clash_record(record);
        if (outbound) {
            if (outbound_is_unsupported_stub(outbound)) {
                skipped++;
                continue;
            }
            push(outbounds, outbound);
        }
        else
            skipped++;
    }

    if (length(outbounds) == 0) {
        fs.unlink(output_file);
        return false;
    }

    return write_json_file(output_file, {
        version: 1,
        format: "clash-yaml",
        skipped: skipped,
        outbounds: outbounds
    });
}

function normalize_uri_list_data(data, output_file) {
    data = as_string(data);
    if (index(data, "\r") >= 0)
        data = replace(data, /\r/g, "");

    let output = fs.open(output_file, "w");
    if (!output)
        return false;

    let added = 0;
    let skipped = 0;
    output.write("{\"version\":1,\"format\":\"uri-list\",\"outbounds\":[");

    for (let line in split(data, "\n")) {
        if (index(line, "\r") >= 0)
            line = replace(line, /\r/g, "");
        line = trim(line);
        if (line != "" && !starts_with(line, "#")) {
            if (happ.is_encrypted(line)) {
                let decrypted = happ.decrypt(line);
                if (decrypted != null && decrypted != "") {
                    for (let dec_line in split(decrypted, "\n")) {
                        dec_line = trim(dec_line);
                        if (dec_line != "" && !starts_with(dec_line, "#")) {
                            let outbound = parse_share_link(dec_line);
                            if (outbound) {
                                if (outbound_is_unsupported_stub(outbound)) {
                                    skipped++;
                                    continue;
                                }
                                if (added > 0)
                                    output.write(",");
                                output.write(sprintf("%J", outbound));
                                added++;
                            } else {
                                skipped++;
                            }
                        }
                    }
                    continue;
                }
            }
            let outbound = parse_share_link(line);
            if (outbound) {
                if (outbound_is_unsupported_stub(outbound)) {
                    skipped++;
                    continue;
                }
                if (added > 0)
                    output.write(",");
                output.write(sprintf("%J", outbound));
                added++;
            }
            else {
                skipped++;
            }
        }
    }

    output.write("],\"skipped\":" + skipped + "}\n");
    output.close();

    if (added == 0) {
        fs.unlink(output_file);
        return false;
    }
    return true;
}

let metadata_allowed_keys = {
    "profile-title": true,
    "subscription-userinfo": true,
    "profile-web-page-url": true,
    "support-url": true,
    "announce": true,
    "announce-url": true,
    "subscription-refill-date": true,
    "content-disposition": true
};

function metadata_new_store() {
    return {
        values: {},
        seen: {},
        order: []
    };
}

function write_metadata_compact_json(store) {
    print("{");
    for (let i = 0; i < length(store.order); i++) {
        let key = store.order[i];
        if (i > 0)
            print(",");
        print(sprintf("%J", key), ":", sprintf("%J", store.values[key]));
    }
    print("}\n");
}

function add_metadata_entry(store, key, value) {
    key = lc(trim(key));
    value = replace(trim(value), /\r/g, "");
    if (!metadata_allowed_keys[key] || value == "")
        return;

    if (!store.seen[key]) {
        push(store.order, key);
        store.seen[key] = true;
    }
    store.values[key] = value;
}

function parse_metadata_line(store, line) {
    line = trim(line);
    let colon = index(line, ":");
    if (colon <= 0)
        return;

    add_metadata_entry(store, substr(line, 0, colon), substr(line, colon + 1));
}

function metadata_headers_store(input_file) {
    let data = read_file(input_file);
    let store = metadata_new_store();

    if (data != null) {
        for (let line in split(data, "\n"))
            parse_metadata_line(store, line);
    }

    return store;
}

function metadata_headers_json(input_file) {
    write_metadata_compact_json(metadata_headers_store(input_file));
    return true;
}

function metadata_body_store_from_data(data) {
    let store = metadata_new_store();
    let line_no = 0;

    if (data != null) {
        for (let line in split(data, "\n")) {
            line_no++;
            if (line_no > 20)
                break;

            line = trim(line);
            if (starts_with(line, "#"))
                line = replace(line, /^#[ \t]*/g, "");
            else if (starts_with(line, "//"))
                line = replace(line, /^\/\/[ \t]*/g, "");
            else
                continue;

            parse_metadata_line(store, line);
        }
    }

    return store;
}

function metadata_body_store(input_file) {
    return metadata_body_store_from_data(read_file(input_file));
}

function metadata_body_store_with_base64_fallback(input_file) {
    let store = metadata_body_store(input_file);
    if (length(store.order) > 0)
        return store;

    let data = read_file(input_file);
    if (data == null)
        return store;

    let decoded = base64_decode(replace(as_string(data), /[\r\n\t ]/g, ""));
    if (decoded == null || decoded == "")
        return store;

    return metadata_body_store_from_data(decoded);
}

function metadata_body_json(input_file) {
    write_metadata_compact_json(metadata_body_store(input_file));
    return true;
}

function metadata_trim_text(value) {
    return trim(as_string(value));
}

function hex_val(ch) {
    let code = ord(ch);
    if (code >= 48 && code <= 57) return code - 48;
    if (code >= 65 && code <= 70) return code - 55;
    if (code >= 97 && code <= 102) return code - 87;
    return 0;
}

function hex_to_int(str) {
    if (length(str) < 2) return 0;
    return (hex_val(substr(str, 0, 1)) << 4) | hex_val(substr(str, 1, 1));
}

function decode_url_component(str) {
    str = as_string(str);
    str = replace(str, /\+/g, " ");
    return replace(str, /%([0-9A-Fa-f]{2})/g, function(match, hex) {
        return chr(hex_to_int(hex));
    });
}

function decode_rfc2047(val) {
    val = as_string(val);
    let m = match(val, /^=\?([^?]+)\?([BbQq])\?([^?]+)\?=$/);
    if (m) {
        let encoding = lc(m[2]);
        let data = m[3];
        if (encoding == "b") {
            let decoded = base64_decode(data);
            if (decoded != null) return decoded;
        } else if (encoding == "q") {
            let qdecoded = replace(data, /_/g, " ");
            qdecoded = replace(qdecoded, /=([0-9A-Fa-f]{2})/g, function(full, hex) {
                return chr(hex_to_int(hex));
            });
            return qdecoded;
        }
    }
    return val;
}

function metadata_clean_text(value, max, decode_base64, allow_newlines) {
    value = as_string(value);
    if (starts_with(value, "=?"))
        value = decode_rfc2047(value);
    if (decode_base64 && lc(substr(value, 0, 7)) == "base64:") {
        let raw_val = substr(value, 7);
        let decoded = base64_decode(raw_val);
        if (decoded != null && length(decoded) > 0 && match(decoded, /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/) == null) {
            value = decoded;
        } else {
            value = raw_val;
        }
    }
    if (index(value, "%") >= 0) {
        value = decode_url_component(value);
    }

    let cleaned = "";
    if (allow_newlines) {
        let norm = replace(replace(value, /\r\n/g, "\n"), /\r/g, "\n");
        norm = replace(norm, /[\x01-\x09\x0b-\x1f\x7f]+/g, " ");
        let lines = [];
        for (let line in split(norm, "\n")) {
            let cl = trim(replace(line, / +/g, " "));
            if (cl != "")
                push(lines, cl);
        }
        cleaned = join("\n", lines);
    } else {
        cleaned = trim(replace(replace(value, /[\x01-\x1f\x7f]+/g, " "), / +/g, " "));
    }
    if (cleaned == "")
        return null;
    return length(cleaned) > max ? substr(cleaned, 0, max) : cleaned;
}

function metadata_has_control_or_space(value) {
    return match(as_string(value), /[\x01-\x20\x7f]/) != null;
}

function metadata_clean_url(value) {
    let cleaned = metadata_trim_text(value);
    if (cleaned == "" || length(cleaned) > 2048)
        return null;
    if (!starts_with(cleaned, "http://") && !starts_with(cleaned, "https://"))
        return null;
    return metadata_has_control_or_space(cleaned) ? null : cleaned;
}

function metadata_clean_number(value) {
    value = metadata_trim_text(value);
    if (value == "" || value == null)
        return null;
    return match(value, /^[0-9]+$/) != null ? value : null;
}

function metadata_replace_path_separators(value) {
    return replace(as_string(value), /[\/\\]/g, "_");
}

function metadata_content_disposition_filename(value) {
    value = as_string(value);
    let filename = null;

    let pos_ext = index(value, "filename*=");
    if (pos_ext >= 0) {
        let rest = substr(value, pos_ext + 10);
        let semicolon = index(rest, ";");
        let ext_val = semicolon >= 0 ? substr(rest, 0, semicolon) : rest;
        ext_val = trim(ext_val);
        let quote = index(ext_val, "''");
        if (quote >= 0) {
            filename = decode_url_component(substr(ext_val, quote + 2));
        } else {
            filename = decode_url_component(ext_val);
        }
    }

    if (filename == null) {
        let quoted_marker = "filename=\"";
        let quoted_pos = index(value, quoted_marker);
        if (quoted_pos >= 0) {
            let rest = substr(value, quoted_pos + length(quoted_marker));
            let quote_end = index(rest, "\"");
            filename = quote_end >= 0 ? substr(rest, 0, quote_end) : rest;
        }
        else {
            let marker = "filename=";
            let pos = index(value, marker);
            if (pos >= 0) {
                let rest = substr(value, pos + length(marker));
                let semicolon = index(rest, ";");
                filename = semicolon >= 0 ? substr(rest, 0, semicolon) : rest;
                if (length(filename) > 0 && substr(filename, 0, 1) == "\"")
                    filename = substr(filename, 1);
                if (length(filename) > 0 && substr(filename, length(filename) - 1) == "\"")
                    filename = substr(filename, 0, length(filename) - 1);
            }
        }
    }

    if (filename == null)
        return null;

    filename = metadata_clean_text(filename, 120, false);
    if (filename == null)
        return null;

    filename = metadata_replace_path_separators(filename);
    return filename == "" ? null : filename;
}

function metadata_number_value(value) {
    return value == null ? 0 : int(value, 10);
}

function metadata_parse_userinfo(value) {
    let result = {};

    for (let item in split(as_string(value), ";")) {
        item = trim(item);
        let equals = index(item, "=");
        if (equals < 0)
            continue;

        let key = lc(trim(substr(item, 0, equals)));
        let number = metadata_clean_number(substr(item, equals + 1));
        if (number == null)
            continue;

        if (key == "upload" || key == "download" || key == "total" || key == "expire")
            result[key] = number;
    }

    return result;
}

function metadata_ui_object(raw) {
    raw = object_or_empty(raw);

    let title = metadata_clean_text(raw["profile-title"], 120, true);
    let web_page_url = metadata_clean_url(raw["profile-web-page-url"]);
    let support_url = metadata_clean_url(raw["support-url"]);
    let announce = metadata_clean_text(raw["announce"], 500, true, true);
    let announce_url = metadata_clean_url(raw["announce-url"]);
    let refill_date = metadata_clean_number(raw["subscription-refill-date"]);
    let file_name = metadata_content_disposition_filename(raw["content-disposition"]);
    let userinfo = metadata_parse_userinfo(raw["subscription-userinfo"]);

    let upload = userinfo.upload;
    let download = userinfo.download;
    let total = userinfo.total;
    let expire = userinfo.expire;
    let has_traffic = upload != null || download != null || total != null || expire != null;
    let used = metadata_number_value(upload) + metadata_number_value(download);
    let total_value = metadata_number_value(total);

    let result = { version: 1 };
    if (title != null)
        result.title = title;
    if (has_traffic) {
        let traffic = {
            used: used,
            isUnlimited: !(total != null && total_value > 0)
        };
        if (upload != null)
            traffic.upload = metadata_number_value(upload);
        if (download != null)
            traffic.download = metadata_number_value(download);
        if (total != null && total_value > 0) {
            traffic.total = total_value;
            let remaining = total_value - used;
            traffic.remaining = remaining < 0 ? 0 : remaining;
        }
        result.traffic = traffic;
    }
    if (expire != null && metadata_number_value(expire) > 0)
        result.expire = metadata_number_value(expire);
    if (refill_date != null && metadata_number_value(refill_date) > 0)
        result.refillDate = metadata_number_value(refill_date);
    if (web_page_url != null)
        result.webPageUrl = web_page_url;
    if (support_url != null)
        result.supportUrl = support_url;
    if (announce != null)
        result.announce = announce;
    if (announce_url != null)
        result.announceUrl = announce_url;
    if (file_name != null)
        result.fileName = file_name;

    return result;
}

function metadata_ui_json(raw_path) {
    let result = metadata_ui_object(read_json_file(raw_path));
    if (length(keys(result)) > 1)
        write_json(result);
    return true;
}

function metadata_extract_ui_json(headers_file, body_file) {
    let raw = metadata_body_store_with_base64_fallback(body_file).values;
    let headers = metadata_headers_store(headers_file).values;
    for (let key, value in headers)
        raw[key] = value;

    let result = metadata_ui_object(raw);
    if (length(keys(result)) > 1)
        write_json(result);
    return true;
}

function is_metadata_preamble_line(line) {
    let trimmed = trim(line);
    let m = match(trimmed, /^(#|\/\/)[ \t]*([A-Za-z0-9][A-Za-z0-9_-]*)[ \t]*:/);
    return m && metadata_allowed_keys[lc(m[2])];
}

function normalize_uri_list_stream(input, output_file, strip_metadata) {
    let output = fs.open(output_file, "w");
    if (!output)
        return false;

    let added = 0;
    let skipped = 0;
    let line_no = 0;
    output.write("{\"version\":1,\"format\":\"uri-list\",\"outbounds\":[");

    while (true) {
        let line = input.read("line");
        if (line == null)
            break;
        line_no++;
        line = trim(line);
        if (strip_metadata && line_no <= 20 && is_metadata_preamble_line(line))
            continue;
        if (line != "" && !starts_with(line, "#")) {
            if (happ.is_encrypted(line)) {
                let decrypted = happ.decrypt(line);
                if (decrypted != null && decrypted != "") {
                    for (let dec_line in split(decrypted, "\n")) {
                        dec_line = trim(dec_line);
                        if (dec_line != "" && !starts_with(dec_line, "#")) {
                            let outbound = parse_share_link(dec_line);
                            if (outbound) {
                                if (outbound_is_unsupported_stub(outbound)) {
                                    skipped++;
                                    continue;
                                }
                                if (added > 0)
                                    output.write(",");
                                output.write(sprintf("%J", outbound));
                                added++;
                            } else {
                                skipped++;
                            }
                        }
                    }
                    continue;
                }
            }
            let outbound = parse_share_link(line);
            if (outbound) {
                if (outbound_is_unsupported_stub(outbound)) {
                    skipped++;
                    continue;
                }
                if (added > 0)
                    output.write(",");
                output.write(sprintf("%J", outbound));
                added++;
            }
            else {
                skipped++;
            }
        }
    }

    output.write("],\"skipped\":" + skipped + "}\n");
    output.close();

    if (added == 0) {
        fs.unlink(output_file);
        return false;
    }
    return true;
}

function file_looks_like_uri_list(input_file) {
    let input = fs.open(input_file, "r");
    if (!input)
        return false;

    let line_no = 0;
    while (line_no < 200) {
        let line = input.read("line");
        if (line == null)
            break;
        line_no++;
        line = trim(line);
        if (line == "" || starts_with(line, "#") || is_metadata_preamble_line(line))
            continue;
        if (happ.is_encrypted(line)) {
            input.close();
            return false;
        }
        if (is_supported_share_link(line)) {
            input.close();
            return true;
        }
        if (substr(line, 0, 1) == "{" || substr(line, 0, 1) == "[" || index(line, "proxies:") >= 0) {
            input.close();
            return false;
        }
    }

    input.close();
    return false;
}

function normalize_uri_list_file(input_file, output_file, strip_metadata) {
    let input = fs.open(input_file, "r");
    if (!input)
        return false;
    let ok = normalize_uri_list_stream(input, output_file, strip_metadata);
    input.close();
    return ok;
}

function normalize_uri_list(input_file, output_file) {
    return normalize_uri_list_file(input_file, output_file, false);
}

function strip_metadata_preamble_data(data) {
    data = as_string(data);
    let offset = 0;
    let changed = false;

    for (let line_no = 1; line_no <= 20 && offset <= length(data); line_no++) {
        let rest = substr(data, offset);
        let newline_pos = index(rest, "\n");
        let line = newline_pos >= 0 ? substr(rest, 0, newline_pos) : rest;
        if (is_metadata_preamble_line(line)) {
            changed = true;
            break;
        }
        if (newline_pos < 0)
            break;
        offset += newline_pos + 1;
    }

    if (!changed)
        return data;

    let result = [];
    let line_no = 0;

    for (let line in split(data, "\n")) {
        line_no++;
        let text = replace(line, /\r$/g, "");
        if (line_no <= 20) {
            if (is_metadata_preamble_line(text))
                continue;
        }
        push(result, text);
    }

    return join("\n", result);
}

function content_is_clash_yaml(data) {
    for (let line in split(data, "\n")) {
        if (match(line, /^[ \t]*proxies:[ \t]*(#.*)?$/))
            return true;
    }
    return false;
}

function xray_first_array_object(value) {
    value = array_or_empty(value);
    return length(value) > 0 && type(value[0]) == "object" ? value[0] : {};
}

function xray_first_string(values) {
    for (let value in values) {
        value = as_string(value);
        if (value != "")
            return value;
    }
    return "";
}

function xray_valid_port_value(value) {
    let value_type = type(value);
    if (value_type == "int" || value_type == "double")
        return valid_port(value) ? int(value) : null;

    value = as_string(value);
    if (!is_integer_string(value))
        return null;

    let port = int(value, 10);
    return valid_port(port) ? port : null;
}

function xray_alpn(value) {
    if (type(value) == "array")
        return value;

    let text = as_string(value);
    return text != "" ? split_csv(text) : [];
}

function xray_add_utls(tls, fingerprint) {
    fingerprint = normalize_utls_fingerprint(fingerprint);
    if (fingerprint != "")
        tls.utls = { enabled: true, fingerprint: fingerprint };
}

function xray_tls_from_stream(stream, network) {
    stream = object_or_empty(stream);
    let security = lc(as_string(stream.security || ""));
    let reality = object_or_empty(stream.realitySettings);
    let tls_settings = object_or_empty(stream.tlsSettings);
    let settings = security == "reality" ? reality : tls_settings;

    if (security != "tls" && security != "xtls" && security != "reality" && length(keys(settings)) == 0)
        return null;

    let tls = { enabled: true };
    let server_name = xray_first_string([settings.serverName, settings.server_name, settings.sni]);
    let alpn = tls_alpn_for_transport(xray_alpn(settings.alpn), network);
    if (server_name != "")
        tls.server_name = server_name;
    if (is_true(settings.allowInsecure) || is_true(settings.insecure))
        tls.insecure = true;
    if (length(alpn) > 0)
        tls.alpn = alpn;

    xray_add_utls(tls, settings.fingerprint || settings.fp || "");

    // The Xray spelling of the pin. Without it a node whose certificate fails CA
    // or name validation loses its pin the moment auto_user_agent makes the
    // provider answer with Xray-JSON instead of a link list - and the node simply
    // does not connect, with nothing in the log.
    let certificate_pin = common.certificate_pin_base64(
        settings.pinnedPeerCertSha256 || settings.pinned_peer_cert_sha256 || ""
    );
    if (certificate_pin != "")
        tls.certificate_sha256 = [ certificate_pin ];

    if (security == "reality" || length(keys(reality)) > 0) {
        tls.reality = { enabled: true };
        let public_key = xray_first_string([reality.publicKey, reality.public_key, settings.publicKey, settings.public_key]);
        let short_id = xray_first_string([reality.shortId, reality.short_id, settings.shortId, settings.short_id]);
        if (public_key != "")
            tls.reality.public_key = public_key;
        if (short_id != "")
            tls.reality.short_id = short_id;
        let mlkem_pref = reality.support_x25519mlkem768;
        if (mlkem_pref == null)
            mlkem_pref = reality.supportX25519MLKEM768;
        if (mlkem_pref == null)
            mlkem_pref = reality["support-x25519mlkem768"];
        if (mlkem_pref == null)
            mlkem_pref = settings.support_x25519mlkem768;
        if (mlkem_pref == null)
            mlkem_pref = settings.supportX25519MLKEM768;
        if (mlkem_pref == null)
            mlkem_pref = settings["support-x25519mlkem768"];
        if (mlkem_pref == null && xray_first_string([reality.mldsa65Verify, reality.pqv, settings.mldsa65Verify, settings.pqv]) != "")
            mlkem_pref = true;
        if (mlkem_pref != null)
            tls.reality.support_x25519mlkem768 = is_true(mlkem_pref);
        if (!tls.utls)
            tls.utls = { enabled: true, fingerprint: "chrome" };
    }
    if (is_true(settings.fragment || settings.tls_fragment) ||
        finalmask_has_tcp_fragment(stream.finalmask))
        tls.fragment = true;

    return tls;
}

function xray_transport_from_stream(stream) {
    stream = object_or_empty(stream);
    let network = lc(as_string(stream.network || ""));
    if (network == "" || network == "tcp")
        return null;

    if (network == "ws") {
        let settings = object_or_empty(stream.wsSettings);
        let headers = object_or_empty(settings.headers);
        let result = { type: "ws", path: as_string(settings.path || "/") };
        let host = as_string(headers.Host || headers.host || "");
        if (host != "")
            result.headers = { Host: host };
        return result;
    }

    if (network == "grpc") {
        let settings = object_or_empty(stream.grpcSettings);
        let result = { type: "grpc" };
        if (as_string(settings.serviceName || settings.service_name || "") != "")
            result.service_name = as_string(settings.serviceName || settings.service_name);
        return result;
    }

    if (network == "http" || network == "h2") {
        let settings = object_or_empty(stream.httpSettings);
        let result = { type: "http" };
        if (type(settings.path) == "array" && length(settings.path) > 0)
            result.path = as_string(settings.path[0]);
        else if (as_string(settings.path || "") != "")
            result.path = as_string(settings.path);
        if (type(settings.host) == "array")
            result.host = settings.host;
        else if (as_string(settings.host || "") != "")
            result.host = split_csv(settings.host);
        return result;
    }

    if (network == "httpupgrade") {
        let settings = object_or_empty(stream.httpupgradeSettings);
        let result = { type: "httpupgrade" };
        if (as_string(settings.path || "") != "")
            result.path = as_string(settings.path);
        if (as_string(settings.host || "") != "")
            result.host = as_string(settings.host);
        return result;
    }

    if (network == "xhttp") {
        let settings = object_or_empty(stream.xhttpSettings);
        let extra_settings = {};
        xhttp_merge_extra_settings(extra_settings, settings);
        let result = {
            type: "xhttp",
            mode: as_string(settings.mode || "auto"),
            path: as_string(settings.path || "/"),
            x_padding_bytes: "100-1000",
            no_grpc_header: false,
            sc_max_each_post_bytes: "1000000",
            sc_min_posts_interval_ms: "30"
        };
        if (result.mode != "auto" && result.mode != "packet-up" && result.mode != "stream-up" && result.mode != "stream-one")
            result.mode = "auto";
        if (as_string(settings.host || "") != "")
            result.host = as_string(settings.host);
        xhttp_optional_positive_range(result, "x_padding_bytes", xhttp_setting_value(settings, extra_settings, "xPaddingBytes", "x_padding_bytes"));
        xhttp_optional_bool(result, "no_grpc_header", xhttp_setting_value(settings, extra_settings, [ "noGRPCHeader", "noGrpcHeader" ], "no_grpc_header"));
        xhttp_optional_positive_range(result, "sc_max_each_post_bytes", xhttp_setting_value(settings, extra_settings, "scMaxEachPostBytes", "sc_max_each_post_bytes"));
        xhttp_optional_range(result, "sc_min_posts_interval_ms", xhttp_setting_value(settings, extra_settings, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"));
        xhttp_optional_range(result, "sc_stream_up_server_secs", xhttp_setting_value(settings, extra_settings, "scStreamUpServerSecs", "sc_stream_up_server_secs"));
        let xmux = xhttp_normalize_xmux(xhttp_setting_value(settings, extra_settings, "xmux", "xmux"));
        if (xmux)
            result.xmux = xmux;
        xhttp_apply_v2_settings(result, settings, extra_settings);
        return result;
    }

    return null;
}

function xray_display_name(original_tag) {
    original_tag = as_string(original_tag);
    return original_tag;
}

function xray_config_display_name(config, fallback) {
    let name = xray_first_string([config.remarks, config.remark, config.name, config.ps]);
    return name != "" ? name : fallback;
}

function xray_source_tag(outbound, fallback) {
    let tag = as_string(outbound.tag || "");
    return tag != "" ? tag : fallback;
}

function xray_unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;

    for (let suffix = 1; suffix < 100000; suffix++) {
        let candidate = base + "-" + suffix;
        if (!taken[candidate])
            return candidate;
    }

    return base + "-overflow";
}

function xray_tag_base(original_tag, config_index, config_count) {
    original_tag = as_string(original_tag);
    if (original_tag == "")
        original_tag = "server";
    return original_tag;
}

function xray_protocol_supported(protocol) {
    protocol = lc(as_string(protocol));
    return protocol == "vless" || protocol == "vmess" || protocol == "trojan" ||
        protocol == "shadowsocks" || protocol == "ss" || protocol == "socks" ||
        protocol == "http" || protocol == "hysteria" || protocol == "hysteria2" ||
        protocol == "hy2";
}

function xray_apply_stream_tls_transport(result, outbound) {
    let stream = object_or_empty(outbound.streamSettings);
    let transport = xray_transport_from_stream(stream);
    let tls = xray_tls_from_stream(stream, lc(as_string(stream.network || "")));
    if (tls)
        result.tls = tls;
    if (transport)
        result.transport = transport;
    return result;
}

function convert_xray_vless(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let vnext = xray_first_array_object(settings.vnext);
    let user = xray_first_array_object(vnext.users);
    let server = as_string(vnext.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(vnext.port != null ? vnext.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    let uuid = as_string(user.id || outbound.uuid || outbound.id || settings.id || "");
    if (server == "" || is_dummy_server(server, port) || port == null || uuid == "")
        return null;

    let result = {
        type: "vless",
        tag: tag,
        server: server,
        server_port: port,
        uuid: uuid
    };

    let flow = normalize_vless_flow(user.flow || outbound.flow || settings.flow || "");
    if (flow == null)
        return null;
    if (flow != "")
        result.flow = flow;
    let encryption = normalize_vless_encryption(user.encryption || outbound.encryption || settings.encryption || "");
    if (encryption != "")
        result.encryption = encryption;

    return xray_apply_stream_tls_transport(result, outbound);
}

function convert_xray_vmess(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let vnext = xray_first_array_object(settings.vnext);
    let user = xray_first_array_object(vnext.users);
    let server = as_string(vnext.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(vnext.port != null ? vnext.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    let uuid = as_string(user.id || outbound.uuid || outbound.id || settings.id || "");
    if (server == "" || is_dummy_server(server, port) || port == null || uuid == "")
        return null;

    let security = as_string(user.security || outbound.security || settings.security || "auto");
    let result = {
        type: "vmess",
        tag: tag,
        server: server,
        server_port: port,
        uuid: uuid,
        security: security != "" ? security : "auto"
    };

    let alter_id = user.alterId != null ? user.alterId : (outbound.alter_id != null ? outbound.alter_id : (outbound.alterId != null ? outbound.alterId : (settings.alterId != null ? settings.alterId : settings.alter_id)));
    if (alter_id != null && as_string(alter_id) != "")
        result.alter_id = int(alter_id);

    return xray_apply_stream_tls_transport(result, outbound);
}

function convert_xray_trojan(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let srv = xray_first_array_object(settings.servers);
    let server = as_string(srv.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(srv.port != null ? srv.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    let password = as_string(srv.password || outbound.password || settings.password || "");
    if (server == "" || is_dummy_server(server, port) || port == null || password == "")
        return null;

    let result = {
        type: "trojan",
        tag: tag,
        server: server,
        server_port: port,
        password: password
    };

    return xray_apply_stream_tls_transport(result, outbound);
}

function convert_xray_shadowsocks(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let srv = xray_first_array_object(settings.servers);
    let server = as_string(srv.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(srv.port != null ? srv.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    let method = normalize_shadowsocks_method(srv.method || srv.cipher || outbound.method || outbound.cipher || settings.method || settings.cipher || "");
    let password = as_string(srv.password || outbound.password || settings.password || "");
    if (server == "" || is_dummy_server(server, port) || port == null || !valid_shadowsocks_password(method, password))
        return null;

    let result = {
        type: "shadowsocks",
        tag: tag,
        server: server,
        server_port: port,
        method: method,
        password: password
    };

    let plugin = as_string(srv.plugin || outbound.plugin || settings.plugin || "");
    let plugin_opts = as_string(srv.pluginOpts || srv.plugin_opts || outbound.plugin_opts || outbound.pluginOpts || settings.pluginOpts || settings.plugin_opts || "");
    if (plugin != "")
        result.plugin = plugin;
    if (plugin_opts != "")
        result.plugin_opts = plugin_opts;

    let stream = object_or_empty(outbound.streamSettings);
    let transport = xray_transport_from_stream(stream);
    let tls = xray_tls_from_stream(stream, lc(as_string(stream.network || "")));
    if (transport != null && transport.type == "ws" && result.plugin == null) {
        result.plugin = "v2ray-plugin";
        let opts = [ "mode=websocket" ];
        if (tls != null && tls.enabled === true) {
            push(opts, "tls");
            if (as_string(tls.server_name || "") != "")
                push(opts, "host=" + as_string(tls.server_name));
        }
        let ws_host = as_string(object_or_empty(transport.headers).Host || object_or_empty(transport.headers).host || "");
        if (ws_host != "" && (tls == null || as_string(tls.server_name || "") == ""))
            push(opts, "host=" + ws_host);
        else if (ws_host != "" && tls != null && as_string(tls.server_name || "") != "" && ws_host != as_string(tls.server_name)) {
            let filtered = [];
            for (let item in opts) {
                if (substr(item, 0, 5) != "host=")
                    push(filtered, item);
            }
            opts = filtered;
            push(opts, "host=" + ws_host);
        }
        let ws_path = as_string(transport.path || "/");
        if (ws_path != "")
            push(opts, "path=" + ws_path);
        result.plugin_opts = join(";", opts);
    } else {
        if (tls)
            result.tls = tls;
        if (transport)
            result.transport = transport;
    }

    if (is_true(srv.uot || outbound.uot || outbound.udp_over_tcp || settings.uot))
        result.udp_over_tcp = true;

    return result;
}

function convert_xray_socks(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let server_config = xray_first_array_object(settings.servers);
    let server = as_string(server_config.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(server_config.port != null ? server_config.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    if (server == "" || is_dummy_server(server, port) || port == null)
        return null;

    let result = {
        type: "socks",
        tag: tag,
        server: server,
        server_port: port,
        version: "5"
    };

    let user = xray_first_array_object(server_config.users);
    let username = as_string(user.user || outbound.username || settings.user || "");
    let password = as_string(user.pass || user.password || outbound.password || settings.pass || settings.password || "");
    if (username != "")
        result.username = username;
    if (password != "")
        result.password = password;

    return result;
}

function convert_xray_http(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let server_config = xray_first_array_object(settings.servers);
    let server = as_string(server_config.address || outbound.server || outbound.address || settings.address || "");
    let port = xray_valid_port_value(server_config.port != null ? server_config.port : (outbound.server_port != null ? outbound.server_port : (outbound.port != null ? outbound.port : settings.port)));
    if (server == "" || is_dummy_server(server, port) || port == null)
        return null;

    let result = {
        type: "http",
        tag: tag,
        server: server,
        server_port: port
    };

    let user = xray_first_array_object(server_config.users);
    let username = as_string(user.user || outbound.username || settings.user || "");
    let password = as_string(user.pass || user.password || outbound.password || settings.pass || settings.password || "");
    if (username != "")
        result.username = username;
    if (password != "")
        result.password = password;

    let stream = object_or_empty(outbound.streamSettings);
    let tls = xray_tls_from_stream(stream, lc(as_string(stream.network || "")));
    if (tls)
        result.tls = tls;

    return result;
}

function convert_xray_hysteria2(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let stream = object_or_empty(outbound.streamSettings);
    let hysteria_settings = object_or_empty(stream.hysteriaSettings);
    let protocol = lc(as_string(outbound.protocol || ""));
    let version = int(settings.version || hysteria_settings.version || (protocol == "hysteria2" || protocol == "hy2" ? 2 : 0));
    if (version != 2)
        return null;

    let server = as_string(settings.address || settings.server || outbound.server || outbound.address || "");
    let port = xray_valid_port_value(settings.port != null ? settings.port : (outbound.server_port != null ? outbound.server_port : outbound.port));
    let password = as_string(hysteria_settings.auth || settings.auth || settings.password || outbound.password || "");
    if (server == "" || is_dummy_server(server, port) || port == null || password == "")
        return null;

    let result = {
        type: "hysteria2",
        tag: tag,
        server: server,
        server_port: port,
        password: password,
        tls: { enabled: true }
    };

    let tls_settings = object_or_empty(stream.tlsSettings);
    let server_name = xray_first_string([tls_settings.serverName, tls_settings.server_name, tls_settings.sni]);
    if (server_name != "")
        result.tls.server_name = server_name;
    if (is_true(tls_settings.allowInsecure) || is_true(tls_settings.insecure))
        result.tls.insecure = true;
    let alpn = xray_alpn(tls_settings.alpn);
    if (length(alpn) > 0)
        result.tls.alpn = alpn;

    // Xray keeps the hysteria2 obfuscation out of hysteriaSettings and hangs it
    // off streamSettings.finalmask instead. Dropping it means the salamander or
    // gecko handshake is never sent, the server discards every QUIC packet and
    // the node reports as unreachable.
    let finalmask = object_or_empty(stream.finalmask);
    let quic_params = object_or_empty(finalmask.quicParams);
    let mask_udp = finalmask.udp;
    let mask_entries = type(mask_udp) == "array"
        ? mask_udp
        : (type(mask_udp) == "object" ? [ mask_udp ] : []);
    let obfs_pw = "";
    let is_gecko = false;
    let min_ps = 0;
    let max_ps = 0;
    let fm_hop_obj = null;

    for (let entry in mask_entries) {
        if (type(entry) != "object")
            continue;
        let utype = lc(as_string(entry.type || "salamander"));
        let u_set = object_or_empty(entry.settings);
        if (utype == "salamander" || utype == "gecko") {
            if (utype == "gecko" || lc(as_string(u_set.mode || entry.mode || "")) == "gecko")
                is_gecko = true;
            let pw = as_string(u_set.password || entry.password || "");
            if (pw != "")
                obfs_pw = pw;
            let ps = parse_hysteria2_packet_size_value(u_set.packetSize != null ? u_set.packetSize : (u_set.packet_size != null ? u_set.packet_size : (entry.packetSize != null ? entry.packetSize : entry.packet_size)));
            if (ps != null) {
                min_ps = ps[0];
                max_ps = ps[1];
            }
            let lo = xhttp_positive_integer_value(u_set.minPacketSize != null ? u_set.minPacketSize : (u_set.min_packet_size != null ? u_set.min_packet_size : (entry.minPacketSize != null ? entry.minPacketSize : entry.min_packet_size)));
            if (lo != null)
                min_ps = lo;
            let hi = xhttp_positive_integer_value(u_set.maxPacketSize != null ? u_set.maxPacketSize : (u_set.max_packet_size != null ? u_set.max_packet_size : (entry.maxPacketSize != null ? entry.maxPacketSize : entry.max_packet_size)));
            if (hi != null)
                max_ps = hi;
        } else if (utype == "udphop" || utype == "udp_hop") {
            fm_hop_obj = length(keys(u_set)) > 0 ? u_set : entry;
        }
    }

    if (obfs_pw == "") {
        for (let src in [ hysteria_settings, settings ]) {
            if (type(src) != "object")
                continue;
            if (type(src.obfs) == "object") {
                let o_obj = src.obfs;
                if (lc(as_string(o_obj.type || o_obj.mode || "")) == "gecko")
                    is_gecko = true;
                let ps = parse_hysteria2_packet_size_value(o_obj.packetSize != null ? o_obj.packetSize : o_obj.packet_size);
                if (ps != null) {
                    min_ps = ps[0];
                    max_ps = ps[1];
                }
                let lo = xhttp_positive_integer_value(o_obj.min_packet_size != null ? o_obj.min_packet_size : o_obj.minPacketSize);
                if (lo != null)
                    min_ps = lo;
                let hi = xhttp_positive_integer_value(o_obj.max_packet_size != null ? o_obj.max_packet_size : o_obj.maxPacketSize);
                if (hi != null)
                    max_ps = hi;
                let pw = as_string(o_obj.password || "");
                if (pw != "") {
                    obfs_pw = pw;
                    break;
                }
            } else {
                let pw = as_string(src.obfsPassword || src.obfs_password || src["obfs-password"] || "");
                if (pw != "") {
                    obfs_pw = pw;
                    break;
                }
            }
        }
    }

    if (obfs_pw != "")
        result.obfs = build_hysteria2_obfs(is_gecko, obfs_pw, min_ps, max_ps);

    let up_mbps = parse_hysteria2_mbps(quic_params.brutalUp != null ? quic_params.brutalUp : (quic_params.up != null ? quic_params.up : (hysteria_settings.up != null ? hysteria_settings.up : hysteria_settings.upMbps)));
    if (up_mbps != null)
        result.up_mbps = up_mbps;
    let down_mbps = parse_hysteria2_mbps(quic_params.brutalDown != null ? quic_params.brutalDown : (quic_params.down != null ? quic_params.down : (hysteria_settings.down != null ? hysteria_settings.down : hysteria_settings.downMbps)));
    if (down_mbps != null)
        result.down_mbps = down_mbps;

    let hop_obj = type(quic_params.udpHop) == "object" ? quic_params.udpHop
        : (type(quic_params.udphop) == "object" ? quic_params.udphop
        : (type(hysteria_settings.udphop) == "object" ? hysteria_settings.udphop
        : (type(hysteria_settings.udpHop) == "object" ? hysteria_settings.udpHop : fm_hop_obj)));
    if (type(hop_obj) == "object") {
        let hop_ports = parse_hysteria2_server_ports(as_string(hop_obj.ports || hop_obj.port || ""));
        if (hop_ports != null)
            result.server_ports = hop_ports;
        let hop_iv = normalize_hysteria2_hop_interval(hop_obj.interval);
        if (hop_iv != "")
            result.hop_interval = hop_iv;
    }

    return result;
}

function convert_xray_outbound(outbound, tag) {
    let protocol = lc(as_string(outbound.protocol || ""));
    if (protocol == "vless")
        return convert_xray_vless(outbound, tag);
    if (protocol == "vmess")
        return convert_xray_vmess(outbound, tag);
    if (protocol == "trojan")
        return convert_xray_trojan(outbound, tag);
    if (protocol == "shadowsocks" || protocol == "ss")
        return convert_xray_shadowsocks(outbound, tag);
    if (protocol == "socks")
        return convert_xray_socks(outbound, tag);
    if (protocol == "http")
        return convert_xray_http(outbound, tag);
    if (protocol == "hysteria" || protocol == "hysteria2" || protocol == "hy2")
        return convert_xray_hysteria2(outbound, tag);
    return null;
}

function xray_outbound_detour(outbound) {
    let stream = object_or_empty(outbound.streamSettings);
    let sockopt = object_or_empty(stream.sockopt);
    if (as_string(sockopt.dialerProxy || "") != "")
        return as_string(sockopt.dialerProxy);

    sockopt = object_or_empty(outbound.sockopt);
    if (as_string(sockopt.dialerProxy || "") != "")
        return as_string(sockopt.dialerProxy);

    let proxy_settings = object_or_empty(outbound.proxySettings);
    return as_string(proxy_settings.tag || proxy_settings.Tag || "");
}

function xray_supported_source_tags(source_outbounds) {
    let result = {};
    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_protocol_supported(outbound.protocol))
            continue;

        let tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        result[tag] = true;
    }
    return result;
}

function xray_primary_source_tag(config, source_outbounds) {
    let supported_tags = xray_supported_source_tags(source_outbounds);

    for (let rule in array_or_empty(object_or_empty(config.routing).rules)) {
        let outbound_tag = as_string(object_or_empty(rule).outboundTag || "");
        if (supported_tags[outbound_tag])
            return outbound_tag;
    }

    if (supported_tags["proxy"])
        return "proxy";

    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_protocol_supported(outbound.protocol))
            continue;

        let tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        if (xray_outbound_detour(outbound) == "")
            return tag;
    }

    for (let tag in keys(supported_tags))
        return tag;

    return "";
}

function xray_balancer_selector_matches(selector, tag) {
    selector = as_string(selector);
    tag = as_string(tag);
    if (selector == "" || tag == "")
        return false;
    return tag == selector || starts_with(tag, selector + "-") || starts_with(tag, selector);
}

function xray_urltest_option_string(value) {
    value = as_string(value);
    return value != "" ? value : "";
}

function xray_config_urltest_options(config) {
    let observatory = object_or_empty(config.observatory);
    let burst_observatory = object_or_empty(config.burstObservatory || config.burst_observatory);
    let ping_config = object_or_empty(burst_observatory.pingConfig || burst_observatory.ping_config);
    let result = {};

    let url = xray_first_string([
        ping_config.destination,
        ping_config.url,
        observatory.probeURL,
        observatory.probeUrl,
        observatory.probe_url
    ]);
    if (url != "")
        result.url = url;

    let interval = xray_first_string([
        ping_config.interval,
        observatory.probeInterval,
        observatory.probe_interval
    ]);
    if (interval != "")
        result.interval = interval;

    return result;
}

function xray_apply_urltest_options(group, options) {
    options = object_or_empty(options);
    for (let key in [ "url", "interval" ]) {
        let value = xray_urltest_option_string(options[key]);
        if (value != "")
            group[key] = value;
    }
}

function xray_balancer_plans(config, source_outbounds) {
    let supported_tags = xray_supported_source_tags(source_outbounds);
    let result = [];
    let urltest_options = xray_config_urltest_options(config);

    for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
        let selectors = array_or_empty(object_or_empty(balancer).selector);
        let selected = {};
        let tags = [];
        for (let tag in keys(supported_tags)) {
            for (let selector in selectors) {
                if (xray_balancer_selector_matches(selector, tag) && !selected[tag]) {
                    selected[tag] = true;
                    push(tags, tag);
                    break;
                }
            }
        }
        if (length(tags) > 0) {
            push(result, {
                tag: as_string(object_or_empty(balancer).tag || ""),
                source_tags: tags,
                urltest_options
            });
        }
    }

    return result;
}

function xray_balancer_group_base(plan, display_name, config_index, config_count, plan_index, plan_count) {
    let balancer_tag = as_string(object_or_empty(plan).tag || "");
    display_name = as_string(display_name);
    if (plan_count == 1 && display_name != "")
        return display_name;
    if (balancer_tag != "")
        return balancer_tag;
    if (display_name != "")
        return display_name + "-" + (plan_index + 1);
    return xray_tag_base("urltest", config_index, config_count);
}

function xray_plan_config_outbounds(config, config_index, config_count, taken) {
    let source_outbounds = array_or_empty(config.outbounds);
    let planned = [];
    let tag_map = {};

    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_protocol_supported(outbound.protocol))
            continue;

        let original_tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        let tag = xray_unique_tag(xray_tag_base(original_tag, config_index, config_count), taken);
        taken[tag] = true;
        tag_map[original_tag] = tag;
        push(planned, { outbound, original_tag, tag });
    }

    return { planned, tag_map };
}

function xray_retag_planned_outbound(planned, tag_map, source_tag, new_base, config_index, config_count, taken) {
    source_tag = as_string(source_tag);
    new_base = as_string(new_base);
    if (source_tag == "" || new_base == "")
        return;

    for (let item in planned) {
        if (item.original_tag != source_tag)
            continue;

        let old_tag = as_string(item.tag || "");
        let new_tag = xray_unique_tag(new_base, taken);
        if (new_tag == old_tag)
            return;

        if (old_tag != "")
            delete taken[old_tag];
        taken[new_tag] = true;
        item.tag = new_tag;
        tag_map[source_tag] = new_tag;
        return;
    }
}

function xray_add_converted_outbound(result, item, tag_map, visible, display_name) {
    let converted = convert_xray_outbound(item.outbound, item.tag);
    if (!converted)
        return;

    if (display_name != "")
        converted.remark = display_name;
    if (!visible)
        converted.__tachyon_hidden = true;

    let detour = xray_outbound_detour(item.outbound);
    if (detour != "" && tag_map[detour])
        converted.detour = tag_map[detour];

    push(result, converted);
}

function xray_config_outbounds(config, config_index, config_count, taken) {
    let source_outbounds = array_or_empty(config.outbounds);
    let plan = xray_plan_config_outbounds(config, config_index, config_count, taken);
    let planned = array_or_empty(plan.planned);
    let tag_map = object_or_empty(plan.tag_map);
    let display_name = xray_config_display_name(config, "");
    let balancer_plans = xray_balancer_plans(config, source_outbounds);
    let visible_source_tags = {};
    let dependency_tags = {};
    let result = [];

    if (length(balancer_plans) > 0) {
        for (let plan_index = 0; plan_index < length(balancer_plans); plan_index++) {
            let plan = balancer_plans[plan_index];
            let urltest_outbounds = [];
            for (let source_tag in array_or_empty(plan.source_tags)) {
                if (tag_map[source_tag]) {
                    visible_source_tags[source_tag] = false;
                    push(urltest_outbounds, tag_map[source_tag]);
                }
            }

            if (length(urltest_outbounds) > 0) {
                let group_base = xray_balancer_group_base(plan, display_name, config_index, config_count, plan_index, length(balancer_plans));
                let group_tag = xray_unique_tag(group_base, taken);
                taken[group_tag] = true;
                let group = {
                    type: "urltest",
                    tag: group_tag,
                    outbounds: urltest_outbounds,
                    remark: group_base != "" ? group_base : group_tag,
                    __tachyon_allow_group: true
                };
                xray_apply_urltest_options(group, plan.urltest_options);
                push(result, group);
            }
        }
    } else {
        let primary_tag = xray_primary_source_tag(config, source_outbounds);
        if (primary_tag != "") {
            xray_retag_planned_outbound(planned, tag_map, primary_tag, display_name, config_index, config_count, taken);
            visible_source_tags[primary_tag] = true;
        }
    }

    for (let item in planned) {
        let detour = xray_outbound_detour(item.outbound);
        if (detour != "" && tag_map[detour])
            dependency_tags[detour] = true;
    }

    for (let item in planned) {
        let visible = visible_source_tags[item.original_tag] === true;
        let hidden = !visible;
        if (visible || dependency_tags[item.original_tag] || visible_source_tags[item.original_tag] === false) {
            let item_display_name = visible && display_name != ""
                ? display_name
                : xray_display_name(item.original_tag);
            xray_add_converted_outbound(result, item, tag_map, !hidden, item_display_name);
        }
    }

    return result;
}

function is_xray_config(value) {
    if (type(value) != "object" || type(value.outbounds) != "array")
        return false;

    for (let outbound in value.outbounds) {
        if (type(outbound) == "object" && type(outbound.protocol) == "string")
            return true;
    }

    return false;
}

function normalize_xray_configs(configs) {
    configs = array_or_empty(configs);
    let taken = {};
    let outbounds = [];

    for (let i = 0; i < length(configs); i++) {
        let config = configs[i];
        if (!is_xray_config(config))
            continue;

        for (let outbound in xray_config_outbounds(config, i, length(configs), taken))
            push(outbounds, outbound);
    }

    return outbounds;
}

function normalize_sing_box_xhttp_transport(outbound) {
    if (type(outbound) != "object" || type(outbound.transport) != "object")
        return outbound;
    if (outbound.transport.type != "xhttp")
        return outbound;

    outbound.transport.x_padding_bytes = xhttp_positive_range_or_default(outbound.transport.x_padding_bytes, "100-1000");

    let sc_max_each_post_bytes = xhttp_present_positive_range_or_default(outbound.transport.sc_max_each_post_bytes, "1000000");
    if (sc_max_each_post_bytes != null)
        outbound.transport.sc_max_each_post_bytes = sc_max_each_post_bytes;

    let sc_min_posts_interval_ms = xhttp_present_positive_range_or_default(outbound.transport.sc_min_posts_interval_ms, "30");
    if (sc_min_posts_interval_ms != null)
        outbound.transport.sc_min_posts_interval_ms = sc_min_posts_interval_ms;

    let uplink_chunk_size = xhttp_present_positive_range_or_default(outbound.transport.uplink_chunk_size, "2048-3072");
    if (uplink_chunk_size != null)
        outbound.transport.uplink_chunk_size = uplink_chunk_size;

    let sc_stream_up_server_secs = xhttp_present_positive_range_or_default(outbound.transport.sc_stream_up_server_secs, "0");
    if (sc_stream_up_server_secs != null)
        outbound.transport.sc_stream_up_server_secs = sc_stream_up_server_secs;

    return outbound;
}

function normalize_sing_box_hysteria2_outbound(outbound) {
    if (type(outbound) == "object" &&
        lc(as_string(outbound.type || "")) == "hysteria2" &&
        type(outbound.tls) == "object" &&
        outbound.tls.utls != null) {
        delete outbound.tls.utls;
    }
    return outbound;
}

function normalize_sing_box_tuic_outbound(outbound) {
    if (type(outbound) == "object" &&
        lc(as_string(outbound.type || "")) == "tuic" &&
        type(outbound.tls) == "object" &&
        outbound.tls.utls != null) {
        delete outbound.tls.utls;
    }
    return outbound;
}

function sing_box_urltest_group(outbound) {
    return type(outbound) == "object" && lc(as_string(outbound.type || "")) == "urltest";
}

function sing_box_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

parse_amnezia_vpn_container = function(line) {
    let amnezia = require("subscription.amnezia");
    if (type(amnezia) != "object" || type(amnezia.decompress) != "function")
        return null;
    let text = amnezia.decompress(line);
    if (type(text) != "string" || substr(trim(text), 0, 1) != "{")
        return null;
    let data = json_decode_text(text);
    if (type(data) != "object" || type(data.containers) != "array" || length(data.containers) == 0 || length(data.containers) > 16)
        return null;
    let host_fallback = trim(as_string(data.hostName || data.host || ""));
    let desc_name = trim(as_string(data.description || data.name || ""));
    let clean_desc = "";
    if (length(desc_name) <= 200) {
        for (let i = 0; i < length(desc_name); i++) {
            let n = ord(substr(desc_name, i, 1));
            if (n >= 32 && n != 127)
                clean_desc += chr(n);
        }
    }
    let hash_pos = index(line, "#");
    let frag = hash_pos >= 0 ? trim(urldecode_fragment(substr(line, hash_pos + 1))) : "";
    let def_kind = as_string(data.defaultContainer || "");
    let candidates = [];
    for (let c in data.containers) {
        if (type(c) == "object" && as_string(c.container || "") == def_kind)
            push(candidates, c);
    }
    for (let c in data.containers) {
        if (type(c) == "object" && as_string(c.container || "") != def_kind)
            push(candidates, c);
    }
    for (let container in candidates) {
        let kind = lc(trim(as_string(container.container || "")));
        if (kind == "amnezia-xray" || kind == "xray") {
            let xray_sec = json_decode_text(container.xray) || json_decode_text(container["amnezia-xray"]) || json_decode_text(container.params);
            if (type(xray_sec) != "object")
                continue;
            let raw_last = xray_sec.last_config != null ? xray_sec.last_config : xray_sec.config;
            let last_cfg = json_decode_text(raw_last) || xray_sec;
            if (!is_xray_config(last_cfg))
                continue;
            let outbounds = normalize_xray_configs([ last_cfg ]);
            for (let ob in outbounds) {
                if (type(ob) != "object" || ob.__tachyon_hidden || sing_box_urltest_group(ob))
                    continue;
                if ((as_string(ob.server || "") == "" || ob.server == "$REMOTE_HOST") && host_fallback != "")
                    ob.server = host_fallback;
                if (ob.type == "vless" && ob.flow != null) {
                    let nf = normalize_vless_flow(ob.flow);
                    if (nf == null)
                        continue;
                    if (nf == "")
                        delete ob.flow;
                    else
                        ob.flow = nf;
                }
                ob = normalize_sing_box_xhttp_transport(ob);
                let tag_nm = frag != "" ? frag : (clean_desc != "" ? clean_desc : as_string(ob.remark || ob.tag || "Amnezia-Xray"));
                ob.tag = tag_nm;
                ob.remark = tag_nm;
                ob.share_link = line;
                return ob;
            }
        } else if (kind == "amnezia-shadowsocks" || kind == "shadowsocks" || kind == "amnezia-ss" || kind == "ss") {
            let ss_sec = json_decode_text(container.shadowsocks) || json_decode_text(container["amnezia-shadowsocks"]) || json_decode_text(container.ss) || json_decode_text(container.params);
            if (type(ss_sec) != "object")
                continue;
            let raw_last = ss_sec.last_config != null ? ss_sec.last_config : ss_sec.config;
            let last_cfg = json_decode_text(raw_last) || ss_sec;
            if (type(last_cfg) != "object")
                continue;
            let srv = trim(as_string(last_cfg.server || last_cfg.hostName || last_cfg.host || host_fallback));
            if (srv == "$REMOTE_HOST")
                srv = host_fallback;
            let prt = int(last_cfg.server_port || last_cfg.port || ss_sec.port || data.port || 0);
            let pw = as_string(last_cfg.password || ss_sec.password || "");
            let method = trim(as_string(last_cfg.method || last_cfg.cipher || ss_sec.method || ss_sec.cipher || "chacha20-ietf-poly1305"));
            if (srv != "" && !is_dummy_server(srv, prt) && valid_port(prt) && pw != "") {
                let tag_nm = frag != "" ? frag : (clean_desc != "" ? clean_desc : (srv + ":" + prt));
                return {
                    type: "shadowsocks",
                    tag: tag_nm,
                    remark: tag_nm,
                    share_link: line,
                    server: srv,
                    server_port: prt,
                    method: method,
                    password: pw
                };
            }
        }
    }
    return null;
};

function decode_base64_or_raw_conf_text(raw_config) {
    let text = trim(as_string(raw_config));
    if (text == "")
        return "";
    if (index(lc(text), "[interface]") >= 0)
        return text;
    let payload = replace(replace(text, /[\r\n \t]+/g, ""), /-/g, "+");
    payload = replace(payload, /_/g, "/");
    if (match(payload, /^[A-Za-z0-9+\/]*={0,2}$/) && length(payload) % 4 != 1) {
        while (length(payload) % 4)
            payload += "=";
        try {
            let decoded = b64dec(payload);
            if (decoded != null && decoded != "")
                return decoded;
        } catch (e) {}
    }
    return text;
}

let last_normalize_error_reason = "";

function get_last_normalize_error() {
    return last_normalize_error_reason;
}

function extract_peer_params_from_object(obj) {
    if (type(obj) != "object")
        return { public_key: "", endpoint: "", pre_shared_key: "", allowed_ips: null };

    let sub = type(obj.peer) == "object" ? obj.peer :
        (type(obj.server) == "object" ? obj.server :
        (type(obj.wireguard) == "object" ? obj.wireguard :
        (type(obj.amnezia) == "object" ? obj.amnezia :
        (type(obj.awg) == "object" ? obj.awg : {}))));
    if (type(obj.peers) == "array" && length(obj.peers) > 0 && type(obj.peers[0]) == "object")
        sub = obj.peers[0];

    let peer_pub = trim(as_string(
        obj.public_key || obj.publicKey || obj.peer_public_key || obj.peerPublicKey || obj.server_public_key || obj.serverPublicKey ||
        sub.public_key || sub.publicKey || sub.peer_public_key || sub.peerPublicKey || sub.server_public_key || sub.serverPublicKey || ""
    ));
    let peer_ep = trim(as_string(obj.endpoint || obj.server_endpoint || sub.endpoint || sub.server_endpoint || ""));
    if (peer_ep == "") {
        let srv = trim(as_string(obj.server || obj.host || obj.hostname || sub.server || sub.host || sub.address || ""));
        let prt = trim(as_string(obj.server_port || obj.port || sub.server_port || sub.port || ""));
        if (srv != "" && prt != "")
            peer_ep = (index(srv, ":") >= 0 && substr(srv, 0, 1) != "[") ? ("[" + srv + "]:" + prt) : (srv + ":" + prt);
    }
    let psk = trim(as_string(
        obj.pre_shared_key || obj.preshared_key || obj.presharedKey || obj.psk ||
        sub.pre_shared_key || sub.preshared_key || sub.presharedKey || sub.psk || ""
    ));
    let allowed = obj.allowed_ips != null ? obj.allowed_ips : (obj.allowedIps != null ? obj.allowedIps : (sub.allowed_ips != null ? sub.allowed_ips : sub.allowedIps));
    return {
        public_key: peer_pub,
        endpoint: peer_ep,
        pre_shared_key: psk,
        allowed_ips: allowed
    };
}

function extract_peer_params_from_headers_file(headers_file) {
    let result = { public_key: "", endpoint: "", pre_shared_key: "", allowed_ips: null };
    if (as_string(headers_file) == "")
        return result;
    let data = read_file(headers_file);
    if (data == null || data == "")
        return result;
    let host = "", port = "";
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(line, /\r$/g, ""));
        let colon = index(line, ":");
        if (colon <= 0)
            continue;
        let k = lc(trim(substr(line, 0, colon)));
        let v = trim(substr(line, colon + 1));
        if (v == "")
            continue;
        if (k == "x-peer-public-key" || k == "x-wg-public-key" || k == "x-awg-public-key" || k == "x-server-public-key" || k == "peer-public-key")
            result.public_key = v;
        else if (k == "x-peer-endpoint" || k == "x-wg-endpoint" || k == "x-awg-endpoint" || k == "x-endpoint" || k == "peer-endpoint")
            result.endpoint = v;
        else if (k == "x-peer-host" || k == "x-server-host")
            host = v;
        else if (k == "x-peer-port" || k == "x-server-port")
            port = v;
        else if (k == "x-preshared-key" || k == "x-pre-shared-key")
            result.pre_shared_key = v;
    }
    if (result.endpoint == "" && host != "" && port != "")
        result.endpoint = (index(host, ":") >= 0 && substr(host, 0, 1) != "[") ? ("[" + host + "]:" + port) : (host + ":" + port);
    return result;
}

function is_json_candidate_container(item) {
    if (type(item) != "object")
        return false;
    if (type(item.servers) == "array" || type(item.configs) == "array" ||
        type(item.nodes) == "array" || type(item.items) == "array" ||
        type(item.endpoints) == "array")
        return true;
    if (type(item.outbounds) == "array" && !sing_box_urltest_group(item) && lc(as_string(item.type || "")) != "selector") {
        for (let ob in item.outbounds) {
            if (type(ob) == "object")
                return true;
        }
    }
    return false;
}

function extract_container_candidates(container, fallback_peer) {
    let result = [];
    let item_peer = extract_peer_params_from_object(container);
    let child_peer = {};
    if (type(fallback_peer) == "object") {
        for (let k, v in fallback_peer)
            child_peer[k] = v;
    }
    if (item_peer.public_key != "") child_peer.public_key = item_peer.public_key;
    if (item_peer.endpoint != "") child_peer.endpoint = item_peer.endpoint;
    if (item_peer.pre_shared_key != "") child_peer.pre_shared_key = item_peer.pre_shared_key;
    if (item_peer.allowed_ips != null) child_peer.allowed_ips = item_peer.allowed_ips;

    let container_name = trim(as_string(container.name || container.tag || container.remark || ""));

    let sub_lists = [
        container.servers,
        container.configs,
        container.nodes,
        container.items,
        container.endpoints,
        container.outbounds
    ];

    for (let list in sub_lists) {
        if (type(list) != "array")
            continue;
        for (let i = 0; i < length(list); i++) {
            let child = list[i];
            if (type(child) == "object") {
                if (child.__fallback_peer == null && length(keys(child_peer)) > 0)
                    child.__fallback_peer = child_peer;
                if (container_name != "" && as_string(child.name || child.tag || child.remark || "") == "")
                    child.name = length(list) == 1 ? container_name : sprintf("%s (%d)", container_name, i + 1);
                push(result, child);
            }
        }
    }
    return result;
}

function flatten_json_candidate_items(candidates, fallback_peer, depth) {
    depth = int(depth || 0);
    if (depth > 5)
        return candidates;
    let result = [];
    let has_container = false;
    for (let item in candidates) {
        if (type(item) != "object")
            continue;
        if (is_json_candidate_container(item)) {
            has_container = true;
            let eff_peer = item.__fallback_peer || fallback_peer;
            let children = extract_container_candidates(item, eff_peer);
            for (let child in children)
                push(result, child);
        } else {
            push(result, item);
        }
    }
    if (has_container)
        return flatten_json_candidate_items(result, fallback_peer, depth + 1);
    return result;
}

function expand_json_config_outbound_items(item, fallback_peer) {
    if (type(item) != "object")
        return null;

    if (is_json_candidate_container(item)) {
        let eff_peer = item.__fallback_peer || fallback_peer;
        delete item.__fallback_peer;
        let children = extract_container_candidates(item, eff_peer);
        let result = [];
        for (let child in children) {
            let child_peer = child.__fallback_peer || eff_peer;
            delete child.__fallback_peer;
            let child_res = expand_json_config_outbound_items(child, child_peer);
            if (type(child_res) == "array") {
                for (let ep in child_res)
                    push(result, ep);
            }
        }
        if (length(result) > 0)
            return result;
    }

    let raw_cfg = as_string(item.config || item.awg_config || item.wg_config || "");
    if (raw_cfg == "")
        return null;

    let item_name = trim(as_string(item.name || item.tag || item.remark || ""));
    let endpoints = null;
    if (starts_with(trim(raw_cfg), "vpn://")) {
        endpoints = wireguard.from_vpn_endpoints(trim(raw_cfg));
    } else {
        let conf_text = decode_base64_or_raw_conf_text(raw_cfg);
        if (conf_text != "" && index(lc(conf_text), "[peer]") < 0) {
            let item_peer = extract_peer_params_from_object(item);
            let fb = type(fallback_peer) == "object" ? fallback_peer : {};
            let peer_pub = item_peer.public_key != "" ? item_peer.public_key : as_string(fb.public_key || "");
            let peer_ep = item_peer.endpoint != "" ? item_peer.endpoint : as_string(fb.endpoint || "");
            let psk = item_peer.pre_shared_key != "" ? item_peer.pre_shared_key : as_string(fb.pre_shared_key || "");
            let allowed = item_peer.allowed_ips != null ? item_peer.allowed_ips : fb.allowed_ips;
            if (peer_pub != "" && peer_ep != "") {
                conf_text += "\n[Peer]\nPublicKey = " + peer_pub + "\nEndpoint = " + peer_ep + "\n";
                if (psk != "")
                    conf_text += "PresharedKey = " + psk + "\n";
                if (type(allowed) == "array" && length(allowed) > 0)
                    conf_text += "AllowedIPs = " + join(", ", allowed) + "\n";
                else if (type(allowed) == "string" && trim(allowed) != "")
                    conf_text += "AllowedIPs = " + trim(allowed) + "\n";
            } else if (index(lc(conf_text), "[interface]") >= 0) {
                last_normalize_error_reason = "incomplete_awg_missing_peer";
            }
        }
        let share = "vpn://" + replace(replace(replace(b64enc(conf_text), /\+/g, "-"), /\//g, "_"), /=+$/, "");
        endpoints = wireguard.from_conf_endpoints(conf_text, share, item_name);
    }

    if (type(endpoints) != "array" || length(endpoints) == 0)
        return [];

    let result = [];
    for (let i = 0; i < length(endpoints); i++) {
        let ep = endpoints[i];
        if (item_name != "") {
            ep.tag = i == 0 ? item_name : sprintf("%s (%d)", item_name, i + 1);
            ep.remark = ep.tag;
        }
        push(result, ep);
    }
    return result;
}

function normalize_sing_box_wireguard_outbound(outbound) {
    if (type(outbound) != "object")
        return outbound;
    let out_type = lc(trim(as_string(outbound.type || "")));
    if (out_type != "wireguard" && out_type != "amneziawg" && out_type != "awg")
        return outbound;

    outbound.type = "wireguard";
    let tag_val = trim(as_string(outbound.tag || outbound.name || outbound.remark || ""));
    if (tag_val != "")
        outbound.tag = tag_val;

    if (outbound.address == null && outbound.local_address != null) {
        outbound.address = type(outbound.local_address) == "array" ? outbound.local_address : [ as_string(outbound.local_address) ];
        delete outbound.local_address;
    } else if (type(outbound.address) == "string") {
        outbound.address = [ outbound.address ];
    }

    if (type(outbound.peers) != "array" || length(outbound.peers) == 0) {
        let srv = trim(as_string(outbound.server || outbound.host || ""));
        let prt = int(outbound.server_port || outbound.port || 0);
        let pub = trim(as_string(outbound.peer_public_key || outbound.public_key || outbound.publicKey || ""));
        if (srv != "" && prt > 0 && pub != "") {
            let peer = {
                address: srv,
                port: prt,
                public_key: pub,
                allowed_ips: type(outbound.allowed_ips) == "array" && length(outbound.allowed_ips) > 0
                    ? outbound.allowed_ips
                    : [ "0.0.0.0/0", "::/0" ]
            };
            let psk = trim(as_string(outbound.pre_shared_key || outbound.preshared_key || ""));
            if (psk != "")
                peer.pre_shared_key = psk;
            if (outbound.reserved != null)
                peer.reserved = outbound.reserved;
            if (outbound.persistent_keepalive_interval != null)
                peer.persistent_keepalive_interval = outbound.persistent_keepalive_interval;
            outbound.peers = [ peer ];
            delete outbound.server;
            delete outbound.server_port;
            delete outbound.peer_public_key;
            delete outbound.pre_shared_key;
            delete outbound.preshared_key;
            delete outbound.reserved;
            delete outbound.allowed_ips;
            delete outbound.persistent_keepalive_interval;
        }
    } else {
        for (let peer in outbound.peers) {
            if (type(peer) != "object")
                continue;
            if (peer.address == null && peer.server != null) {
                peer.address = peer.server;
                delete peer.server;
            }
            if (peer.port == null && peer.server_port != null) {
                peer.port = int(peer.server_port);
                delete peer.server_port;
            }
            if (peer.public_key == null && peer.peer_public_key != null) {
                peer.public_key = peer.peer_public_key;
                delete peer.peer_public_key;
            }
            if (peer.allowed_ips == null)
                peer.allowed_ips = [ "0.0.0.0/0", "::/0" ];
        }
    }

    if (type(outbound.amnezia) == "object") {
        for (let k, v in outbound.amnezia) {
            if (outbound[k] == null)
                outbound[k] = v;
        }
        delete outbound.amnezia;
    }

    if (outbound.mtu == null)
        outbound.mtu = 1280;

    return outbound;
}

function normalize_sing_box_json_outbounds(candidates, fallback_peer) {
    candidates = flatten_json_candidate_items(candidates, fallback_peer);
    let outbounds = [];
    let urltest_refs = {};
    let detour_refs = {};
    let idx = 0;

    for (let outbound in candidates) {
        idx++;
        if (type(outbound) != "object" || outbound_is_unsupported_stub(outbound))
            continue;
        let eff_peer = outbound.__fallback_peer || fallback_peer;
        delete outbound.__fallback_peer;
        let expanded_cfg = expand_json_config_outbound_items(outbound, eff_peer);
        if (expanded_cfg != null) {
            for (let ep in expanded_cfg)
                push(outbounds, ep);
            continue;
        }
        if ((outbound.type == null || as_string(outbound.type) == "") &&
            (outbound.protocol != null || outbound.streamSettings != null || outbound.settings != null)) {
            let xray_tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + idx);
            let converted = convert_xray_outbound(outbound, xray_tag);
            if (converted == null)
                continue;
            let disp = xray_display_name(as_string(outbound.remarks || outbound.remark || outbound.ps || outbound.name || outbound.tag || ""));
            if (disp != "")
                converted.remark = disp;
            let detour = xray_outbound_detour(outbound);
            if (detour != "")
                converted.detour = detour;
            outbound = converted;
        }
        else if (outbound.streamSettings != null && outbound.transport == null) {
            let stream = object_or_empty(outbound.streamSettings);
            let transport = xray_transport_from_stream(stream);
            let tls = xray_tls_from_stream(stream, lc(as_string(stream.network || "")));
            if (lc(as_string(outbound.type || "")) == "shadowsocks" && transport != null && transport.type == "ws" && outbound.plugin == null) {
                outbound.plugin = "v2ray-plugin";
                let opts = [ "mode=websocket" ];
                if (tls != null && tls.enabled === true) {
                    push(opts, "tls");
                    if (as_string(tls.server_name || "") != "")
                        push(opts, "host=" + as_string(tls.server_name));
                }
                let ws_host = as_string(object_or_empty(transport.headers).Host || object_or_empty(transport.headers).host || "");
                if (ws_host != "" && (tls == null || as_string(tls.server_name || "") == ""))
                    push(opts, "host=" + ws_host);
                let ws_path = as_string(transport.path || "/");
                if (ws_path != "")
                    push(opts, "path=" + ws_path);
                outbound.plugin_opts = join(";", opts);
            } else {
                if (tls != null && outbound.tls == null)
                    outbound.tls = tls;
                if (transport != null && outbound.transport == null)
                    outbound.transport = transport;
            }
            delete outbound.streamSettings;
        }
        outbound = normalize_sing_box_wireguard_outbound(outbound);
        if (outbound.type == "wireguard" && (type(outbound.peers) != "array" || length(outbound.peers) == 0))
            continue;
        if (lc(as_string(outbound.type || "")) == "vless" && outbound.flow != null) {
            let norm_flow = normalize_vless_flow(outbound.flow);
            if (norm_flow == null)
                continue;
            if (norm_flow == "")
                delete outbound.flow;
            else
                outbound.flow = norm_flow;
        }
        outbound = normalize_sing_box_hysteria2_outbound(outbound);
        outbound = normalize_sing_box_tuic_outbound(outbound);
        push(outbounds, normalize_sing_box_xhttp_transport(outbound));
    }

    for (let outbound in outbounds) {
        if (sing_box_urltest_group(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    urltest_refs[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            detour_refs[detour] = true;
    }

    for (let outbound in outbounds) {
        let tag_name = sing_box_outbound_tag(outbound);
        if (sing_box_urltest_group(outbound)) {
            outbound.__tachyon_allow_group = true;
            continue;
        }
        if (tag_name != "" && (urltest_refs[tag_name] || detour_refs[tag_name]))
            outbound.__tachyon_hidden = true;
    }

    return outbounds;
}

function normalize_sing_box_json_value(value, output_file, headers_file) {
    let candidates = [];
    let outbounds = [];

    if (is_xray_config(value))
        outbounds = normalize_xray_configs([value]);
    else if (type(value) == "array" && length(value) > 0 && is_xray_config(value[0]))
        outbounds = normalize_xray_configs(value);

    if (length(outbounds) > 0) {
        return write_json_file(output_file, {
            version: 1,
            format: "sing-box-json",
            outbounds: outbounds
        });
    }

    let fallback_peer = extract_peer_params_from_headers_file(headers_file);
    if (type(value) == "object") {
        let top_peer = extract_peer_params_from_object(value);
        if (top_peer.public_key != "")
            fallback_peer.public_key = top_peer.public_key;
        if (top_peer.endpoint != "")
            fallback_peer.endpoint = top_peer.endpoint;
        if (top_peer.pre_shared_key != "")
            fallback_peer.pre_shared_key = top_peer.pre_shared_key;
        if (top_peer.allowed_ips != null)
            fallback_peer.allowed_ips = top_peer.allowed_ips;
    }

    if (type(value) == "object" && is_json_candidate_container(value)) {
        candidates = extract_container_candidates(value, fallback_peer);
    }
    else if (type(value) == "array")
        candidates = value;
    else if (type(value) == "object" && (type(value.type) == "string" || type(value.protocol) == "string" || value.config != null || value.awg_config != null || value.wg_config != null))
        candidates = [value];

    outbounds = normalize_sing_box_json_outbounds(candidates, fallback_peer);

    if (length(outbounds) == 0) {
        fs.unlink(output_file);
        return false;
    }

    return write_json_file(output_file, {
        version: 1,
        format: "sing-box-json",
        outbounds: outbounds
    });
}

function temp_path(prefix) {
    let stamp = clock();
    return sprintf("/tmp/%s.%d.%d", prefix, stamp[0], stamp[1]);
}


function gzip_decode_file(input_file, output_file) {
    if (as_string(input_file) == "" || as_string(output_file) == "" || !fs.stat(input_file))
        return false;

    for (let command in [ "gzip -dc", "gunzip -c", "zcat" ]) {
        let status = system(command + " " + shell_quote(input_file) +
            " > " + shell_quote(output_file) + " 2>/dev/null");
        if (status == 0) {
            let stat = fs.stat(output_file);
            if (stat && int(stat.size) > 0)
                return true;
        }
        fs.unlink(output_file);
    }

    return false;
}

function try_decode_gzip_content_file(input_file) {
    let tmp = temp_path("tachyon-subscription-gzip");
    if (!gzip_decode_file(input_file, tmp)) {
        fs.unlink(tmp);
        return false;
    }

    if (!fs.rename(tmp, input_file)) {
        fs.unlink(tmp);
        return false;
    }

    return true;
}

function normalized_skipped_message(path) {
    let value = read_json_file(path);
    if (type(value) != "object")
        return "";

    let skipped = as_string(value.skipped != null ? value.skipped : "0");
    if (match(skipped, /^[0-9]+$/) == null || int(skipped) <= 0)
        return "";

    if (as_string(value.format != null ? value.format : "") == "clash-yaml")
        return "Skipped " + skipped + " invalid or unsupported Clash proxy entries";

    return "Skipped " + skipped + " invalid or unsupported subscription links";
}

function extract_ui_metadata_file(headers_file, body_file, output_file) {
    let tmp = temp_path("tachyon-subscription-metadata");
    let raw = metadata_body_store_with_base64_fallback(body_file).values;
    let headers = metadata_headers_store(headers_file).values;
    for (let key, value in headers)
        raw[key] = value;

    let result = metadata_ui_object(raw);
    if (length(keys(result)) <= 1) {
        fs.unlink(output_file);
        return false;
    }

    if (!fs.writefile(tmp, sprintf("%J\n", result))) {
        fs.unlink(tmp);
        return false;
    }
    if (!fs.rename(tmp, output_file)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

function normalize_content_data(data, output_file, depth, headers_file) {
    data = as_string(data);
    if (index(data, "\r") >= 0)
        data = replace(data, /\r/g, "");
    data = strip_metadata_preamble_data(data);

    if (depth < 2 && happ.is_encrypted(data)) {
        let decrypted = happ.decrypt(data);
        if (decrypted != null && decrypted != "")
            return normalize_content_data(decrypted, output_file, depth + 1, headers_file);
    }

    let first = first_non_ws_char(data);
    if (first == "{" || first == "[") {
        let decoded_json = json_decode_text(data);
        if (decoded_json != null)
            return normalize_sing_box_json_value(decoded_json, output_file, headers_file);
    }

    if (index(lc(data), "[interface]") >= 0 && match(data, /(^|\n)[ \t]*\[[Ii]nterface\][ \t]*(\n|$)/) != null) {
        if (normalize_sing_box_json_value({ config: data }, output_file, headers_file))
            return true;
    }

    if (index(data, "proxies:") >= 0 && content_is_clash_yaml(data)) {
        let tmp = temp_path("tachyon-subscription-clash");
        if (!fs.writefile(tmp, data))
            return false;
        let ok = normalize_clash_yaml(tmp, output_file);
        fs.unlink(tmp);
        return ok;
    }

    if (index(data, "://") >= 0) {
        if (normalize_uri_list_data(data, output_file))
            return true;
    }

    if (depth < 1) {
        let compact = replace(data, /[\r\n\t ]/g, "");
        let decoded = base64_decode(compact);
        if (decoded != null && decoded != "")
            return normalize_content_data(decoded, output_file, depth + 1, headers_file);
    }

    return false;
}

let _core_subscription_cli_supported = null;
let _core_subscription_cli_bin = "";

function core_subscription_bin_path() {
    return as_string(getenv("TACHYON_CORE_BIN") || "/usr/bin/tachyon-core");
}

function core_subscription_cli_supported() {
    let bin = core_subscription_bin_path();
    let st = fs.stat(bin);
    if (st == null || st.type != "file" || (int(st.mode || 0) & 73) == 0) {
        _core_subscription_cli_supported = false;
        _core_subscription_cli_bin = bin;
        return false;
    }

    let stamp = bin + "|" + as_string(st.size || 0) + "|" + as_string(st.mtime || 0);
    if (_core_subscription_cli_supported != null && _core_subscription_cli_bin == stamp)
        return _core_subscription_cli_supported;

    let stamp_file = "/var/run/tachyon/core-subscription-cli.stamp";
    if (getenv("TACHYON_CORE_BIN") == null) {
        let cached_stamp = trim(as_string(read_file(stamp_file) || ""));
        if (cached_stamp == stamp + "|1") {
            _core_subscription_cli_bin = stamp;
            _core_subscription_cli_supported = true;
            return true;
        }
        if (cached_stamp == stamp + "|0") {
            _core_subscription_cli_bin = stamp;
            _core_subscription_cli_supported = false;
            return false;
        }
    }

    let cap = common.command_capture(common.command_from_args([ bin, "subscription", "hwid" ]) + " 2>/dev/null");
    _core_subscription_cli_bin = stamp;
    _core_subscription_cli_supported = cap != null && int(cap.status) == 0;
    if (getenv("TACHYON_CORE_BIN") == null && fs.stat("/var/run/tachyon") != null)
        common.write_file(stamp_file, stamp + "|" + (_core_subscription_cli_supported ? "1" : "0") + "\n");
    return _core_subscription_cli_supported;
}

function content_requires_ucode_normalizer(input_file, headers_file) {
    let data = read_file(input_file);
    if (data == null || data == "")
        return true;

    if (index(data, "fptn:") >= 0 || index(data, "fptnb:") >= 0)
        return true;

    return false;
}

function try_normalize_with_core_cli(input_file, output_file, headers_file, force_allow) {
    if (!core_subscription_cli_supported())
        return false;
    if (!force_allow && content_requires_ucode_normalizer(input_file, headers_file))
        return false;

    let core_tmp = temp_path("tachyon-subscription-core-parse");
    let args = [
        core_subscription_bin_path(),
        "subscription",
        "parse",
        input_file,
        "--format",
        "outbounds",
        "-o",
        core_tmp
    ];
    if (as_string(headers_file) != "" && fs.stat(as_string(headers_file)) != null) {
        push(args, "--headers");
        push(args, as_string(headers_file));
    }
    let parse_cap = common.command_capture(common.command_from_args(args) + " 2>/dev/null");
    if (parse_cap == null || int(parse_cap.status) != 0) {
        fs.unlink(core_tmp);
        return false;
    }

    let parsed = read_json_file(core_tmp);
    fs.unlink(core_tmp);
    if (type(parsed) != "array" || length(parsed) == 0)
        return false;

    let fallback_peer = extract_peer_params_from_headers_file(headers_file);
    let outbounds = normalize_sing_box_json_outbounds(parsed, fallback_peer);
    if (length(outbounds) == 0)
        return false;

    return write_json_file(output_file, {
        version: 1,
        format: "sing-box-json",
        outbounds: outbounds
    });
}

parse_wdtt_via_core_cli = function(raw_line) {
    if (!core_subscription_cli_supported())
        return null;
    let in_tmp = temp_path("tachyon-wdtt-in");
    let out_tmp = temp_path("tachyon-wdtt-out");
    if (!fs.writefile(in_tmp, as_string(raw_line) + "\n")) {
        fs.unlink(in_tmp);
        return null;
    }
    let args = [
        core_subscription_bin_path(),
        "subscription",
        "parse",
        in_tmp,
        "--format",
        "outbounds",
        "-o",
        out_tmp
    ];
    let parse_cap = common.command_capture(common.command_from_args(args) + " 2>/dev/null");
    fs.unlink(in_tmp);
    if (parse_cap == null || int(parse_cap.status) != 0) {
        fs.unlink(out_tmp);
        return null;
    }
    let parsed = read_json_file(out_tmp);
    fs.unlink(out_tmp);
    if (type(parsed) != "array" || length(parsed) == 0 || type(parsed[0]) != "object")
        return null;
    let obj = parsed[0];
    if (lc(as_string(obj.type || "")) != "wdtt")
        return null;
    obj.share_link = as_string(raw_line);
    return obj;
};

function normalize_content_file(input_file, output_file, headers_file, engine_mode) {
    last_normalize_error_reason = "";
    let eff_engine = lc(trim(as_string(engine_mode || getenv("TACHYON_SUBSCRIPTION_ENGINE") || "")));
    if (eff_engine == "core" && try_normalize_with_core_cli(input_file, output_file, headers_file, false))
        return true;

    let ok = false;
    if (file_looks_like_uri_list(input_file))
        ok = normalize_uri_list_file(input_file, output_file, true);
    else {
        let data = read_file(input_file);
        ok = data == null ? false : normalize_content_data(data, output_file, 0, headers_file);
    }
    if (ok && validate_subscription(output_file))
        return true;
    if (last_normalize_error_reason != "incomplete_awg_missing_peer" &&
        try_normalize_with_core_cli(input_file, output_file, headers_file, true))
        return true;
    return ok;
}

function normalize_content_validated(input_file, output_file, headers_file, engine_mode) {
    last_normalize_error_reason = "";
    let normalize_input = input_file;
    let decoded_tmp = temp_path("tachyon-subscription-gzip");
    let decoded = gzip_decode_file(input_file, decoded_tmp);
    if (decoded)
        normalize_input = decoded_tmp;
    else
        fs.unlink(decoded_tmp);

    let ok = normalize_content_file(normalize_input, output_file, headers_file, engine_mode);
    if (decoded)
        fs.unlink(decoded_tmp);
    if (!ok)
        return false;

    return validate_subscription(output_file);
}

function normalized_skipped_warning(path) {
    let message = normalized_skipped_message(path);
    if (message != "")
        print(message, "\n");

    return true;
}

function subscription_source_entry_result(valid, url, user_agent, error) {
    return {
        valid,
        url: as_string(url),
        user_agent: as_string(user_agent),
        error: as_string(error)
    };
}

function write_subscription_source_entry_tsv_result(result) {
    result = type(result) == "object" ? result : subscription_source_entry_result(false, "", "", "Subscription URL cannot be empty");

    if (!result.valid) {
        print(result.error, "\n");
        return false;
    }

    print(result.url, "\t", result.user_agent, "\n");
    return true;
}

function parse_subscription_source_entry(entry) {
    entry = trim(entry);
    if (entry == "")
        return subscription_source_entry_result(false, "", "", "Subscription URL cannot be empty");

    if (index(entry, "|") >= 0)
        return subscription_source_entry_result(false, "", "", "Configure User-Agent in the subscription item settings");

    if (!(substr(entry, 0, 7) == "http://" || substr(entry, 0, 8) == "https://" || happ.is_encrypted(entry)))
        return subscription_source_entry_result(false, "", "", "Subscription URL must start with http://, https:// or a supported Happ crypt link");

    return subscription_source_entry_result(true, entry, "", "");
}

function parse_subscription_source_entry_tsv(entry) {
    return write_subscription_source_entry_tsv_result(parse_subscription_source_entry(entry));
}

function module_exports() {
    return {
        share_link_outbound,
        parse_share_link,
        add_transport,
        parse_subscription_source_entry,
        extract_peer_params_from_headers_file,
        normalize_sing_box_json_outbounds,
        validate_subscription,
        normalize_content_validated,
        core_subscription_cli_supported,
        try_normalize_with_core_cli,
        get_last_normalize_error,
        normalized_skipped_message,
        try_decode_gzip_content_file,
        extract_ui_metadata_file,
        runtime_outbounds_equal,
        outbound_is_unsupported_stub
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0];
let ok = false;

if (mode == "validate-subscription")
    ok = validate_subscription(ARGV[1]);
else if (mode == "url-fragment")
    ok = subscription_url_fragment(ARGV[1]);
else if (mode == "share-link-outbound")
    ok = share_link_outbound(ARGV[1], ARGV[2]);
else if (mode == "normalize-uri-list")
    ok = normalize_uri_list(ARGV[1], ARGV[2]);
else if (mode == "normalize-clash-yaml")
    ok = normalize_clash_yaml(ARGV[1], ARGV[2]);
else if (mode == "normalize-content")
    ok = normalize_content_file(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "normalize-content-validated")
    ok = normalize_content_validated(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "try-decode-gzip-content")
    ok = try_decode_gzip_content_file(ARGV[1]);
else if (mode == "runtime-outbounds-equal")
    ok = runtime_outbounds_equal(ARGV[1], ARGV[2]);
else if (mode == "normalized-skipped-warning")
    ok = normalized_skipped_warning(ARGV[1]);
else if (mode == "metadata-headers-json")
    ok = metadata_headers_json(ARGV[1]);
else if (mode == "metadata-body-json")
    ok = metadata_body_json(ARGV[1]);
else if (mode == "metadata-ui-json")
    ok = metadata_ui_json(ARGV[1]);
else if (mode == "metadata-extract-ui-json")
    ok = metadata_extract_ui_json(ARGV[1], ARGV[2]);
else if (mode == "metadata-extract-ui-file")
    ok = extract_ui_metadata_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "parse-source-entry-tsv")
    ok = parse_subscription_source_entry_tsv(ARGV[1]);
else if (ARGV[0] && ARGV[1])
    ok = normalize_uri_list(ARGV[0], ARGV[1]);
else {
    warn("Usage: subscription/parser.uc validate-subscription <normalized-json>\n");
    warn("       subscription/parser.uc url-fragment <url>\n");
    warn("       subscription/parser.uc share-link-outbound <url> <tag>\n");
    warn("       subscription/parser.uc normalize-uri-list <input> <output>\n");
    warn("       subscription/parser.uc normalize-clash-yaml <input> <output>\n");
    warn("       subscription/parser.uc normalize-content <input> <output>\n");
    warn("       subscription/parser.uc normalize-content-validated <input> <output>\n");
    warn("       subscription/parser.uc try-decode-gzip-content <input>\n");
    warn("       subscription/parser.uc runtime-outbounds-equal <left> <right>\n");
    warn("       subscription/parser.uc normalized-skipped-warning <normalized-json>\n");
    warn("       subscription/parser.uc metadata-headers-json <input>\n");
    warn("       subscription/parser.uc metadata-body-json <input>\n");
    warn("       subscription/parser.uc metadata-ui-json <raw-json>\n");
    warn("       subscription/parser.uc metadata-extract-ui-json <headers> <body>\n");
    warn("       subscription/parser.uc metadata-extract-ui-file <headers> <body> <output>\n");
    warn("       subscription/parser.uc parse-source-entry-tsv <entry>\n");
    exit(2);
}

if (!ok)
    exit(1);
