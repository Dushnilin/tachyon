#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let bool_value_common = common.bool_value;
let remove_file = common.remove_file;
let list_option = common.list_option;

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    return bool_value_common(value);
}

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const ITEM_TYPES = [
    "subscription_url",
    "section_interface",
    "urltest",
    "priority_group",
    "priority_level",
    "condition",
    "outbound_source",
    "outbound_group",
    "balancer"
];

// Conditions a section may claim as global: the claim reserves the value for
// that section alone and every other section must drop it. Several UCI keys can
// fold into one kind - a rule set lives in rule_set or in rule_set_with_subnets,
// and a legacy config can still carry domains in the CSV text field instead of
// the list. Keys are storage keys, not widget names; the LuCI side maps its
// widget names onto the same kinds.
const GLOBAL_RULE_OPTIONS = {
    community_lists: [ "community_lists" ],
    rule_set: [ "rule_set", "rule_set_with_subnets" ],
    domain_ip_lists: [ "domain_ip_lists" ],
    geoip_country: [ "geoip_country" ],
    ports: [ "ports" ],
    dscp: [ "dscp" ],
    domain: [
        "domain",
        "domain_suffix",
        "domain_suffix_text",
        "domain_keyword",
        "domain_keyword_text",
        "domain_regex",
        "domain_regex_text",
        "domain_text"
    ],
    user_domains: [ "user_domains", "user_domains_text" ],
    ip_cidr: [ "ip_cidr", "ip_cidr_text" ]
};

// These kinds live in a textarea (newline/comma separated), the rest in a UCI
// list or a whitespace separated single option. One splitter for both the value
// set and a claim keeps the two sides reading UCI the same way.
const GLOBAL_RULE_TEXT_OPTIONS = {
    domain: true,
    user_domains: true,
    ip_cidr: true
};

let item_sections = null;

function raw_option(section, key) {
    return object_or_empty(section)[key];
}

function option(section, key, fallback) {
    return common.option(section, key, fallback);
}

function bool_option(section, key, fallback) {
    let val = raw_option(section, key);
    if (val == null)
        return !!fallback;
    return bool_value(val, fallback);
}

function list_value(section, key) {
    let value = raw_option(section, key);
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function whitespace_list_value(section, key) {
    let value = raw_option(section, key);
    if (type(value) == "array")
        return value;
    return common.list_option(section, key);
}

function section_name(section) {
    return option(section, ".name", "");
}

function empty_item_sections() {
    let result = {};
    for (let type_name in ITEM_TYPES) {
        result[type_name] = {
            by_name: {},
            list: []
        };
    }
    return result;
}

function add_item_section(index, type_name, section) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (name == "")
        return;

    if (index[type_name] == null)
        index[type_name] = { by_name: {}, list: [] };
    index[type_name].by_name[name] = section;
    push(index[type_name].list, section);
}

function item_index_from_cursor(cursor, config_name) {
    let index = empty_item_sections();
    if (cursor == null)
        return index;

    config_name = as_string(config_name || CONFIG_NAME);
    for (let type_name in ITEM_TYPES) {
        try {
            cursor.foreach(config_name, type_name, function(section) {
                add_item_section(index, type_name, section);
            });
        }
        catch (e) {
            // An absent config or an unknown section type throws here. The
            // index simply ends up without entries of that type, which is the
            // same state as a config that declares none; uci reports the parse
            // error itself to the system log.
        }
    }

    return index;
}

function fixture_section_list(data, type_name) {
    data = object_or_empty(data);
    let value = data[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = data[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function item_index_from_data(data) {
    let index = empty_item_sections();
    for (let type_name in ITEM_TYPES)
        for (let section in fixture_section_list(data, type_name))
            add_item_section(index, type_name, section);
    return index;
}

function item_index_from_uci() {
    let index = empty_item_sections();
    for (let type_name in ITEM_TYPES)
        for (let section in uci_core.section_objects(CONFIG_NAME, type_name))
            add_item_section(index, type_name, section);
    return index;
}

function set_item_sections(index) {
    item_sections = type(index) == "object" ? index : empty_item_sections();
}

function set_item_sections_from_cursor(cursor, config_name) {
    set_item_sections(item_index_from_cursor(cursor, config_name));
}

function set_item_sections_from_data(data) {
    set_item_sections(item_index_from_data(data));
}

function get_item_sections() {
    if (item_sections == null)
        item_sections = item_index_from_uci();
    return item_sections;
}

function child_section(type_name, item_id) {
    return object_or_empty(object_or_empty(object_or_empty(get_item_sections())[type_name]).by_name)[as_string(item_id)];
}

function owned_child_section(parent, type_name, item_id) {
    let child = child_section(type_name, item_id);
    if (type(child) != "object")
        return null;
    return option(child, "section", "") == section_name(parent) ? child : null;
}

function child_item_sort(left, right) {
    let left_has_order = (raw_option(left, "order") != null && raw_option(left, "order") != "");
    let right_has_order = (raw_option(right, "order") != null && raw_option(right, "order") != "");
    if (left_has_order && right_has_order) {
        let left_order = int(option(left, "order", "0"), 10);
        let right_order = int(option(right, "order", "0"), 10);
        if (left_order != right_order)
            return left_order < right_order ? -1 : 1;
    } else if (left_has_order) {
        return -1;
    } else if (right_has_order) {
        return 1;
    }
    return 0;
}

function child_items(parent, type_name) {
    let result = [];
    for (let child in object_or_empty(object_or_empty(get_item_sections())[type_name]).list || [])
        if (option(child, "section", "") == section_name(parent))
            push(result, child);
    sort(result, child_item_sort);
    return result;
}

function child_items_by_owner(type_name, owner_key, owner_value) {
    owner_value = as_string(owner_value);
    let result = [];
    for (let child in object_or_empty(object_or_empty(get_item_sections())[type_name]).list || [])
        if (option(child, owner_key, "") == owner_value)
            push(result, child);
    sort(result, child_item_sort);
    return result;
}

function child_item_by_value(parent, type_name, value_key, value) {
    value = as_string(value);
    for (let child in child_items(parent, type_name))
        if (option(child, value_key, "") == value)
            return child;
    return null;
}

function child_option(child, key, fallback) {
    if (type(child) != "object")
        return as_string(fallback);
    return option(child, key, fallback);
}

function child_option_alias(child, keys, fallback) {
    if (type(child) != "object")
        return as_string(fallback);
    for (let key in keys) {
        let value = raw_option(child, key);
        if (value != null)
            return as_string(value);
    }
    return as_string(fallback);
}

function child_bool(child, key, fallback) {
    if (type(child) != "object")
        return !!fallback;
    return bool_option(child, key, fallback);
}

function child_list(child, key, fallback) {
    if (type(child) != "object")
        return fallback == null ? [] : fallback;
    let value = raw_option(child, key);
    if (value == null)
        value = fallback;
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function child_list_alias(child, keys, fallback) {
    if (type(child) == "object") {
        for (let key in keys) {
            let value = raw_option(child, key);
            if (value != null)
                return child_list(child, key, []);
        }
    }
    return fallback == null ? [] : fallback;
}

function child_values(parent, type_name, value_key, legacy_key) {
    let items = child_items(parent, type_name);
    if (length(items) > 0) {
        let result = [];
        for (let child in items) {
            let value = option(child, value_key, "");
            if (value != "")
                push(result, value);
        }
        return result;
    }
    return legacy_key == "" ? [] : whitespace_list_value(parent, legacy_key);
}

function settings_map(section, key) {
    let value = option(section, key, "");
    if (value == "")
        return {};

    try {
        value = json(value);
    }
    catch (e) {
        return {};
    }

    return object_or_empty(value);
}

function item_settings(section, key, item) {
    return object_or_empty(settings_map(section, key)[as_string(item)]);
}

function item_option(section, key, item, option_name, fallback) {
    let value = item_settings(section, key, item)[option_name];
    if (value == null)
        return as_string(fallback);
    return as_string(value);
}

function item_bool(section, key, item, option_name, fallback) {
    return bool_value(item_settings(section, key, item)[option_name], fallback);
}

function item_list(section, key, item, option_name, fallback) {
    let value = item_settings(section, key, item)[option_name];
    if (value == null)
        value = fallback;
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function is_legacy_connection_action(action) {
    action = lc(as_string(action));
    return action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "socks" || action == "socks5" || action == "socks4" || action == "http" ||
        action == "shadowsocks" || action == "ss" || action == "vless" || action == "vmess" ||
        action == "trojan" || action == "hysteria2" || action == "hy2" || action == "tuic";
}

function is_connections_action(action) {
    action = lc(as_string(action));
    return action == "connection" || is_legacy_connection_action(action);
}

function is_remote_proxy_action(action) {
    action = as_string(action);
    return is_connections_action(action) ||
        action == "awg" || action == "warp" ||
        action == "anytls" || action == "snell" || action == "mieru" || action == "naive" || action == "sudoku" ||
        action == "masque" || action == "openvpn" || action == "openconnect" ||
        action == "tewfai" || action == "trusttunnel" || action == "mtproto" || action == "shadowtls" ||
        action == "chain" || action == "tailscale" ||
        action == "wdtt" || action == "olcrtc" || action == "fptn";
}

function is_wdtt_action(action) {
    return as_string(action) == "wdtt";
}

function is_olcrtc_action(action) {
    return as_string(action) == "olcrtc";
}

function is_fptn_action(action) {
    return as_string(action) == "fptn";
}

// How FPTN traffic leaves the box.
//
//   component - the external fptn-client owns tun-fptn and the fwmark route.
//   native    - tachyon-core dials FPTN from the generated config itself.
//
// "native" only exists on tachyon-core; every other engine is component mode.
// With no explicit setting the current behaviour is preserved: an installed
// component keeps the component path, a core-only box gets the native one.
// The explicit choice exists only so the two tunnels cannot fight when both
// are possible.
function fptn_transport_mode() {
    let variant = trim(as_string(fs.readfile(getenv("SB_VARIANT_STATE_FILE") || "/etc/tachyon/tachyon-core-variant") || ""));
    if (variant == "" && getenv("SB_VARIANT_STATE_FILE") == null)
        variant = trim(as_string(fs.readfile("/etc/tachyon/sing-box-variant") || ""));
    let version = trim(as_string(fs.readfile(getenv("SB_VERSION_STATE_FILE") || "/etc/tachyon/tachyon-core-version") || ""));
    if (version == "" && getenv("SB_VERSION_STATE_FILE") == null)
        version = trim(as_string(fs.readfile("/etc/tachyon/sing-box-version") || ""));
    if (variant != "tachyon-core" && match(version, /-tachyon\./) == null)
        return "component";

    let settings = object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    let mode = trim(as_string(common.option(settings, "fptn_mode", "") || ""));
    if (mode == "native" || mode == "component")
        return mode;

    let has_binary = fs.stat("/usr/bin/fptn-client-cli") != null || fs.stat("/usr/bin/fptn-client") != null;
    return has_binary ? "component" : "native";
}

function normalize_action(action) {
    action = as_string(action);
    return is_connections_action(action) ? "connection" : action;
}

function action(section) {
    return normalize_action(option(section, "action", ""));
}

// Imported .conf entries. Shared by the connection path (each entry becomes a
// vpn:// link) and the AmneziaWG path (each entry becomes its own endpoint).
function condition_section(id) {
    let item = child_section("condition", id);
    return (type(item) == "object" && section_name(item) != "") ? item : null;
}

function condition_sections() {
    return object_or_empty(object_or_empty(get_item_sections())["condition"]).list || [];
}

function outbound_source_section(id) {
    let item = child_section("outbound_source", id);
    return (type(item) == "object" && section_name(item) != "") ? item : null;
}

function outbound_source_sections() {
    return object_or_empty(object_or_empty(get_item_sections())["outbound_source"]).list || [];
}

function outbound_group_section(id) {
    let item = child_section("outbound_group", id);
    return (type(item) == "object" && section_name(item) != "") ? item : null;
}

function outbound_group_sections() {
    return object_or_empty(object_or_empty(get_item_sections())["outbound_group"]).list || [];
}

function balancer_section(id) {
    let item = child_section("balancer", id);
    return (type(item) == "object" && section_name(item) != "") ? item : null;
}

function balancer_sections() {
    return object_or_empty(object_or_empty(get_item_sections())["balancer"]).list || [];
}

function section_condition_refs(section) {
    return whitespace_list_value(section, "condition_refs");
}

function section_outbound_source_refs(section) {
    return whitespace_list_value(section, "outbound_source_refs");
}

function section_outbound_group_refs(section) {
    return whitespace_list_value(section, "outbound_group_refs");
}

function section_balancer_refs(section) {
    return whitespace_list_value(section, "balancer_refs");
}

function outbound_source_by_url(value) {
    value = as_string(value);
    if (value == "")
        return null;
    for (let src in outbound_source_sections()) {
        if (!bool_option(src, "enabled", true))
            continue;
        if (option(src, "url", "") == value)
            return src;
    }
    return null;
}

function outbound_source_by_interface(value) {
    value = as_string(value);
    if (value == "")
        return null;
    for (let src in outbound_source_sections()) {
        if (!bool_option(src, "enabled", true))
            continue;
        let iname = option(src, "interface_name", option(src, "name", ""));
        if (iname == value)
            return src;
    }
    return null;
}

function subscription_source_item(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child;
    return outbound_source_by_url(value);
}

function interface_source_item(section, value) {
    let child = child_item_by_value(section, "section_interface", "name", value);
    if (child != null)
        return child;
    return outbound_source_by_interface(value);
}

function is_dpi_or_desync_source_type(stype) {
    stype = lc(trim(as_string(stype)));
    return stype == "zapret" || stype == "zapret2" || stype == "byedpi" || stype == "desync";
}

function section_effective_outbound_sources(section) {
    let result = [];
    let seen = {};
    let add_src = function(src) {
        if (type(src) != "object" || !bool_option(src, "enabled", true))
            return;
        let id = section_name(src);
        if (id == "" || seen[id])
            return;
        seen[id] = true;
        push(result, src);
    };
    let add_grp = function(grp_id) {
        let grp = outbound_group_section(grp_id);
        if (grp == null || !bool_option(grp, "enabled", true))
            return;
        let grp_sources = whitespace_list_value(grp, "source_refs");
        if (length(grp_sources) == 0 || grp_sources[0] == "*") {
            for (let src in outbound_source_sections()) {
                if (!is_dpi_or_desync_source_type(option(src, "source_type", "")))
                    add_src(src);
            }
        } else {
            for (let src_id in grp_sources)
                add_src(outbound_source_section(src_id));
        }
    };

    for (let src_id in section_outbound_source_refs(section))
        add_src(outbound_source_section(src_id));

    for (let grp_id in section_outbound_group_refs(section))
        add_grp(grp_id);

    for (let bal_id in section_balancer_refs(section)) {
        let bal = balancer_section(bal_id);
        if (bal == null || !bool_option(bal, "enabled", true))
            continue;
        let bal_srcs = whitespace_list_value(bal, "source_refs");
        let bal_grps = whitespace_list_value(bal, "group_refs");
        let bal_lvls = whitespace_list_value(bal, "outbound_group_levels");
        for (let src_id in bal_srcs)
            add_src(outbound_source_section(src_id));
        for (let grp_id in bal_grps)
            add_grp(grp_id);
        for (let lvl_ref in bal_lvls) {
            if (lc(lvl_ref) != "direct")
                add_grp(lvl_ref);
        }
        if (length(bal_srcs) == 0 && length(bal_grps) == 0 && length(bal_lvls) == 0 && length(result) == 0) {
            for (let src in outbound_source_sections()) {
                if (!is_dpi_or_desync_source_type(option(src, "source_type", "")))
                    add_src(src);
            }
        }
    }
    return result;
}

// The token an FPTN section dials with: checks linked outbound_source items
// first, then the explicit access_token when there is one, otherwise the first
// fptn:// link pasted into the section URL list.
function fptn_section_token(section) {
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", ""));
        let stoken = trim(as_string(option(src, "access_token", "")));
        if (stoken != "" && (stype == "fptn" || substr(stoken, 0, 6) == "fptnb:" || substr(stoken, 0, 5) == "fptn:"))
            return stoken;
    }
    let token = trim(as_string(option(section, "access_token", "")));
    if (token != "")
        return token;
    let links = raw_option(section, "selector_proxy_links");
    if (links == null || links == "")
        links = [];
    if (type(links) != "array")
        links = [links];
    // The text variant of the same field, kept for configs that carry it.
    let text = option(section, "selector_proxy_links_text", "");
    if (text != "") {
        for (let line in split(text, /[\r\n]+/)) {
            line = trim(line);
            if (line != "" && match(line, /^[^#\s]/))
                push(links, line);
        }
    }
    for (let link in links) {
        link = trim(as_string(link));
        if (substr(link, 0, 6) == "fptnb:" || substr(link, 0, 5) == "fptn:")
            return link;
    }
    return "";
}

function push_unique_str(arr, seen, val) {
    val = as_string(val);
    if (val == "" || seen[val])
        return;
    seen[val] = true;
    push(arr, val);
}

function normalize_amnezia_config_entry(raw_val, fallback_name) {
    let val = trim(as_string(raw_val));
    if (val == "")
        return "";
    if (substr(val, 0, 1) == "{")
        return val;
    if (index(val, "[Interface]") >= 0 && index(val, "[Peer]") >= 0) {
        let nm = trim(as_string(fallback_name || "AmneziaWG"));
        if (nm == "")
            nm = "AmneziaWG";
        return sprintf("%J", { name: nm, config: val });
    }
    return val;
}

function synthesize_awg_conf_from_source(src) {
    let priv = trim(option(src, "awg_private_key", ""));
    let srv_addr = trim(option(src, "awg_server_address", ""));
    let srv_port = trim(option(src, "awg_server_port", ""));
    let pub = trim(option(src, "awg_peer_public_key", ""));
    if (priv == "" || srv_addr == "" || srv_port == "" || pub == "")
        return "";
    let addr_list = list_value(src, "awg_local_address");
    let addr_str = length(addr_list) > 0 ? join(", ", addr_list) : "10.8.1.2/32";
    let lines = [
        "[Interface]",
        "PrivateKey = " + priv,
        "Address = " + addr_str
    ];
    let mtu = trim(option(src, "awg_mtu", ""));
    if (mtu != "")
        push(lines, "MTU = " + mtu);
    for (let pair in [
        [ "Jc", "awg_jc" ],
        [ "Jmin", "awg_jmin" ],
        [ "Jmax", "awg_jmax" ],
        [ "S1", "awg_s1" ],
        [ "S2", "awg_s2" ],
        [ "S3", "awg_s3" ],
        [ "S4", "awg_s4" ],
        [ "H1", "awg_h1" ],
        [ "H2", "awg_h2" ],
        [ "H3", "awg_h3" ],
        [ "H4", "awg_h4" ],
        [ "I1", "awg_i1" ],
        [ "I2", "awg_i2" ],
        [ "I3", "awg_i3" ],
        [ "I4", "awg_i4" ],
        [ "I5", "awg_i5" ],
        [ "J1", "awg_j1" ],
        [ "J2", "awg_j2" ],
        [ "J3", "awg_j3" ],
        [ "Itime", "awg_itime" ],
        [ "HeaderProtectionKey", "awg_header_protection_key" ],
        [ "ContentPaddingAddition", "awg_content_padding_addition" ],
        [ "RekeyAfterTime", "awg_rekey_after_time" ],
        [ "RekeyTimeout", "awg_rekey_timeout" ],
        [ "RejectAfterTime", "awg_reject_after_time" ],
        [ "KeepaliveTimeout", "awg_keepalive_timeout" ],
        [ "MaxHandshakeAttempts", "awg_max_handshake_attempts" ]
    ]) {
        let v = trim(option(src, pair[1], ""));
        if (v != "" && v != "0")
            push(lines, pair[0] + " = " + v);
        else if (v == "0" && (pair[0] == "S1" || pair[0] == "S2" || pair[0] == "S3" || pair[0] == "S4"))
            push(lines, pair[0] + " = 0");
    }
    if (bool_option(src, "awg_random_trailers", false))
        push(lines, "RandomTrailers = 1");
    if (bool_option(src, "awg_disable_cookies", false))
        push(lines, "DisableCookies = 1");
    push(lines, "");
    push(lines, "[Peer]");
    push(lines, "PublicKey = " + pub);
    let psk = trim(option(src, "awg_preshared_key", ""));
    if (psk != "")
        push(lines, "PresharedKey = " + psk);
    let ep_host = index(srv_addr, ":") >= 0 && substr(srv_addr, 0, 1) != "[" ? ("[" + srv_addr + "]") : srv_addr;
    push(lines, "Endpoint = " + ep_host + ":" + srv_port);
    push(lines, "AllowedIPs = 0.0.0.0/0, ::/0");
    let ka = trim(option(src, "awg_keepalive", "25"));
    if (ka != "")
        push(lines, "PersistentKeepalive = " + ka);

    let nm = trim(option(src, "name", section_name(src) || "AmneziaWG"));
    return sprintf("%J", { name: nm != "" ? nm : "AmneziaWG", config: join("\n", lines) });
}

function raw_amnezia_configs_from_obj(obj) {
    let configs = raw_option(obj, "selector_amnezia_configs");
    if (configs == null || configs == "")
        configs = raw_option(obj, "amnezia_configs");
    let result = [];
    let fallback_name = option(obj, "name", section_name(obj) || "AmneziaWG");
    if (configs != null && configs != "") {
        let arr = type(configs) == "array" ? configs : [configs];
        for (let c in arr) {
            let norm = normalize_amnezia_config_entry(c, fallback_name);
            if (norm != "")
                push(result, norm);
        }
    }
    let raw_conf_text = trim(option(obj, "amnezia_conf_text", ""));
    if (raw_conf_text != "") {
        let norm_text = normalize_amnezia_config_entry(raw_conf_text, fallback_name);
        if (norm_text != "")
            push(result, norm_text);
    }
    return result;
}

function amnezia_configs(section) {
    let result = [];
    let seen = {};
    for (let c in raw_amnezia_configs_from_obj(section))
        push_unique_str(result, seen, c);
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "amnezia_config" || stype == "awg" || raw_option(src, "amnezia_configs") != null || raw_option(src, "selector_amnezia_configs") != null || raw_option(src, "amnezia_conf_text") != null) {
            for (let c in raw_amnezia_configs_from_obj(src))
                push_unique_str(result, seen, c);
        }
        if (stype == "awg") {
            let synth = synthesize_awg_conf_from_source(src);
            if (synth != "")
                push_unique_str(result, seen, synth);
        }
    }
    return result;
}

function connection_urls(section) {
    let links = [];
    let seen = {};
    for (let l in whitespace_list_value(section, "selector_proxy_links"))
        push_unique_str(links, seen, l);
    let importer = require("subscription.amnezia_config");
    for (let value in amnezia_configs(section)) {
        let item = importer.parse(value);
        if (item == null) die("Invalid imported Amnezia configuration");
        push_unique_str(links, seen, item.link);
    }
    let text = option(section, "selector_proxy_links_text", "");
    if (text != "") {
        for (let line in split(text, /[\r\n]+/)) {
            line = trim(line);
            if (line != "" && match(line, /^[^#\s]/))
                push_unique_str(links, seen, line);
        }
    }
    let sec_action = action(section);
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "proxy_links" || stype == "links" || raw_option(src, "proxy_links") != null || raw_option(src, "selector_proxy_links") != null) {
            for (let l in whitespace_list_value(src, "proxy_links"))
                push_unique_str(links, seen, l);
            for (let l in whitespace_list_value(src, "selector_proxy_links"))
                push_unique_str(links, seen, l);
            let stext = option(src, "proxy_links_text", option(src, "selector_proxy_links_text", ""));
            if (stext != "") {
                for (let line in split(stext, /[\r\n]+/)) {
                    line = trim(line);
                    if (line != "" && match(line, /^[^#\s]/))
                        push_unique_str(links, seen, line);
                }
            }
        }
        if (stype == "fptn" && sec_action != "fptn") {
            let ftoken = trim(option(src, "access_token", ""));
            if (ftoken != "") {
                if (index(ftoken, "#") < 0) {
                    let fname = trim(option(src, "name", "FPTN"));
                    if (fname != "")
                        ftoken = ftoken + "#" + fname;
                }
                push_unique_str(links, seen, ftoken);
            }
        }
        if (stype == "tor" && sec_action != "tor") {
            let tor_port = trim(option(src, "tor_socks_port", "9050")) || "9050";
            let tor_name = trim(option(src, "name", "Tor")) || "Tor";
            push_unique_str(links, seen, "socks5://127.0.0.1:" + tor_port + "#" + tor_name);
        }
    }
    return links;
}

function urltest_text_links(section) {
    let text = option(section, "urltest_proxy_links_text", "");
    if (text == "")
        return [];
    let links = [];
    for (let line in split(text, /[\r\n]+/)) {
        line = trim(line);
        if (line != "" && match(line, /^[^#\s]/))
            push(links, line);
    }
    return links;
}

function subscription_urls(section) {
    let result = [];
    let seen = {};
    for (let u in child_values(section, "subscription_url", "url", "subscription_urls"))
        push_unique_str(result, seen, u);
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "subscription" || option(src, "url", "") != "") {
            let u = trim(option(src, "url", ""));
            if (u != "")
                push_unique_str(result, seen, u);
        }
    }
    return result;
}

function interfaces(section) {
    let result = [];
    let seen = {};
    let items = child_values(section, "section_interface", "name", "");
    if (length(items) > 0) {
        for (let it in items)
            push_unique_str(result, seen, it);
    } else {
        for (let it in list_value(section, "interfaces"))
            push_unique_str(result, seen, it);
        if (length(result) == 0) {
            let value = option(section, "interface", "");
            if (value != "")
                push_unique_str(result, seen, value);
        }
    }
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "interface") {
            let iname = trim(option(src, "interface_name", option(src, "interface", "")));
            if (iname != "")
                push_unique_str(result, seen, iname);
        }
        else if (stype == "tailscale") {
            let ts_iface = trim(option(src, "interface_name", "tailscale0")) || "tailscale0";
            push_unique_str(result, seen, ts_iface);
        }
    }
    return result;
}

function is_dpi_or_desync_only_section(section) {
    if (type(section) != "object")
        return false;
    let act = lc(trim(option(section, "action", "")));
    if (act == "zapret" || act == "zapret2" || act == "byedpi" || act == "desync")
        return true;
    if (!is_connections_action(act))
        return false;
    if (length(connection_urls(section)) > 0 ||
        length(subscription_urls(section)) > 0 ||
        length(interfaces(section)) > 0 ||
        length(list_value(section, "outbound_jsons")) > 0 ||
        trim(option(section, "outbound_json", "")) != "")
        return false;
    let eff_sources = section_effective_outbound_sources(section);
    if (length(eff_sources) == 0)
        return false;
    for (let src in eff_sources) {
        let stype = option(src, "source_type", "subscription");
        if (!is_dpi_or_desync_source_type(stype))
            return false;
    }
    return true;
}

function is_remote_proxy_section(section) {
    if (type(section) != "object")
        return false;
    let act = option(section, "action", "");
    if (!is_remote_proxy_action(act))
        return false;
    if (is_dpi_or_desync_only_section(section))
        return false;
    return true;
}

function synthesize_protocol_outbound_json_from_source(src, stype) {
    let tag_name = trim(option(src, "name", section_name(src))) || section_name(src);
    if (stype == "anytls") {
        let srv = trim(option(src, "anytls_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "anytls",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "anytls_server_port", option(src, "anytls_port", option(src, "server_port", "443"))) || 443),
            password: option(src, "anytls_password", option(src, "password", "")),
            tls: {
                enabled: true,
                server_name: option(src, "anytls_sni", option(src, "sni", srv)) || srv,
                insecure: bool_option(src, "anytls_insecure", false)
            }
        };
        let min_idle = int(option(src, "anytls_min_idle_session", "0") || 0);
        if (min_idle > 0) obj.min_idle_session = min_idle;
        let ci = trim(option(src, "anytls_idle_session_check_interval", ""));
        if (ci != "") obj.idle_session_check_interval = ci;
        let ito = trim(option(src, "anytls_idle_session_timeout", ""));
        if (ito != "") obj.idle_session_timeout = ito;
        return sprintf("%J", obj);
    }
    if (stype == "naive") {
        let srv = trim(option(src, "naive_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "naive",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "naive_server_port", option(src, "naive_port", option(src, "server_port", "443"))) || 443),
            username: option(src, "naive_username", option(src, "username", "")),
            password: option(src, "naive_password", option(src, "password", "")),
            tls: {
                enabled: true,
                server_name: option(src, "naive_sni", option(src, "sni", srv)) || srv
            }
        };
        if (bool_option(src, "naive_quic", false))
            obj.quic = true;
        let cc = trim(option(src, "naive_quic_congestion_control", ""));
        if (cc != "") obj.quic_congestion_control = cc;
        let conc = int(option(src, "naive_insecure_concurrency", "0") || 0);
        if (conc > 0) obj.insecure_concurrency = conc;
        if (bool_option(src, "naive_uot", false))
            obj.udp_over_tcp = true;
        let raw_hdrs = trim(option(src, "naive_extra_headers", ""));
        if (raw_hdrs != "") {
            let parsed_hdrs = null;
            if (substr(raw_hdrs, 0, 1) == "{") {
                try { parsed_hdrs = json(raw_hdrs); } catch (e) { parsed_hdrs = null; }
            }
            if (type(parsed_hdrs) == "object") {
                obj.extra_headers = parsed_hdrs;
            } else {
                let hdrs = {};
                for (let line in split(raw_hdrs, /\r?\n/)) {
                    let colon = index(line, ":");
                    if (colon > 0) {
                        let hk = trim(substr(line, 0, colon));
                        let hv = trim(substr(line, colon + 1));
                        if (hk != "") hdrs[hk] = hv;
                    }
                }
                if (length(keys(hdrs)) > 0)
                    obj.extra_headers = hdrs;
            }
        }
        return sprintf("%J", obj);
    }
    if (stype == "mieru") {
        let srv = trim(option(src, "mieru_server", option(src, "server", "")));
        if (srv == "") return "";
        let single_p = int(option(src, "mieru_server_port", option(src, "server_port", "1080")) || 1080);
        let ports = list_value(src, "mieru_server_ports");
        if (length(ports) == 0)
            ports = list_value(src, "mieru_port_bindings");
        let obj = {
            type: "mieru",
            tag: tag_name,
            server: srv,
            server_port: single_p,
            transport: uc(option(src, "mieru_transport", "TCP")),
            username: option(src, "mieru_username", option(src, "username", "")),
            password: option(src, "mieru_password", option(src, "password", ""))
        };
        if (length(ports) > 0)
            obj.server_ports = ports;
        let mux = trim(option(src, "mieru_multiplexing", ""));
        if (mux != "") obj.multiplexing = mux;
        let hmode = trim(option(src, "mieru_handshake_mode", ""));
        if (hmode != "") obj.handshake_mode = hmode;
        let tpat = trim(option(src, "mieru_traffic_pattern", ""));
        if (tpat != "") obj.traffic_pattern = tpat;
        return sprintf("%J", obj);
    }
    if (stype == "trusttunnel") {
        let srv = trim(option(src, "trusttunnel_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "trusttunnel",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "trusttunnel_server_port", option(src, "trusttunnel_port", option(src, "server_port", "443"))) || 443),
            username: option(src, "trusttunnel_username", option(src, "username", "")),
            password: option(src, "trusttunnel_password", option(src, "password", "")),
            tls: {
                enabled: true,
                server_name: option(src, "trusttunnel_sni", option(src, "sni", srv)) || srv,
                insecure: bool_option(src, "trusttunnel_insecure", false)
            }
        };
        let alpn = list_value(src, "trusttunnel_alpn");
        if (length(alpn) > 0)
            obj.tls.alpn = alpn;
        if (bool_option(src, "trusttunnel_quic", false))
            obj.quic = "true";
        if (bool_option(src, "trusttunnel_health_check", false))
            obj.health_check = true;
        let cc = trim(option(src, "trusttunnel_congestion_control", ""));
        if (cc != "") obj.quic_congestion_control = cc;
        return sprintf("%J", obj);
    }
    if (stype == "tewfai") {
        let srv = trim(option(src, "tewfai_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "tewfai",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "tewfai_server_port", option(src, "tewfai_port", option(src, "server_port", "443"))) || 443),
            uuid: option(src, "tewfai_uuid", option(src, "uuid", option(src, "username", ""))),
            tls: {
                enabled: true,
                server_name: option(src, "tewfai_sni", option(src, "sni", srv)) || srv,
                insecure: bool_option(src, "tewfai_insecure", false)
            }
        };
        let pwd = option(src, "tewfai_password", option(src, "password", ""));
        if (pwd != "") obj.password = pwd;
        let raw_tr = list_value(src, "tewfai_transport");
        let tr_list = [];
        for (let item in raw_tr) {
            item = lc(trim(as_string(item)));
            if (item == "raw_tls" || item == "h2" || item == "ws") item = "tcp";
            else if (item == "h3_stream" || item == "h3_datagram") item = "quic";
            if ((item == "tcp" || item == "quic") && index(tr_list, item) < 0)
                push(tr_list, item);
        }
        if (length(tr_list) > 0) obj.transport = tr_list;
        let cipher = trim(option(src, "tewfai_inner_cipher", ""));
        if (cipher == "aes-256-gcm" || cipher == "none") obj.inner_cipher = cipher;
        let morph = trim(option(src, "tewfai_morph_profile", ""));
        if (morph == "browsing" || morph == "video" || morph == "webrtc" || morph == "bulk")
            obj.morph_profile = morph;
        let max_s = int(option(src, "tewfai_max_streams", "0") || 0);
        if (max_s > 0) obj.max_streams = max_s;
        let mtu = int(option(src, "tewfai_mtu", "0") || 0);
        if (mtu > 0) obj.mtu = mtu;
        if (bool_option(src, "tewfai_pqc_enabled", false)) obj.pqc = true;
        if (bool_option(src, "tewfai_handover_enabled", false)) obj.handover = { enabled: true };
        if (bool_option(src, "tewfai_fec_enabled", false)) obj.fec = true;
        return sprintf("%J", obj);
    }
    if (stype == "masque") {
        let srv = trim(option(src, "masque_server", option(src, "server", "162.159.198.2"))) || "162.159.198.2";
        let priv = trim(option(src, "masque_private_key", ""));
        let acc = trim(option(src, "masque_account_id", ""));
        let tok = trim(option(src, "masque_access_token", option(src, "password", "")));
        if (priv == "" && acc == "" && trim(option(src, "masque_server", option(src, "server", ""))) == "")
            return "";
        let profile = option(src, "masque_profile", "cloudflare") || "cloudflare";
        let obj = {
            type: "masque",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "masque_server_port", option(src, "masque_port", option(src, "server_port", "443"))) || 443),
            profile
        };
        let vhttp = trim(option(src, "masque_vhttp", ""));
        if (vhttp != "") obj.vhttp = vhttp;
        if (priv != "") obj.private_key = priv;
        let pub = trim(option(src, "masque_public_key", ""));
        if (pub != "") obj.public_key = pub;
        let ip = trim(option(src, "masque_ip", profile == "cloudflare" ? "172.16.0.2/32" : ""));
        if (ip != "") obj.ip = ip;
        let ipv6 = trim(option(src, "masque_ipv6", ""));
        if (ipv6 != "") obj.ipv6 = ipv6;
        let uri = trim(option(src, "masque_uri", ""));
        if (uri != "") obj.uri = uri;
        let mtu = int(option(src, "masque_mtu", "0") || 0);
        if (mtu > 0) obj.mtu = mtu;
        if (tok != "") obj.auth_token = tok;
        let sni = trim(option(src, "masque_sni", option(src, "sni", "")));
        let insec = bool_option(src, "masque_insecure", false);
        let frag = bool_option(src, "masque_fragment", false);
        let rfrag = bool_option(src, "masque_record_fragment", false);
        if (sni != "" || insec || frag || rfrag) {
            let tls = { enabled: true };
            if (sni != "") tls.server_name = sni;
            if (insec) tls.insecure = true;
            if (frag) tls.fragment = true;
            if (rfrag) tls.record_fragment = true;
            obj.tls = tls;
        }
        return sprintf("%J", obj);
    }
    if (stype == "openconnect") {
        let srv = trim(option(src, "openconnect_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "openconnect",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "openconnect_server_port", option(src, "openconnect_port", option(src, "server_port", "443"))) || 443),
            flavor: option(src, "openconnect_flavor", "anyconnect") || "anyconnect",
            tls: {
                enabled: true,
                server_name: option(src, "openconnect_sni", option(src, "sni", srv)) || srv,
                insecure: bool_option(src, "openconnect_insecure", false)
            }
        };
        let usr = option(src, "openconnect_username", option(src, "openconnect_user", option(src, "username", "")));
        if (usr != "") obj.username = usr;
        let pwd = option(src, "openconnect_password", option(src, "password", ""));
        if (pwd != "") obj.password = pwd;
        let ag = option(src, "openconnect_authgroup", "");
        if (ag != "") obj.authgroup = ag;
        let ua = option(src, "openconnect_useragent", "");
        if (ua != "") obj.useragent = ua;
        let ocos = option(src, "openconnect_os", "");
        if (ocos != "") obj.os = ocos;
        let ck = option(src, "openconnect_cookie", "");
        if (ck != "") obj.cookie = ck;
        let up = option(src, "openconnect_urlpath", "");
        if (up != "") obj.urlpath = up;
        let rlm = option(src, "openconnect_realm", "");
        if (rlm != "") obj.realm = rlm;
        let pin = option(src, "openconnect_server_cert_pin", "");
        if (pin != "") obj.server_cert_pin = pin;
        if (bool_option(src, "openconnect_dtls", true)) obj.dtls = true;
        if (bool_option(src, "openconnect_esp", false)) obj.esp = true;
        let mtu = int(option(src, "openconnect_mtu", "0") || 0);
        if (mtu > 0) obj.mtu = as_string(mtu);
        return sprintf("%J", obj);
    }
    if (stype == "shadowtls") {
        let srv = trim(option(src, "shadowtls_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "shadowtls",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "shadowtls_server_port", option(src, "shadowtls_port", option(src, "server_port", "443"))) || 443),
            version: int(option(src, "shadowtls_version", "3") || 3),
            password: option(src, "shadowtls_password", option(src, "password", "")),
            tls: {
                enabled: true,
                server_name: option(src, "shadowtls_sni", option(src, "sni", srv)) || srv
            }
        };
        if (bool_option(src, "shadowtls_insecure", false))
            obj.tls.insecure = true;
        return sprintf("%J", obj);
    }
    if (stype == "snell") {
        let srv = trim(option(src, "snell_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "snell",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "snell_server_port", option(src, "snell_port", option(src, "server_port", "8388"))) || 8388),
            psk: option(src, "snell_psk", option(src, "password", "")),
            version: int(option(src, "snell_version", "4") || 4)
        };
        let obfs = trim(option(src, "snell_obfs", ""));
        if (obfs != "" && obfs != "none") {
            obj.obfs = { type: obfs };
            let ohost = trim(option(src, "snell_obfs_host", ""));
            if (ohost != "") obj.obfs.host = ohost;
        }
        if (bool_option(src, "snell_uot", false))
            obj.udp_over_tcp = true;
        return sprintf("%J", obj);
    }
    if (stype == "sudoku") {
        let srv = trim(option(src, "sudoku_server", option(src, "server", "")));
        if (srv == "") return "";
        let obj = {
            type: "sudoku",
            tag: tag_name,
            server: srv,
            server_port: int(option(src, "sudoku_server_port", option(src, "sudoku_port", option(src, "server_port", "8443"))) || 8443),
            key: option(src, "sudoku_key", option(src, "password", ""))
        };
        let aead = trim(option(src, "sudoku_aead_method", ""));
        if (aead != "") obj.aead_method = aead;
        return sprintf("%J", obj);
    }
    if (stype == "warp") {
        let pk = trim(option(src, "warp_private_key", ""));
        if (pk == "") return "";
        let acc = trim(option(src, "warp_account_id", ""));
        let tok = trim(option(src, "warp_access_token", ""));
        if (acc != "" || tok != "") {
            let m_obj = {
                type: "masque",
                tag: tag_name,
                server: "162.159.198.2",
                server_port: 443,
                profile: "cloudflare",
                private_key: pk,
                ip: "172.16.0.2/32"
            };
            if (tok != "") m_obj.auth_token = tok;
            return sprintf("%J", m_obj);
        }
        return sprintf("%J", {
            type: "wireguard",
            tag: tag_name,
            server: option(src, "warp_endpoint_host", "engage.cloudflareclient.com"),
            server_port: int(option(src, "warp_endpoint_port", "2408") || 2408),
            private_key: pk,
            peer_public_key: option(src, "warp_peer_public_key", "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="),
            local_address: [ option(src, "warp_local_v4", "172.16.0.2/32") ]
        });
    }
    if (stype == "desync") {
        let norm_preset = function(val) {
            val = lc(trim(as_string(val)));
            if (val == "" || val == "none" || val == "custom") return "";
            if (val in ["fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "auto"])
                return val == "fakesplit" ? "fake_split" : (val == "tls_rec" ? "tlsrec" : val);
            if (val == "youtube" || val == "google_youtube" || val == "discord" || val == "general" || val == "general_fake_tls")
                return "fake_split";
            if (val == "general_alt")
                return "tlsrec";
            if (val == "aggressive" || val == "general_alt2" || val == "general_multisplit")
                return "disorder";
            if (val == "light" || val == "general_simple_fake")
                return "split";
            return "fake_split";
        };
        let norm_mode = function(val) {
            val = lc(trim(as_string(val)));
            if (val == "") return "";
            if (val in ["fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "none"])
                return val == "fakesplit" ? "fake_split" : (val == "tls_rec" ? "tlsrec" : val);
            if (val == "fake+split")
                return "fake_split";
            if (val == "fake+disorder" || val == "fake_disorder" || val == "fakedisorder" || val == "multidisorder")
                return "disorder";
            if (val == "multisplit")
                return "split";
            return "fake_split";
        };
        let norm_split_pos = function(val) {
            val = lc(trim(as_string(val)));
            if (val == "midsld" || val == "sld" || val == "host")
                return "midsld";
            if (val == "sni" || val == "sniext")
                return "sni";
            if (val != "" && match(val, /^[0-9]+$/)) {
                let n = int(val, 10);
                if (n >= 1 && n <= 1400)
                    return n;
            }
            return null;
        };
        let ds_obj = {
            type: "desync",
            tag: tag_name
        };
        let raw_preset = trim(option(src, "desync_preset", ""));
        let preset = norm_preset(raw_preset);
        let mode = norm_mode(option(src, "desync_mode", ""));
        if (preset != "")
            ds_obj.preset = preset;
        if (mode != "")
            ds_obj.mode = mode;
        if (lc(raw_preset) == "discord" && !bool_option(src, "desync_udp_fake", false))
            ds_obj.udp_fake = true;
        if (ds_obj.preset == null && ds_obj.mode == null)
            ds_obj.preset = "fake_split";
        let sp = norm_split_pos(option(src, "desync_split_pos", ""));
        if (sp != null)
            ds_obj.split_pos = sp;
        let fttl = int(option(src, "desync_fake_ttl", "0") || 0);
        if (fttl > 0)
            ds_obj.fake_ttl = fttl;
        let fsni = trim(option(src, "desync_fake_sni", ""));
        if (fsni != "")
            ds_obj.fake_sni = fsni;
        let reps = int(option(src, "desync_repeats", "0") || 0);
        if (reps > 0)
            ds_obj.repeats = reps;
        let sdelay = trim(option(src, "desync_split_delay_ms", ""));
        if (sdelay != "" && match(sdelay, /^[0-9]+$/))
            ds_obj.split_delay_ms = int(sdelay, 10);
        if (bool_option(src, "desync_udp_fake", false))
            ds_obj.udp_fake = true;
        let ureps = int(option(src, "desync_udp_repeats", "0") || 0);
        if (ureps > 0)
            ds_obj.udp_repeats = ureps;
        let uttl = int(option(src, "desync_udp_fake_ttl", "0") || 0);
        if (uttl > 0)
            ds_obj.udp_fake_ttl = uttl;
        let opts_str = trim(option(src, "desync_opts", ""));
        if (opts_str != "") {
            for (let token in split(opts_str, /\s+/)) {
                let eq = index(token, "=");
                if (eq <= 0) continue;
                let k = lc(trim(substr(token, 0, eq)));
                if (substr(k, 0, 2) == "--")
                    k = replace(substr(k, 2), /-/g, "_");
                let v = trim(substr(token, eq + 1));
                if (v == "") continue;
                if (k == "preset") {
                    let np = norm_preset(v);
                    if (np != "") ds_obj.preset = np;
                } else if (k == "mode") {
                    let nm = norm_mode(v);
                    if (nm != "") ds_obj.mode = nm;
                } else if (k == "split_pos") {
                    let nsp = norm_split_pos(v);
                    if (nsp != null) ds_obj.split_pos = nsp;
                } else if (k == "fake_ttl" && match(v, /^[0-9]+$/)) ds_obj.fake_ttl = int(v, 10);
                else if (k == "fake_sni") ds_obj.fake_sni = v;
                else if (k == "repeats" && match(v, /^[0-9]+$/)) ds_obj.repeats = int(v, 10);
                else if (k == "split_delay_ms" && match(v, /^[0-9]+$/)) ds_obj.split_delay_ms = int(v, 10);
                else if (k == "udp_fake") ds_obj.udp_fake = (lc(v) == "1" || lc(v) == "true" || lc(v) == "yes");
                else if (k == "udp_repeats" && match(v, /^[0-9]+$/)) ds_obj.udp_repeats = int(v, 10);
                else if (k == "udp_fake_ttl" && match(v, /^[0-9]+$/)) ds_obj.udp_fake_ttl = int(v, 10);
            }
        }
        if (ds_obj.preset == "fake_split" || ds_obj.preset == "auto" || ds_obj.preset == "fake") {
            ds_obj.preset = "disorder";
            if (ds_obj.split_pos == null) ds_obj.split_pos = "midsld";
            if (ds_obj.udp_fake == null) ds_obj.udp_fake = true;
        }
        if (ds_obj.mode == "fake_split" || ds_obj.mode == "fake") {
            ds_obj.mode = "disorder";
            if (ds_obj.split_pos == null) ds_obj.split_pos = "midsld";
        }
        return sprintf("%J", ds_obj);
    }
    return "";
}

function source_id_for_manual_item(section, value) {
    value = trim(as_string(value));
    if (value == "" || type(section) != "object")
        return "";
    let importer = null;
    try { importer = require("subscription.amnezia_config"); } catch (e) {}
    for (let src in section_effective_outbound_sources(section)) {
        let src_id = section_name(src);
        if (src_id == "")
            continue;
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "fptn") {
            let ftoken = trim(option(src, "access_token", ""));
            if (ftoken != "" && (value == ftoken || index(value, ftoken + "#") == 0))
                return src_id;
        }
        if (stype == "proxy_links" || stype == "links" || raw_option(src, "proxy_links") != null || raw_option(src, "selector_proxy_links") != null) {
            for (let l in whitespace_list_value(src, "proxy_links"))
                if (trim(as_string(l)) == value) return src_id;
            for (let l in whitespace_list_value(src, "selector_proxy_links"))
                if (trim(as_string(l)) == value) return src_id;
            let stext = option(src, "proxy_links_text", option(src, "selector_proxy_links_text", ""));
            for (let line in split(stext, /[\r\n]+/))
                if (trim(as_string(line)) == value) return src_id;
        }
        if (stype == "amnezia_config" || stype == "awg" || raw_option(src, "amnezia_configs") != null || raw_option(src, "selector_amnezia_configs") != null || raw_option(src, "amnezia_conf_text") != null) {
            let configs = [];
            for (let c in raw_amnezia_configs_from_obj(src))
                push(configs, c);
            if (stype == "awg") {
                let synth = synthesize_awg_conf_from_source(src);
                if (synth != "") push(configs, synth);
            }
            for (let c in configs) {
                if (c == value) return src_id;
                if (importer != null) {
                    let parsed = importer.parse(c);
                    if (parsed != null && parsed.link == value)
                        return src_id;
                }
            }
        }
        if (stype == "interface") {
            let iname = trim(option(src, "interface_name", option(src, "interface", "")));
            if (iname != "" && iname == value)
                return src_id;
        }
        if (stype == "outbound_json" || stype == "json") {
            for (let j in list_value(src, "outbound_jsons"))
                if (trim(as_string(j)) == value) return src_id;
            if (trim(option(src, "outbound_json", "")) == value)
                return src_id;
        }
        let synth_json = synthesize_protocol_outbound_json_from_source(src, stype);
        if (synth_json != "" && synth_json == value)
            return src_id;
    }
    return "";
}

function outbound_jsons(section, raw) {
    // raw=true returns the undeduplicated list: duplicate JSON tags must stay
    // visible to the validator, which push_unique_str would silently merge.
    let result = [];
    let seen = {};
    let add = raw
        ? function (v) { push(result, as_string(v)); }
        : function (v) { push_unique_str(result, seen, v); };
    for (let j in list_value(section, "outbound_jsons"))
        add(j);
    if (length(result) == 0) {
        let value = option(section, "outbound_json", "");
        if (value != "")
            add(value);
    }
    let sec_action = action(section);
    for (let src in section_effective_outbound_sources(section)) {
        let stype = lc(option(src, "source_type", "subscription"));
        if (stype == "outbound_json" || stype == "json") {
            for (let j in list_value(src, "outbound_jsons"))
                add(j);
            let single = option(src, "outbound_json", "");
            if (single != "")
                add(single);
        } else if (sec_action != stype) {
            let synth = synthesize_protocol_outbound_json_from_source(src, stype);
            if (synth != "")
                add(synth);
        }
    }
    return result;
}

function urltests(section) {
    let result = [];
    let seen = {};
    let seen_names = {};
    for (let bal_id in section_balancer_refs(section)) {
        let bal = balancer_section(bal_id);
        if (bal != null && lc(option(bal, "balancer_type", "urltest")) == "urltest") {
            let bname = option(bal, "name", section_name(bal));
            seen_names[bname] = true;
            if (bool_option(bal, "enabled", true))
                push_unique_str(result, seen, section_name(bal));
        }
    }
    for (let child in child_items(section, "urltest")) {
        let id = section_name(child);
        if (id != "") {
            let cname = child_option(child, "name", id);
            if (!seen_names[cname]) {
                seen_names[cname] = true;
                push_unique_str(result, seen, id);
            }
        }
    }
    if (length(result) > 0)
        return result;

    if (option(section, "action", "") == "group")
        return [ "urltest" ];

    return bool_option(section, "urltest_enabled", false) ? [ "urltest" ] : [];
}

function priority_groups(section) {
    let result = [];
    let seen = {};
    let seen_names = {};
    for (let bal_id in section_balancer_refs(section)) {
        let bal = balancer_section(bal_id);
        if (bal != null && lc(option(bal, "balancer_type", "urltest")) == "priority") {
            let bname = option(bal, "name", section_name(bal));
            seen_names[bname] = true;
            if (bool_option(bal, "enabled", true))
                push_unique_str(result, seen, section_name(bal));
        }
    }
    for (let child in child_items(section, "priority_group")) {
        let id = section_name(child);
        if (id != "") {
            let cname = child_option(child, "name", id);
            if (!seen_names[cname]) {
                seen_names[cname] = true;
                push_unique_str(result, seen, id);
            }
        }
    }
    return result;
}

function dashboard_filter_mode(section) {
    return option(section, "dashboard_filter_mode", "disabled") || "disabled";
}

function dashboard_hide_na_servers(section) {
    return bool_option(section, "dashboard_hide_na_servers", false);
}

function dashboard_detect_server_country(section) {
    return option(section, "dashboard_detect_server_country", "flag_emoji") || "flag_emoji";
}

function dashboard_include_countries(section) {
    return list_value(section, "dashboard_include_countries");
}

function dashboard_include_outbounds(section) {
    return list_value(section, "dashboard_include_outbounds");
}

function dashboard_include_regex(section) {
    return list_value(section, "dashboard_include_regex");
}

function dashboard_include_proxy_parameters(section) {
    return bool_option(section, "dashboard_include_proxy_parameters", false);
}

function dashboard_include_protocols(section) {
    return list_value(section, "dashboard_include_protocols");
}

function dashboard_include_transports(section) {
    return list_value(section, "dashboard_include_transports");
}

function dashboard_include_securities(section) {
    return list_value(section, "dashboard_include_securities");
}

function dashboard_include_ports(section) {
    return list_value(section, "dashboard_include_ports");
}

function dashboard_include_groups(section) {
    return list_value(section, "dashboard_include_groups");
}

function dashboard_exclude_countries(section) {
    return list_value(section, "dashboard_exclude_countries");
}

function dashboard_exclude_outbounds(section) {
    return list_value(section, "dashboard_exclude_outbounds");
}

function dashboard_exclude_regex(section) {
    return list_value(section, "dashboard_exclude_regex");
}

function dashboard_exclude_proxy_parameters(section) {
    return bool_option(section, "dashboard_exclude_proxy_parameters", false);
}

function dashboard_exclude_protocols(section) {
    return list_value(section, "dashboard_exclude_protocols");
}

function dashboard_exclude_transports(section) {
    return list_value(section, "dashboard_exclude_transports");
}

function dashboard_exclude_securities(section) {
    return list_value(section, "dashboard_exclude_securities");
}

function dashboard_exclude_ports(section) {
    return list_value(section, "dashboard_exclude_ports");
}

function dashboard_exclude_groups(section) {
    return list_value(section, "dashboard_exclude_groups");
}

function priority_group_child(section, value) {
    let child = owned_child_section(section, "priority_group", value);
    if (child != null)
        return child;
    let bal = balancer_section(value);
    if (bal != null && lc(option(bal, "balancer_type", "urltest")) == "priority")
        return bal;
    return null;
}

function priority_group_settings(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child : {};
}

function child_effective_include_prefixes(child, section) {
    if (child == null)
        return [];
    let raw_mode = lc(trim(child_option_alias(child, [ "filter_mode", "urltest_filter_mode" ], "")));
    if (raw_mode != "disabled" && raw_mode != "exclude") {
        let explicit = child_list_alias(child, [ "include_prefixes", "urltest_include_prefixes" ], []);
        if (length(explicit) > 0)
            return explicit;
    }
    let srefs = whitespace_list_value(child, "source_refs");
    if (length(srefs) == 0 || srefs[0] == "*")
        return [];
    if (type(section) == "object") {
        let eff_srcs = section_effective_outbound_sources(section);
        let non_dpi_ids = [];
        for (let es in eff_srcs) {
            if (!is_dpi_or_desync_source_type(option(es, "source_type", "")))
                push(non_dpi_ids, section_name(es));
        }
        if (length(non_dpi_ids) > 0) {
            let sref_set = {};
            for (let sid in srefs)
                sref_set[sid] = true;
            let all_covered = true;
            for (let sec_sid in non_dpi_ids) {
                if (!sref_set[sec_sid]) {
                    all_covered = false;
                    break;
                }
            }
            if (all_covered)
                return [];
        }
    }
    let sub_items = type(section) == "object" ? child_items(section, "subscription_url") : [];
    let sub_urls = type(section) == "object" ? subscription_urls(section) : [];
    let prefixes = [];
    let seen = {};
    for (let src_id in srefs) {
        let src = outbound_source_section(src_id);
        if (src == null)
            continue;
        let pfx = bool_option(src, "prefix_nodes", true) ? trim(option(src, "node_prefix", "")) : "";
        if (pfx != "")
            push_unique_str(prefixes, seen, pfx);
        let matched_idx = 0;
        let src_url = trim(option(src, "url", ""));
        for (let i = 0; i < length(sub_items); i++) {
            let it = object_or_empty(sub_items[i]);
            if (as_string(it[".name"] || "") == src_id || (src_url != "" && trim(option(it, "url", "")) == src_url)) {
                matched_idx = i + 1;
                break;
            }
        }
        if (matched_idx == 0 && src_url != "") {
            for (let i = 0; i < length(sub_urls); i++) {
                if (trim(as_string(sub_urls[i])) == src_url) {
                    matched_idx = i + 1;
                    break;
                }
            }
        }
        if (matched_idx > 0)
            push_unique_str(prefixes, seen, "sub:" + matched_idx);
        push_unique_str(prefixes, seen, src_id);
    }
    return prefixes;
}

function synthesized_priority_levels_for_balancer(group_id) {
    let bal = balancer_section(group_id);
    if (bal == null || lc(option(bal, "balancer_type", "urltest")) != "priority")
        return [];
    let group_refs = whitespace_list_value(bal, "outbound_group_levels");
    if (length(group_refs) == 0)
        return [];
    let result = [];
    for (let i = 0; i < length(group_refs); i++) {
        let ref = trim(as_string(group_refs[i]));
        if (ref == "")
            continue;
        let synth_id = as_string(group_id) + "_lvl_" + (i + 1);
        if (lc(ref) == "direct") {
            push(result, {
                ".name": synth_id,
                group: as_string(group_id),
                name: "Direct",
                order: as_string(i + 1),
                direct: "1",
                filter_mode: "include"
            });
            continue;
        }
        let grp = outbound_group_section(ref);
        if (grp == null)
            continue;
        let clone = {
            ".name": synth_id,
            group: as_string(group_id),
            name: option(grp, "name", ref) || ref,
            order: as_string(i + 1),
            direct: "0",
            outbound_group_ref: ref,
            filter_mode: option(grp, "filter_mode", "include") || "include",
            detect_server_country: option(grp, "detect_server_country", "flag_emoji") || "flag_emoji",
            include_countries: list_value(grp, "include_countries"),
            include_outbounds: list_value(grp, "include_outbounds"),
            include_regex: list_value(grp, "include_regex"),
            include_prefixes: child_effective_include_prefixes(grp, null),
            include_proxy_parameters: (bool_option(grp, "include_proxy_parameters", false) ||
                length(list_value(grp, "include_protocols")) > 0 ||
                length(list_value(grp, "include_transports")) > 0 ||
                length(list_value(grp, "include_securities")) > 0 ||
                length(list_value(grp, "include_ports")) > 0) ? "1" : "0",
            include_protocols: list_value(grp, "include_protocols"),
            include_transports: list_value(grp, "include_transports"),
            include_securities: list_value(grp, "include_securities"),
            include_ports: list_value(grp, "include_ports"),
            exclude_countries: list_value(grp, "exclude_countries"),
            exclude_outbounds: list_value(grp, "exclude_outbounds"),
            exclude_regex: list_value(grp, "exclude_regex"),
            exclude_prefixes: list_value(grp, "exclude_prefixes"),
            exclude_proxy_parameters: (bool_option(grp, "exclude_proxy_parameters", false) ||
                length(list_value(grp, "exclude_protocols")) > 0 ||
                length(list_value(grp, "exclude_transports")) > 0 ||
                length(list_value(grp, "exclude_securities")) > 0 ||
                length(list_value(grp, "exclude_ports")) > 0) ? "1" : "0",
            exclude_protocols: list_value(grp, "exclude_protocols"),
            exclude_transports: list_value(grp, "exclude_transports"),
            exclude_securities: list_value(grp, "exclude_securities"),
            exclude_ports: list_value(grp, "exclude_ports")
        };
        push(result, clone);
    }
    return result;
}

function priority_level_child(group_id, value) {
    let child = child_section("priority_level", value);
    if (type(child) == "object") {
        if (option(child, "group", "") == as_string(group_id))
            return child;
        let bal = balancer_section(group_id);
        if (bal != null) {
            let pg = child_section("priority_group", option(child, "group", ""));
            if (pg != null && option(pg, "name", "") == option(bal, "name", ""))
                return child;
        }
    }
    for (let item in synthesized_priority_levels_for_balancer(group_id)) {
        if (section_name(item) == as_string(value))
            return item;
    }
    return null;
}

function priority_level_sort(left, right) {
    let left_order = int(option(left, "order", "0"), 10);
    let right_order = int(option(right, "order", "0"), 10);
    if (left_order != right_order)
        return left_order < right_order ? -1 : 1;

    let left_name = section_name(left);
    let right_name = section_name(right);
    return left_name == right_name ? 0 : (left_name < right_name ? -1 : 1);
}

function priority_level_items(group_id) {
    let synth = synthesized_priority_levels_for_balancer(group_id);
    if (length(synth) > 0)
        return synth;
    let result = child_items_by_owner("priority_level", "group", group_id);
    if (length(result) == 0) {
        let bal = balancer_section(group_id);
        if (bal != null) {
            for (let pg in uci_core.section_objects(CONFIG_NAME, "priority_group")) {
                if (option(pg, "name", "") == option(bal, "name", "")) {
                    result = child_items_by_owner("priority_level", "group", section_name(pg));
                    if (length(result) > 0)
                        break;
                }
            }
        }
    }
    if (length(result) > 0) {
        sort(result, priority_level_sort);
        return result;
    }
    return [];
}

function priority_levels(group_id) {
    let result = [];
    for (let child in priority_level_items(group_id)) {
        let id = section_name(child);
        if (id != "")
            push(result, id);
    }
    return result;
}

function tokenize_condition_expression(expr) {
    expr = trim(as_string(expr));
    if (expr == "")
        return [];
    let padded = replace(expr, /\(/g, " ( ");
    padded = replace(padded, /\)/g, " ) ");
    padded = replace(padded, /&&/g, " AND ");
    padded = replace(padded, /\|\|/g, " OR ");
    padded = replace(padded, /!/g, " NOT ");
    let raw_tokens = split(trim(padded), /[ \t\r\n]+/);
    let tokens = [];
    for (let tok in raw_tokens) {
        tok = trim(as_string(tok));
        if (tok == "")
            continue;
        let upper = uc(tok);
        if (upper == "AND" || upper == "&" || upper == "И")
            push(tokens, { type: "AND" });
        else if (upper == "OR" || upper == "|" || upper == "ИЛИ")
            push(tokens, { type: "OR" });
        else if (upper == "NOT" || upper == "~" || upper == "НЕ")
            push(tokens, { type: "NOT" });
        else if (tok == "(")
            push(tokens, { type: "LPAREN" });
        else if (tok == ")")
            push(tokens, { type: "RPAREN" });
        else
            push(tokens, { type: "IDENT", value: tok });
    }
    return tokens;
}

function parse_condition_tokens(tokens) {
    let pos = 0;
    let parse_or = null;
    let parse_and = null;
    let parse_unary = null;

    parse_unary = function() {
        if (pos >= length(tokens))
            return null;
        let tok = tokens[pos];
        if (tok.type == "NOT") {
            pos++;
            let operand = parse_unary();
            return operand != null ? { type: "not", child: operand } : null;
        }
        if (tok.type == "LPAREN") {
            pos++;
            let inner = parse_or();
            if (pos < length(tokens) && tokens[pos].type == "RPAREN")
                pos++;
            return inner;
        }
        if (tok.type == "IDENT") {
            pos++;
            return { type: "ref", id: tok.value };
        }
        pos++;
        return null;
    };

    parse_and = function() {
        let left = parse_unary();
        if (left == null)
            return null;
        let children = [ left ];
        while (pos < length(tokens)) {
            let tok = tokens[pos];
            if (tok.type == "AND") {
                pos++;
                let right = parse_unary();
                if (right != null)
                    push(children, right);
            } else if (tok.type == "IDENT" || tok.type == "NOT" || tok.type == "LPAREN") {
                // Implicit AND when two identifiers are adjacent
                let right = parse_unary();
                if (right != null)
                    push(children, right);
            } else {
                break;
            }
        }
        return length(children) == 1 ? children[0] : { type: "and", children };
    };

    parse_or = function() {
        let left = parse_and();
        if (left == null)
            return null;
        let children = [ left ];
        while (pos < length(tokens) && tokens[pos].type == "OR") {
            pos++;
            let right = parse_and();
            if (right != null)
                push(children, right);
        }
        return length(children) == 1 ? children[0] : { type: "or", children };
    };

    return parse_or();
}

function parse_condition_expression(expr) {
    let tokens = tokenize_condition_expression(expr);
    if (length(tokens) == 0)
        return null;
    return parse_condition_tokens(tokens);
}

function condition_direct_dependencies(cond) {
    let deps = [];
    let seen = {};
    for (let m in whitespace_list_value(cond, "members"))
        push_unique_str(deps, seen, m);
    for (let tok in tokenize_condition_expression(option(cond, "expression", ""))) {
        if (tok.type == "IDENT")
            push_unique_str(deps, seen, tok.value);
    }
    return deps;
}

function validate_condition_cycles_for_id(start_id) {
    let visit = null;
    let state = {};
    let path = [];
    visit = function(curr_id) {
        state[curr_id] = 1;
        push(path, curr_id);
        let cond = condition_section(curr_id);
        if (cond != null) {
            for (let dep in condition_direct_dependencies(cond)) {
                if (dep == curr_id) {
                    push(path, dep);
                    return { valid: false, cycle: path, message: "Condition '" + curr_id + "' references itself" };
                }
                if (state[dep] == 1) {
                    push(path, dep);
                    return { valid: false, cycle: path, message: "Circular reference in conditions: " + join(" -> ", path) };
                }
                if (state[dep] == null) {
                    let sub = visit(dep);
                    if (!sub.valid)
                        return sub;
                }
            }
        }
        pop(path);
        state[curr_id] = 2;
        return { valid: true };
    };
    return visit(as_string(start_id));
}

function validate_condition_graph() {
    for (let cond in condition_sections()) {
        let id = section_name(cond);
        if (id == "")
            continue;
        let res = validate_condition_cycles_for_id(id);
        if (!res.valid)
            return res;
        for (let dep in condition_direct_dependencies(cond)) {
            if (condition_section(dep) == null)
                return { valid: false, message: "Condition '" + id + "' references unknown condition '" + dep + "'" };
        }
    }
    return { valid: true };
}

function condition_ast(cond_id, visited) {
    cond_id = as_string(cond_id);
    if (cond_id == "")
        return null;
    visited = visited || {};
    if (visited[cond_id])
        return null;
    let cond = condition_section(cond_id);
    if (cond == null || !bool_option(cond, "enabled", true))
        return null;

    let next_visited = {};
    for (let k, v in visited)
        next_visited[k] = v;
    next_visited[cond_id] = true;

    let expr_str = trim(option(cond, "expression", ""));
    let members = whitespace_list_value(cond, "members");
    let ctype = lc(option(cond, "condition_type", "atomic"));
    let invert_self = bool_option(cond, "invert", false);

    let expand_parsed = null;
    expand_parsed = function(node) {
        if (node == null)
            return null;
        if (node.type == "ref")
            return condition_ast(node.id, next_visited);
        if (node.type == "not") {
            let child = expand_parsed(node.child);
            return child != null ? { type: "not", child } : null;
        }
        if (node.type == "and" || node.type == "or") {
            let children = [];
            for (let ch in (node.children || [])) {
                let exp = expand_parsed(ch);
                if (exp != null)
                    push(children, exp);
            }
            if (length(children) == 0)
                return null;
            if (length(children) == 1)
                return children[0];
            return { type: node.type, children };
        }
        return null;
    };

    let result = null;
    if (expr_str != "") {
        result = expand_parsed(parse_condition_expression(expr_str));
    } else if (length(members) > 0 || ctype == "composite") {
        let op = lc(option(cond, "operator", "and"));
        let children = [];
        for (let m_id in members) {
            let sub = condition_ast(m_id, next_visited);
            if (sub != null)
                push(children, sub);
        }
        if (length(children) > 0) {
            if (op == "not") {
                let inner = length(children) == 1 ? children[0] : { type: "and", children };
                result = { type: "not", child: inner };
            } else {
                let mode = (op == "or") ? "or" : "and";
                result = length(children) == 1 ? children[0] : { type: mode, children };
            }
        }
    } else {
        result = { type: "leaf", id: cond_id, section: cond };
    }

    if (result != null && invert_self)
        result = { type: "not", child: result };
    return result;
}

function section_condition_ast(section) {
    if (section == null || type(section) != "object")
        return null;
    let expr_str = trim(option(section, "condition_expression", ""));
    let refs = section_condition_refs(section);
    let op = lc(option(section, "condition_operator", "and"));

    if (expr_str != "") {
        let parsed = parse_condition_expression(expr_str);
        let expand_node = null;
        expand_node = function(node) {
            if (node == null)
                return null;
            if (node.type == "ref")
                return condition_ast(node.id, {});
            if (node.type == "not") {
                let ch = expand_node(node.child);
                return ch != null ? { type: "not", child: ch } : null;
            }
            if (node.type == "and" || node.type == "or") {
                let children = [];
                for (let c in (node.children || [])) {
                    let exp = expand_node(c);
                    if (exp != null)
                        push(children, exp);
                }
                if (length(children) == 0)
                    return null;
                return length(children) == 1 ? children[0] : { type: node.type, children };
            }
            return null;
        };
        return expand_node(parsed);
    }

    if (length(refs) == 0)
        return null;

    let children = [];
    for (let ref_id in refs) {
        let ast = condition_ast(ref_id, {});
        if (ast != null)
            push(children, ast);
    }
    if (length(children) == 0)
        return null;
    if (op == "not") {
        let inner = length(children) == 1 ? children[0] : { type: "and", children };
        return { type: "not", child: inner };
    }
    let mode = (op == "or") ? "or" : "and";
    return length(children) == 1 ? children[0] : { type: mode, children };
}

function ast_to_dnf(node, invert) {
    if (node == null)
        return [];
    invert = !!invert;
    if (node.type == "not")
        return ast_to_dnf(node.child, !invert);
    if (node.type == "leaf")
        return [ [ { id: node.id, section: node.section, invert } ] ];

    let effective_type = node.type;
    if (invert)
        effective_type = (node.type == "and") ? "or" : "and";

    let child_dnfs = [];
    for (let ch in (node.children || [])) {
        let d = ast_to_dnf(ch, invert);
        if (length(d) > 0)
            push(child_dnfs, d);
    }
    if (length(child_dnfs) == 0)
        return [];

    if (effective_type == "or") {
        let res = [];
        for (let d in child_dnfs)
            for (let clause in d)
                push(res, clause);
        return res;
    }

    // AND: Cartesian product of clauses
    let acc = child_dnfs[0];
    for (let i = 1; i < length(child_dnfs); i++) {
        let next_acc = [];
        for (let c1 in acc) {
            for (let c2 in child_dnfs[i]) {
                let merged = [];
                for (let lit in c1) push(merged, lit);
                for (let lit in c2) push(merged, lit);
                push(next_acc, merged);
            }
        }
        acc = next_acc;
    }
    return acc;
}

function section_leaf_conditions(section) {
    let ast = section_condition_ast(section);
    if (ast == null)
        return [];
    let result = [];
    let seen = {};
    let walk = null;
    walk = function(node, inv) {
        if (node == null)
            return;
        if (node.type == "not") {
            walk(node.child, !inv);
            return;
        }
        if (node.type == "leaf") {
            if (!inv && node.section != null && !seen[node.id]) {
                seen[node.id] = true;
                push(result, node.section);
            }
            return;
        }
        for (let ch in (node.children || []))
            walk(ch, inv);
    };
    walk(ast, false);
    return result;
}

function clean_condition_tokens(src, key) {
    let raw = raw_option(src, key);
    if (raw == null)
        return [];
    let lines = type(raw) == "array" ? raw : split(as_string(raw), /[\r\n]+/);
    let out = [];
    for (let line in lines) {
        line = replace(as_string(line), /(^|[ \t]+)\/\/.*$/, "");
        line = replace(line, /(^|[ \t]+)#.*$/, "");
        line = trim(line);
        if (line == "")
            continue;
        for (let tok in split(line, /[ \t,]+/)) {
            tok = trim(as_string(tok));
            if (tok != "")
                push(out, tok);
        }
    }
    return out;
}

function merge_condition_into_section_object(base_section, positive_conds, negative_conds) {
    let merged = {};
    for (let k, v in object_or_empty(base_section))
        merged[k] = v;

    // Avoid re-expanding condition_refs on the already-merged virtual clause object
    delete merged.condition_refs;
    delete merged.condition_expression;

    let list_keys = [
        "community_lists",
        "community",
        "rule_set",
        "rule_set_with_subnets",
        "domain_ip_lists",
        "domain_suffix",
        "domain_keyword",
        "domain_regex",
        "user_domains",
        "ip_cidr",
        "ip",
        "subnets",
        "source_ip_cidr",
        "source_macs",
        "device_ip",
        "devices",
        "device_mac",
        "fully_routed_ips",
        "excluded_ips",
        "ports",
        "port",
        "protocol",
        "excluded_protocol",
        "dscp",
        "geoip_country"
    ];
    let text_keys = [
        "domain",
        "domain_text",
        "domain_suffix_text",
        "domain_keyword_text",
        "domain_regex_text",
        "user_domains_text",
        "ip_cidr_text",
        "source_ip_cidr_text",
        "ports_text"
    ];

    for (let key in list_keys) {
        let acc = [];
        let seen = {};
        for (let src in [ base_section, ...(positive_conds || []) ]) {
            for (let item in clean_condition_tokens(src, key))
                push_unique_str(acc, seen, item);
        }
        if (key == "source_ip_cidr") {
            for (let src in [ base_section, ...(positive_conds || []) ]) {
                for (let mac in clean_condition_tokens(src, "source_macs"))
                    push_unique_str(acc, seen, mac);
            }
        }
        if (length(acc) > 0)
            merged[key] = acc;
    }

    for (let tkey in text_keys) {
        let parts = [];
        for (let src in [ base_section, ...(positive_conds || []) ]) {
            let raw = raw_option(src, tkey);
            if (raw == null)
                continue;
            let val = type(raw) == "array" ? trim(join("\n", raw)) : trim(as_string(raw));
            if (val != "")
                push(parts, val);
        }
        if (length(parts) > 0)
            merged[tkey] = join("\n", parts);
    }

    for (let cond in (positive_conds || [])) {
        if (option(merged, "geoip_mode", "") == "" && option(cond, "geoip_mode", "") != "")
            merged.geoip_mode = option(cond, "geoip_mode", "");
        if (option(merged, "community_subnets", "") == "" && option(cond, "community_subnets", "") != "")
            merged.community_subnets = option(cond, "community_subnets", "");
        if (option(merged, "match_all", "") == "" && bool_option(cond, "match_all", false))
            merged.match_all = "1";
    }

    if (negative_conds != null && length(negative_conds) > 0)
        merged.__inverted_conditions = negative_conds;

    return merged;
}

function section_effective_clauses(section) {
    if (section == null || type(section) != "object")
        return [];
    let ast = section_condition_ast(section);
    if (ast == null) {
        let macs = whitespace_list_value(section, "source_macs");
        if (length(macs) > 0)
            return [ merge_condition_into_section_object(section, [], []) ];
        return [ section ];
    }
    let dnf = ast_to_dnf(ast, false);
    if (length(dnf) == 0)
        return [ section ];
    let clauses = [];
    for (let conjunction in dnf) {
        let pos_conds = [];
        let neg_conds = [];
        for (let lit in conjunction) {
            if (lit.invert)
                push(neg_conds, lit.section);
            else
                push(pos_conds, lit.section);
        }
        push(clauses, merge_condition_into_section_object(section, pos_conds, neg_conds));
    }
    return clauses;
}

function community_lists(section) {
    let result = [];
    let seen = {};
    for (let item in whitespace_list_value(section, "community_lists"))
        push_unique_str(result, seen, item);
    for (let cond in section_leaf_conditions(section))
        for (let item in whitespace_list_value(cond, "community_lists"))
            push_unique_str(result, seen, item);
    return result;
}

function rule_sets(section) {
    let result = [];
    let seen = {};
    for (let item in whitespace_list_value(section, "rule_set"))
        push_unique_str(result, seen, item);
    for (let cond in section_leaf_conditions(section))
        for (let item in whitespace_list_value(cond, "rule_set"))
            push_unique_str(result, seen, item);
    return result;
}

function rule_sets_with_subnets(section) {
    let result = [];
    let seen = {};
    for (let item in whitespace_list_value(section, "rule_set_with_subnets"))
        push_unique_str(result, seen, item);
    for (let cond in section_leaf_conditions(section))
        for (let item in whitespace_list_value(cond, "rule_set_with_subnets"))
            push_unique_str(result, seen, item);
    return result;
}

function resolved_source_ip_cidrs(section) {
    let core_ip = require("core.ip");
    let raw = [];
    let seen = {};
    for (let item in whitespace_list_value(section, "source_ip_cidr"))
        push_unique_str(raw, seen, item);
    for (let mac in whitespace_list_value(section, "source_macs"))
        push_unique_str(raw, seen, mac);
    for (let cond in section_leaf_conditions(section)) {
        for (let item in whitespace_list_value(cond, "source_ip_cidr"))
            push_unique_str(raw, seen, item);
        for (let mac in whitespace_list_value(cond, "source_macs"))
            push_unique_str(raw, seen, mac);
    }
    let result = [];
    let seen_res = {};
    for (let val in raw) {
        if (core_ip.valid_mac(val)) {
            for (let ip in core_ip.resolve_mac_to_ips(val))
                push_unique_str(result, seen_res, ip);
        } else {
            push_unique_str(result, seen_res, val);
        }
    }
    return result;
}

function list_option_value_from_array(values) {
    return join(" ", values || []);
}

function community_lists_value(section) {
    return list_option_value_from_array(community_lists(section));
}

function rule_sets_value(section) {
    return list_option_value_from_array(rule_sets(section));
}

function combined_domain_condition_text(section) {
    if (type(raw_option(section, "domain")) != "array") {
        let value = option(section, "domain", "");
        if (value != "")
            return value;
    }

    return option(section, "domain_suffix_text", "");
}

function rule_config_or_null() {
    try {
        return require("config.rule");
    } catch (e) {
        return null;
    }
}

function global_rule_kinds() {
    let kinds = [];
    for (let kind in GLOBAL_RULE_OPTIONS)
        push(kinds, kind);
    return kinds;
}

// A claim is stored as list global_rules '<kind>:<value>'. The value may itself
// carry colons (a rule-set URL, a 'full:' domain prefix), so only the first one
// separates - the kind never contains one.
function global_rule_claim(entry) {
    entry = trim(as_string(entry));
    let colon = index(entry, ":");
    if (colon <= 0)
        return null;

    let kind = substr(entry, 0, colon);
    let value = trim(substr(entry, colon + 1));
    if (value == "" || GLOBAL_RULE_OPTIONS[kind] == null)
        return null;

    return { kind, value };
}

function global_rules(section) {
    return whitespace_list_value(section, "global_rules");
}

function condition_values(section, kind) {
    let keys = GLOBAL_RULE_OPTIONS[kind];
    if (keys == null)
        return null;

    let values = {};
    let rule_config = GLOBAL_RULE_TEXT_OPTIONS[kind] ? rule_config_or_null() : null;

    for (let key in keys) {
        let raw = raw_option(section, key);
        if (raw == null)
            continue;

        let items;
        if (type(raw) == "array")
            items = raw;
        else if (rule_config)
            items = rule_config.text_list_values(raw);
        else
            items = split(trim(as_string(raw)), /[ \t\r\n]+/);

        for (let item in items) {
            item = trim(as_string(item));
            if (item != "")
                values[item] = true;
        }
    }

    return values;
}

// Claims the owner still actually uses. A claim whose value was later removed
// from its section goes inert instead of failing validation - otherwise deleting
// one condition would block every apply and a stale claim would keep starving
// other sections of the value forever.
function active_global_rules(section) {
    let active = [];
    for (let entry in global_rules(section)) {
        let claim = global_rule_claim(entry);
        if (claim == null)
            continue;

        let values = condition_values(section, claim.kind);
        if (values != null && values[claim.value] == true)
            push(active, claim);
    }
    return active;
}

function rule_condition_csv(section, key, kind) {
    let rule_config = rule_config_or_null();
    if (!rule_config)
        return "";
    return rule_config.rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        combined_domain_condition_text(section),
        option(section, "domain_suffix", "")
    );
}

function has_dns_matchers_single(section) {
    return rule_condition_csv(section, "domain", "domains") != "" ||
        rule_condition_csv(section, "domain_suffix", "domains") != "" ||
        rule_condition_csv(section, "domain_keyword", "generic") != "" ||
        rule_condition_csv(section, "domain_regex", "generic") != "" ||
        length(whitespace_list_value(section, "community_lists")) > 0 ||
        length(whitespace_list_value(section, "rule_set")) > 0 ||
        length(whitespace_list_value(section, "rule_set_with_subnets")) > 0 ||
        option(section, "domain_ip_lists", "") != "";
}

function has_dns_matchers(section) {
    if (has_dns_matchers_single(section))
        return true;
    for (let cond in section_leaf_conditions(section)) {
        if (has_dns_matchers_single(cond))
            return true;
    }
    return false;
}

const DSCP_ALIASES = {
    "cs0": 0, "cs1": 8, "cs2": 16, "cs3": 24, "cs4": 32, "cs5": 40, "cs6": 48, "cs7": 56,
    "ef": 46,
    "af11": 10, "af12": 12, "af13": 14,
    "af21": 18, "af22": 20, "af23": 22,
    "af31": 26, "af32": 28, "af33": 30,
    "af41": 34, "af42": 36, "af43": 38
};

function parse_dscp_value(item) {
    item = lc(trim(as_string(item)));
    if (item == "") return null;
    if (DSCP_ALIASES[item] != null)
        return DSCP_ALIASES[item];

    let num = null;
    if (substr(item, 0, 2) == "0x")
        num = int(item, 16);
    else
        num = int(item, 10);

    if (num != null && num >= 0 && num <= 63)
        return num;
    return null;
}

function dscp_list(section) {
    let raw = [];
    for (let item in whitespace_list_value(section, "dscp"))
        push(raw, item);
    for (let cond in section_leaf_conditions(section))
        for (let item in whitespace_list_value(cond, "dscp"))
            push(raw, item);
    let result = [];
    let seen = {};
    for (let item in raw) {
        let parsed = parse_dscp_value(item);
        if (parsed != null && !seen[parsed]) {
            seen[parsed] = true;
            push(result, parsed);
        }
    }
    return result;
}

function dscp_value(section) {
    return list_option_value_from_array(dscp_list(section));
}

function contains(arr, val) {
    if (type(arr) != "array") return false;
    for (let item in arr) {
        if (item == val) return true;
    }
    return false;
}

function routed_dns_enabled(section) {
    return bool_option(section, "routed_dns_enabled", false);
}

function routed_dns_type(section) {
    let t = option(section, "routed_dns_type", "udp");
    if (!contains(["udp", "dot", "doh", "doq"], t))
        t = "udp";
    return t;
}

function routed_dns_servers(section) {
    let servers = list_option(section, "routed_dns_server");
    if (length(servers) == 0) {
        let single = option(section, "routed_dns_server", "");
        servers = [single];
    }
    return servers;
}

function geoip_country_list(section) {
    let raw = [];
    for (let item in whitespace_list_value(section, "geoip_country"))
        push(raw, item);
    for (let cond in section_leaf_conditions(section))
        for (let item in whitespace_list_value(cond, "geoip_country"))
            push(raw, item);
    let result = [];
    for (let item in raw) {
        item = lc(trim(as_string(item)));
        if (item == "" || item == "all") continue;
        if (item == "non-ru") {
            if (!contains(result, "ru")) push(result, "ru");
            continue;
        }
        if (match(item, /^[a-z]{2}$/) != null && !contains(result, item))
            push(result, item);
    }
    return result;
}

// Four ways a GeoIP condition can shape its section. "include"/"exclude" leave
// the other half of the traffic to whatever section comes next; the two closed
// modes keep it inside, so the GeoIP condition is the whole section and no
// other matcher may be added to it.
const GEOIP_COUNTRY_MODES = [ "include", "exclude", "include_all", "exclude_direct" ];
const GEOIP_COUNTRY_CLOSED_MODES = [ "include_all", "exclude_direct" ];

function geoip_country_mode(section) {
    let mode = lc(trim(option(section, "geoip_mode", "")));
    if (contains(GEOIP_COUNTRY_MODES, mode))
        return mode;
    for (let cond in section_leaf_conditions(section)) {
        let cmode = lc(trim(option(cond, "geoip_mode", "")));
        if (contains(GEOIP_COUNTRY_MODES, cmode))
            return cmode;
    }

    let act = action(section);
    if (act == "bypass" || act == "block")
        return "include";

    return "exclude";
}

function geoip_country_mode_is_closed(section) {
    return contains(GEOIP_COUNTRY_CLOSED_MODES, geoip_country_mode(section));
}

function packet_encoding(section) {
    let val = lc(trim(option(section, "packet_encoding", "")));
    if (val == "xudp" || val == "packetaddr" || val == "disabled" || val == "none")
        return val;
    return "";
}

function geoip_country_value(section) {
    return list_option_value_from_array(geoip_country_list(section));
}

function rule_sets_with_subnets_value(section) {
    return list_option_value_from_array(rule_sets_with_subnets(section));
}

function single_object_has_routing_matchers(section) {
    if (section == null || type(section) != "object")
        return false;

    if (has_dns_matchers_single(section))
        return true;

    if (length(list_option(section, "domain")) > 0 || option(section, "domain", "") != "" || option(section, "domain_text", "") != "" ||
        length(list_option(section, "domain_suffix")) > 0 || option(section, "domain_suffix", "") != "" || option(section, "domain_suffix_text", "") != "" ||
        length(list_option(section, "domain_keyword")) > 0 || option(section, "domain_keyword", "") != "" || option(section, "domain_keyword_text", "") != "" ||
        length(list_option(section, "domain_regex")) > 0 || option(section, "domain_regex", "") != "" || option(section, "domain_regex_text", "") != "" ||
        length(list_option(section, "user_domains")) > 0 || option(section, "user_domains", "") != "" || option(section, "user_domains_text", "") != "")
        return true;

    if (rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        rule_condition_csv(section, "source_ip_cidr", "subnets") != "" ||
        length(list_option(section, "fully_routed_ips")) > 0 ||
        option(section, "fully_routed_ips", "") != "" ||
        length(list_option(section, "source_macs")) > 0 ||
        option(section, "source_macs", "") != "" ||
        length(list_option(section, "ip_cidr")) > 0 ||
        option(section, "ip_cidr", "") != "" ||
        option(section, "ip_cidr_text", "") != "" ||
        length(list_option(section, "source_ip_cidr")) > 0 ||
        option(section, "source_ip_cidr", "") != "" ||
        option(section, "source_ip_cidr_text", "") != "")
        return true;

    if (rule_condition_csv(section, "ports", "ports") != "" ||
        length(list_option(section, "ports")) > 0 ||
        option(section, "ports", "") != "" ||
        option(section, "ports_text", "") != "" ||
        option(section, "port", "") != "" ||
        option(section, "port_range", "") != "")
        return true;

    if (length(list_option(section, "protocol")) > 0 ||
        option(section, "protocol", "") != "")
        return true;

    if (length(whitespace_list_value(section, "dscp")) > 0)
        return true;

    if (length(whitespace_list_value(section, "geoip_country")) > 0)
        return true;

    return false;
}

function section_has_routing_matchers(section) {
    if (section == null || type(section) != "object")
        return false;
    if (single_object_has_routing_matchers(section))
        return true;
    for (let cond in section_leaf_conditions(section)) {
        if (single_object_has_routing_matchers(cond))
            return true;
    }
    return false;
}

function section_matching_provider_source(section, action) {
    if (section == null || type(section) != "object" || action == null || action == "")
        return null;
    let target_type = lc(trim(as_string(action)));
    if (!is_connections_action(option(section, "action", "")))
        return null;
    for (let src in section_effective_outbound_sources(section)) {
        if (lc(trim(option(src, "source_type", ""))) == target_type)
            return src;
    }
    return null;
}

function section_is_active_provider(section, action) {
    if (section == null || type(section) != "object")
        return false;
    let name = section_name(section);
    if (name == "")
        return false;
    if (!bool_option(section, "enabled", true))
        return false;
    if (action != null && action != "" && option(section, "action", "") != action) {
        if (section_matching_provider_source(section, action) == null)
            return false;
    }

    return section_has_routing_matchers(section) ||
        bool_option(section, "match_all", false) ||
        bool_option(section, "mixed_proxy_enabled", false);
}

function active_provider_sections(action, sections) {
    let result = [];
    let list = sections;
    if (list == null)
        list = uci_core.section_objects(CONFIG_NAME, "section");

    for (let section in list) {
        if (!section_is_active_provider(section, action))
            continue;
        let src = section_matching_provider_source(section, action);
        if (src != null) {
            let merged = {};
            for (let k, v in object_or_empty(section))
                merged[k] = v;
            for (let k, v in object_or_empty(src)) {
                if (substr(k, 0, 1) == "." || k == "name" || k == "enabled" || k == "source_type")
                    continue;
                if (merged[k] == null || merged[k] == "")
                    merged[k] = v;
            }
            push(result, merged);
        } else {
            push(result, section);
        }
    }
    return result;
}

function active_provider_section_index(action, sections, target_section) {
    let target_name = type(target_section) == "object" ? section_name(target_section) : as_string(target_section);
    if (target_name == "")
        return 0;

    let active = active_provider_sections(action, sections);
    for (let i = 0; i < length(active); i++) {
        if (section_name(active[i]) == target_name)
            return i + 1;
    }
    return 0;
}

function component_provider_sections(action) {
    let result = [];
    let sections = uci_core.section_objects(CONFIG_NAME, "section");
    for (let section in sections) {
        if (!bool_option(section, "enabled", true))
            continue;
        if (option(section, "action", "") == action) {
            push(result, section);
            continue;
        }
        let src = section_matching_provider_source(section, action);
        if (src != null) {
            let merged = {};
            for (let k, v in object_or_empty(section))
                merged[k] = v;
            for (let k, v in object_or_empty(src)) {
                if (substr(k, 0, 1) == "." || k == "name" || k == "enabled" || k == "source_type")
                    continue;
                if (merged[k] == null || merged[k] == "")
                    merged[k] = v;
            }
            push(result, merged);
        }
    }
    return result;
}

function wdtt_sections() {
    return component_provider_sections("wdtt");
}

function olcrtc_sections() {
    return component_provider_sections("olcrtc");
}

function fptn_sections() {
    return component_provider_sections("fptn");
}

function has_connection_sources(section) {
    return length(connection_urls(section)) > 0 ||
        length(subscription_urls(section)) > 0 ||
        length(interfaces(section)) > 0 ||
        length(outbound_jsons(section)) > 0 ||
        length(section_effective_outbound_sources(section)) > 0;
}

function subscription_url_settings(section, value) {
    let child = subscription_source_item(section, value);
    return child != null ? child : item_settings(section, "subscription_url_settings", value);
}

function interface_settings(section, value) {
    let child = interface_source_item(section, value);
    return child != null ? child : item_settings(section, "interface_settings", value);
}

function interface_domain_resolver_enabled(section, value) {
    let child = interface_source_item(section, value);
    if (child != null)
        return child_bool(child, "domain_resolver_enabled", false);
    return item_bool(section, "interface_settings", value, "domain_resolver_enabled",
        bool_option(section, "domain_resolver_enabled", false));
}

function interface_domain_resolver_dns_type(section, value) {
    let child = interface_source_item(section, value);
    if (child != null)
        return child_option(child, "domain_resolver_dns_type", "udp");
    return item_option(section, "interface_settings", value, "domain_resolver_dns_type",
        option(section, "domain_resolver_dns_type", "udp") || "udp");
}

function interface_domain_resolver_dns_server(section, value) {
    let child = interface_source_item(section, value);
    if (child != null)
        return child_option(child, "domain_resolver_dns_server", "8.8.8.8");
    return item_option(section, "interface_settings", value, "domain_resolver_dns_server",
        option(section, "domain_resolver_dns_server", "8.8.8.8") || "8.8.8.8");
}

function urltest_child(section, value) {
    let child = owned_child_section(section, "urltest", value);
    if (child != null)
        return child;

    child = child_item_by_value(section, "urltest", "id", value);
    if (child != null)
        return child;

    let bal = balancer_section(value);
    if (bal != null && lc(option(bal, "balancer_type", "urltest")) == "urltest") {
        let merged = {};
        let has_base = false;
        let bname = option(bal, "name", section_name(bal));
        for (let ut in child_items(section, "urltest")) {
            if (child_option(ut, "name", section_name(ut)) == bname) {
                for (let k, v in ut)
                    merged[k] = v;
                has_base = true;
                break;
            }
        }
        let grefs = whitespace_list_value(bal, "group_refs");
        if (length(grefs) > 0 && option(bal, "filter_mode", "") == "") {
            let grp = outbound_group_section(grefs[0]);
            if (grp != null) {
                for (let k, v in grp)
                    merged[k] = v;
                has_base = true;
            }
        }
        if (has_base) {
            for (let k, v in bal)
                merged[k] = v;
            return merged;
        }
        return bal;
    }
    return null;
}

function urltest_settings(section, value) {
    let child = urltest_child(section, value);
    return child != null ? child : item_settings(section, "urltest_settings", value);
}

// Whether a single subscription URL takes part at all. Distinct from
// subscription_update_enabled: that one only governs the automatic refresh,
// while this one must keep the source out of the download, the cache and the
// generated outbounds entirely. Defaulting to true keeps every configuration
// written before the flag existed behaving exactly as it did.
function subscription_url_enabled(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "enabled", true);
    return item_bool(section, "subscription_url_settings", value, "enabled",
        bool_option(section, "enabled", true));
}

function subscription_update_enabled(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "subscription_update_enabled", true);
    return item_bool(section, "subscription_url_settings", value, "subscription_update_enabled",
        bool_option(section, "subscription_update_enabled", true));
}

function subscription_update_interval(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_option(child, "subscription_update_interval", "1h");
    return item_option(section, "subscription_url_settings", value, "subscription_update_interval",
        option(section, "subscription_update_interval", "1h") || "1h");
}

function subscription_dashboard_metadata_enabled(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "show_dashboard_metadata", true);
    return item_bool(section, "subscription_url_settings", value, "show_dashboard_metadata", true);
}

function subscription_auto_user_agent(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null) {
        if (raw_option(child, "auto_user_agent") != null)
            return child_bool(child, "auto_user_agent", true);
        return child_option(child, "user_agent", "") == "";
    }

    let settings = item_settings(section, "subscription_url_settings", value);
    if (raw_option(settings, "auto_user_agent") != null)
        return item_bool(section, "subscription_url_settings", value, "auto_user_agent", true);
    return item_option(section, "subscription_url_settings", value, "user_agent", "") == "";
}

function subscription_auto_hwid(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null) {
        if (raw_option(child, "auto_hwid") != null)
            return child_bool(child, "auto_hwid", true);
        return child_option(child, "hwid", "") == "";
    }

    let settings = item_settings(section, "subscription_url_settings", value);
    if (raw_option(settings, "auto_hwid") != null)
        return item_bool(section, "subscription_url_settings", value, "auto_hwid", true);
    return item_option(section, "subscription_url_settings", value, "hwid", "") == "";
}

function subscription_include_urltest_groups(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "include_urltest_groups", true);
    return item_bool(section, "subscription_url_settings", value, "include_urltest_groups", true);
}

function subscription_hide_urltest_group_outbounds(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "hide_urltest_group_outbounds", true);
    return item_bool(section, "subscription_url_settings", value, "hide_urltest_group_outbounds", true);
}

function subscription_urltest_idle_timeout(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_option(child, "urltest_idle_timeout", "");
    return item_option(section, "subscription_url_settings", value, "urltest_idle_timeout", "");
}

function subscription_hide_detour_outbounds(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "hide_detour_outbounds", true);
    return item_bool(section, "subscription_url_settings", value, "hide_detour_outbounds", true);
}

function subscription_prefix_nodes(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null) {
        if (raw_option(child, "prefix_nodes") != null)
            return child_bool(child, "prefix_nodes", false);
        return trim(child_option(child, "node_prefix", "")) != "";
    }
    return item_bool(section, "subscription_url_settings", value, "prefix_nodes", false);
}

function subscription_node_prefix(section, value) {
    if (!subscription_prefix_nodes(section, value))
        return "";

    let child = subscription_source_item(section, value);
    let prefix = child != null
        ? child_option(child, "node_prefix", "")
        : item_option(section, "subscription_url_settings", value, "node_prefix", "");
    return trim(as_string(prefix));
}

function subscription_user_agent(section, value) {
    if (subscription_auto_user_agent(section, value))
        return "";

    let child = subscription_source_item(section, value);
    let configured = child != null
        ? child_option(child, "user_agent", "")
        : item_option(section, "subscription_url_settings", value, "user_agent", "");
    return configured != "" ? configured : "sing-box";
}

function subscription_hwid(section, value) {
    if (subscription_auto_hwid(section, value))
        return "";

    let child = subscription_source_item(section, value);
    if (child != null)
        return child_option(child, "hwid", "");
    return item_option(section, "subscription_url_settings", value, "hwid", "");
}

function subscription_custom_device_headers(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_bool(child, "custom_device_headers", false);
    return item_bool(section, "subscription_url_settings", value, "custom_device_headers", false);
}

function subscription_device_header(section, value, name) {
    let child = subscription_source_item(section, value);
    if (child != null)
        return child_option(child, name, "");
    return item_option(section, "subscription_url_settings", value, name, "");
}

function subscription_device_os(section, value) {
    return subscription_device_header(section, value, "device_os");
}

function subscription_ver_os(section, value) {
    return subscription_device_header(section, value, "ver_os");
}

function subscription_device_model(section, value) {
    return subscription_device_header(section, value, "device_model");
}

function subscription_device_locale(section, value) {
    return subscription_device_header(section, value, "device_locale");
}

function subscription_app_version(section, value) {
    return subscription_device_header(section, value, "app_version");
}

function subscription_accept_language(section, value) {
    return subscription_device_header(section, value, "accept_language");
}

function subscription_device_headers(section, value) {
    return {
        enabled: subscription_custom_device_headers(section, value),
        device_os: subscription_device_os(section, value),
        ver_os: subscription_ver_os(section, value),
        device_model: subscription_device_model(section, value),
        device_locale: subscription_device_locale(section, value),
        app_version: subscription_app_version(section, value),
        accept_language: subscription_accept_language(section, value)
    };
}

function device_headers_signature(headers) {
    headers = object_or_empty(headers);
    if (!headers.enabled)
        return "";

    return sprintf("%J", {
        enabled: "1",
        device_os: as_string(headers.device_os),
        ver_os: as_string(headers.ver_os),
        device_model: as_string(headers.device_model),
        device_locale: as_string(headers.device_locale),
        app_version: as_string(headers.app_version),
        accept_language: as_string(headers.accept_language)
    });
}

function subscription_device_headers_signature(section, value) {
    return device_headers_signature(subscription_device_headers(section, value));
}

function subscription_download_section(section, value) {
    let child = subscription_source_item(section, value);
    if (child != null) {
        if (!child_bool(child, "download_via_proxy_enabled", false))
            return "";
        return child_option(child, "download_via_proxy_section", "");
    }

    if (!item_bool(section, "subscription_url_settings", value, "download_via_proxy_enabled", false))
        return "";

    return item_option(section, "subscription_url_settings", value, "download_via_proxy_section", "");
}

function subscription_insecure(section, value) {
    if (section != null && section.subscription_insecure != null)
        return bool_option(section, "subscription_insecure", false) ? "1" : "0";

    let child = subscription_source_item(section, value);
    if (child != null)
        return bool_option(child, "subscription_insecure", false) ? "1" : "0";

    return item_bool(section, "subscription_url_settings", value, "subscription_insecure", false) ? "1" : "0";
}

function urltest_check_interval(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "check_interval", "urltest_check_interval" ], "3m");
    let fallback = option(section, "check_interval", option(section, "urltest_check_interval", "3m") || "3m") || "3m";
    return item_option(section, "urltest_settings", value, "urltest_check_interval", fallback);
}

function urltest_tolerance(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "tolerance", "urltest_tolerance" ], "50");
    let fallback = option(section, "tolerance", option(section, "urltest_tolerance", "50") || "50") || "50";
    return item_option(section, "urltest_settings", value, "urltest_tolerance", fallback);
}

function urltest_testing_url(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "testing_url", "urltest_testing_url" ], "https://www.gstatic.com/generate_204");
    let fallback = option(section, "testing_url", option(section, "urltest_testing_url", "https://www.gstatic.com/generate_204") || "https://www.gstatic.com/generate_204") || "https://www.gstatic.com/generate_204";
    return item_option(section, "urltest_settings", value, "urltest_testing_url", fallback);
}

function urltest_display_name(section, value) {
    let fallback = as_string(value);
    if (fallback == "urltest" && length(child_items(section, "urltest")) == 0)
        fallback = "Fastest";
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "name", "display_name" ], fallback);
    return item_option(section, "urltest_settings", value, "display_name", fallback);
}

function urltest_idle_timeout(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option(child, "idle_timeout", "");
    let fallback = option(section, "idle_timeout", option(section, "urltest_idle_timeout", "") || "");
    return item_option(section, "urltest_settings", value, "idle_timeout", fallback);
}

function urltest_interrupt_exist_connections(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_bool(child, "interrupt_exist_connections", true);
    let fallback = bool_option(section, "interrupt_exist_connections", bool_option(section, "urltest_interrupt_exist_connections", true));
    return item_bool(section, "urltest_settings", value, "interrupt_exist_connections", fallback);
}

function urltest_group_refs(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return whitespace_list_value(child, "group_refs");
    return [];
}

function urltest_filter_mode(section, value) {
    let child = urltest_child(section, value);
    if (child != null) {
        let raw_mode = lc(trim(child_option_alias(child, [ "filter_mode", "urltest_filter_mode" ], "")));
        let src_prefixes = child_effective_include_prefixes(child, section);
        if (raw_mode == "exclude" && length(src_prefixes) > 0)
            return "mixed";
        if (raw_mode == "disabled" && length(src_prefixes) > 0)
            return "include";
        if (raw_mode == "include" || raw_mode == "exclude" || raw_mode == "mixed")
            return raw_mode;
        if (child[".type"] == "balancer" || raw_option(child, "balancer_type") != null || raw_option(child, "source_refs") != null || raw_option(child, "group_refs") != null) {
            let has_inc = length(src_prefixes) > 0 ||
                length(child_list_alias(child, [ "include_countries", "urltest_include_countries" ], [])) > 0 ||
                length(child_list_alias(child, [ "include_outbounds", "urltest_include_outbounds" ], [])) > 0 ||
                length(child_list_alias(child, [ "include_regex", "urltest_include_regex" ], [])) > 0 ||
                length(child_list(child, "include_protocols", [])) > 0 ||
                length(child_list(child, "include_transports", [])) > 0 ||
                length(child_list(child, "include_securities", [])) > 0 ||
                length(child_list(child, "include_ports", [])) > 0;
            let has_exc = length(child_list_alias(child, [ "exclude_prefixes", "urltest_exclude_prefixes" ], [])) > 0 ||
                length(child_list_alias(child, [ "exclude_countries", "urltest_exclude_countries" ], [])) > 0 ||
                length(child_list_alias(child, [ "exclude_outbounds", "urltest_exclude_outbounds" ], [])) > 0 ||
                length(child_list_alias(child, [ "exclude_regex", "urltest_exclude_regex" ], [])) > 0 ||
                length(child_list(child, "exclude_protocols", [])) > 0 ||
                length(child_list(child, "exclude_transports", [])) > 0 ||
                length(child_list(child, "exclude_securities", [])) > 0 ||
                length(child_list(child, "exclude_ports", [])) > 0;
            if (has_inc && has_exc)
                return "mixed";
            if (has_inc)
                return "include";
            if (has_exc)
                return "exclude";
        }
        return raw_mode != "" ? raw_mode : "disabled";
    }
    return item_option(section, "urltest_settings", value, "urltest_filter_mode",
        option(section, "urltest_filter_mode", "disabled") || "disabled");
}

function urltest_detect_server_country(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option(child, "detect_server_country", "flag_emoji");
    return item_option(section, "urltest_settings", value, "detect_server_country",
        option(section, "detect_server_country", "flag_emoji") || "flag_emoji");
}

function urltest_pin_dashboard(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_bool(child, "pin_dashboard", true);
    return item_bool(section, "urltest_settings", value, "pin_dashboard", true);
}

function child_explicit_mode_allows_include(child) {
    if (child == null)
        return true;
    let raw_mode = lc(trim(child_option_alias(child, [ "filter_mode", "urltest_filter_mode" ], "")));
    return raw_mode != "disabled" && raw_mode != "exclude";
}

function child_explicit_mode_allows_exclude(child) {
    if (child == null)
        return true;
    let raw_mode = lc(trim(child_option_alias(child, [ "filter_mode", "urltest_filter_mode" ], "")));
    return raw_mode != "disabled" && raw_mode != "include";
}

function urltest_include_countries(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_include(child)
            ? child_list_alias(child, [ "include_countries", "urltest_include_countries" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_include_countries",
        list_value(section, "urltest_include_countries"));
}

function urltest_include_outbounds(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_include(child)
            ? child_list_alias(child, [ "include_outbounds", "urltest_include_outbounds" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_include_outbounds",
        list_value(section, "urltest_include_outbounds"));
}

function urltest_include_regex(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_include(child)
            ? child_list_alias(child, [ "include_regex", "urltest_include_regex" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_include_regex",
        list_value(section, "urltest_include_regex"));
}

function urltest_include_proxy_parameters(section, value) {
    let child = urltest_child(section, value);
    if (child == null || !child_explicit_mode_allows_include(child))
        return false;
    if (raw_option(child, "include_proxy_parameters") != null)
        return child_bool(child, "include_proxy_parameters", false);
    return length(child_list(child, "include_protocols", [])) > 0 ||
        length(child_list(child, "include_transports", [])) > 0 ||
        length(child_list(child, "include_securities", [])) > 0 ||
        length(child_list(child, "include_ports", [])) > 0;
}

function urltest_include_protocols(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_include(child)) ? child_list(child, "include_protocols", []) : [];
}

function urltest_include_transports(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_include(child)) ? child_list(child, "include_transports", []) : [];
}

function urltest_include_securities(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_include(child)) ? child_list(child, "include_securities", []) : [];
}

function urltest_include_ports(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_include(child)) ? child_list(child, "include_ports", []) : [];
}

function urltest_exclude_countries(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_exclude(child)
            ? child_list_alias(child, [ "exclude_countries", "urltest_exclude_countries" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_exclude_countries",
        list_value(section, "urltest_exclude_countries"));
}

function urltest_exclude_outbounds(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_exclude(child)
            ? child_list_alias(child, [ "exclude_outbounds", "urltest_exclude_outbounds" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_exclude_outbounds",
        list_value(section, "urltest_exclude_outbounds"));
}

function urltest_exclude_regex(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_exclude(child)
            ? child_list_alias(child, [ "exclude_regex", "urltest_exclude_regex" ], [])
            : [];
    return item_list(section, "urltest_settings", value, "urltest_exclude_regex",
        list_value(section, "urltest_exclude_regex"));
}

function urltest_exclude_proxy_parameters(section, value) {
    let child = urltest_child(section, value);
    if (child == null || !child_explicit_mode_allows_exclude(child))
        return false;
    if (raw_option(child, "exclude_proxy_parameters") != null)
        return child_bool(child, "exclude_proxy_parameters", false);
    return length(child_list(child, "exclude_protocols", [])) > 0 ||
        length(child_list(child, "exclude_transports", [])) > 0 ||
        length(child_list(child, "exclude_securities", [])) > 0 ||
        length(child_list(child, "exclude_ports", [])) > 0;
}

function urltest_exclude_protocols(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_exclude(child)) ? child_list(child, "exclude_protocols", []) : [];
}

function urltest_exclude_transports(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_exclude(child)) ? child_list(child, "exclude_transports", []) : [];
}

function urltest_exclude_securities(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_exclude(child)) ? child_list(child, "exclude_securities", []) : [];
}

function urltest_exclude_ports(section, value) {
    let child = urltest_child(section, value);
    return (child != null && child_explicit_mode_allows_exclude(child)) ? child_list(child, "exclude_ports", []) : [];
}

function priority_group_display_name(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "name", as_string(value)) : as_string(value);
}

function priority_group_health_url(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "health_url", "https://www.gstatic.com/generate_204") : "https://www.gstatic.com/generate_204";
}

function priority_group_active_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "active_check_interval", "5s") : "5s";
}

function priority_group_check_timeout(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "check_timeout", "2s") : "2s";
}

function priority_group_recovery_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "recovery_check_interval", "15s") : "15s";
}

function priority_group_pick_fastest(section, value) {
    // The fastest node of a tier is the expected behaviour, not an opt-in:
    // taking the first living node in filter order is how the group ended up
    // on the slowest server of the tier (issue #244). The flag stays, so a
    // user who wants the stable first node can still ask for it.
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "pick_fastest", true) : true;
}

function priority_group_switch_to_faster_same_priority(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "switch_to_faster_same_priority", false) : false;
}

function priority_group_fastest_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "fastest_check_interval", "3m") : "3m";
}

function priority_group_interrupt_exist_connections(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "interrupt_exist_connections", true) : true;
}

function priority_group_pin_dashboard(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "pin_dashboard", true) : true;
}

function priority_level_display_name(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "name", as_string(value)) : as_string(value);
}

function priority_level_order(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "order", "0") : "0";
}

function priority_level_direct(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_bool(child, "direct", false) : false;
}

function priority_level_filter_mode(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "filter_mode", "include") : "include";
}

function priority_level_include_countries(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_countries", "country" ], []) : [];
}

function priority_level_include_outbounds(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_outbounds", "server_name" ], []) : [];
}

function priority_level_include_regex(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_regex", "regex" ], []) : [];
}

function priority_level_include_proxy_parameters(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_bool(child, "include_proxy_parameters", false) : false;
}

function priority_level_include_protocols(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "include_protocols", []) : [];
}

function priority_level_include_transports(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "include_transports", []) : [];
}

function priority_level_include_securities(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "include_securities", []) : [];
}

function priority_level_include_ports(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "include_ports", []) : [];
}

function priority_level_exclude_countries(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_countries", []) : [];
}

function priority_level_exclude_outbounds(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_outbounds", []) : [];
}

function priority_level_exclude_regex(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_regex", []) : [];
}

function priority_level_exclude_proxy_parameters(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_bool(child, "exclude_proxy_parameters", false) : false;
}

function priority_level_exclude_protocols(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_protocols", []) : [];
}

function priority_level_exclude_transports(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_transports", []) : [];
}

function priority_level_exclude_securities(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_securities", []) : [];
}

function priority_level_exclude_ports(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_ports", []) : [];
}

function priority_level_countries(group_id, value) {
    return priority_level_include_countries(group_id, value);
}

function priority_level_outbounds(group_id, value) {
    return priority_level_include_outbounds(group_id, value);
}

function priority_level_regex(group_id, value) {
    return priority_level_include_regex(group_id, value);
}

function priority_level_detect_server_country(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "detect_server_country", "flag_emoji") : "flag_emoji";
}

function urltest_include_prefixes(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_effective_include_prefixes(child, section);
    return list_value(section, "urltest_include_prefixes");
}

function urltest_exclude_prefixes(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_explicit_mode_allows_exclude(child)
            ? child_list_alias(child, [ "exclude_prefixes", "urltest_exclude_prefixes" ], [])
            : [];
    return list_value(section, "urltest_exclude_prefixes");
}

function priority_level_include_prefixes(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_prefixes", "prefix" ], []) : [];
}

function priority_level_exclude_prefixes(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_prefixes", []) : [];
}

function resolve_effective_filter_mode(raw_mode, has_inc, has_exc) {
    let mode = lc(trim(as_string(raw_mode)));
    if (mode == "include" || mode == "exclude" || mode == "mixed")
        return mode;
    if (has_inc && has_exc)
        return "mixed";
    if (has_inc)
        return "include";
    if (has_exc)
        return "exclude";
    return "disabled";
}

function outbound_group_filter_spec(group_or_id, section) {
    let grp = type(group_or_id) == "object" ? group_or_id : outbound_group_section(group_or_id);
    if (grp == null)
        return null;
    let inc_prefixes = child_effective_include_prefixes(grp, section);
    let inc_countries = list_value(grp, "include_countries");
    let inc_outbounds = list_value(grp, "include_outbounds");
    let inc_regex = list_value(grp, "include_regex");
    let inc_protocols = list_value(grp, "include_protocols");
    let inc_transports = list_value(grp, "include_transports");
    let inc_securities = list_value(grp, "include_securities");
    let inc_ports = list_value(grp, "include_ports");
    let inc_params = raw_option(grp, "include_proxy_parameters") != null
        ? bool_option(grp, "include_proxy_parameters", false)
        : (length(inc_protocols) > 0 || length(inc_transports) > 0 || length(inc_securities) > 0 || length(inc_ports) > 0);

    let exc_prefixes = list_value(grp, "exclude_prefixes");
    let exc_countries = list_value(grp, "exclude_countries");
    let exc_outbounds = list_value(grp, "exclude_outbounds");
    let exc_regex = list_value(grp, "exclude_regex");
    let exc_protocols = list_value(grp, "exclude_protocols");
    let exc_transports = list_value(grp, "exclude_transports");
    let exc_securities = list_value(grp, "exclude_securities");
    let exc_ports = list_value(grp, "exclude_ports");
    let exc_params = raw_option(grp, "exclude_proxy_parameters") != null
        ? bool_option(grp, "exclude_proxy_parameters", false)
        : (length(exc_protocols) > 0 || length(exc_transports) > 0 || length(exc_securities) > 0 || length(exc_ports) > 0);

    let has_inc = length(inc_prefixes) > 0 || length(inc_countries) > 0 || length(inc_outbounds) > 0 ||
        length(inc_regex) > 0 || (inc_params && (length(inc_protocols) > 0 || length(inc_transports) > 0 || length(inc_securities) > 0 || length(inc_ports) > 0));
    let has_exc = length(exc_prefixes) > 0 || length(exc_countries) > 0 || length(exc_outbounds) > 0 ||
        length(exc_regex) > 0 || (exc_params && (length(exc_protocols) > 0 || length(exc_transports) > 0 || length(exc_securities) > 0 || length(exc_ports) > 0));

    return {
        id: section_name(grp),
        name: option(grp, "name", section_name(grp)),
        source_refs: whitespace_list_value(grp, "source_refs"),
        mode: resolve_effective_filter_mode(option(grp, "filter_mode", ""), has_inc, has_exc),
        country_mode: option(grp, "detect_server_country", "flag_emoji") || "flag_emoji",
        include_prefixes: inc_prefixes,
        include_countries: inc_countries,
        include_outbounds: inc_outbounds,
        include_regex: inc_regex,
        include_proxy_parameters: inc_params,
        include_protocols: inc_protocols,
        include_transports: inc_transports,
        include_securities: inc_securities,
        include_ports: inc_ports,
        exclude_prefixes: exc_prefixes,
        exclude_countries: exc_countries,
        exclude_outbounds: exc_outbounds,
        exclude_regex: exc_regex,
        exclude_proxy_parameters: exc_params,
        exclude_protocols: exc_protocols,
        exclude_transports: exc_transports,
        exclude_securities: exc_securities,
        exclude_ports: exc_ports
    };
}

function section_pool_filter_spec(section) {
    if (section == null || type(section) != "object")
        return null;
    let inc_prefixes = list_value(section, "section_include_prefixes");
    let inc_countries = list_value(section, "section_include_countries");
    let inc_outbounds = list_value(section, "section_include_outbounds");
    let inc_regex = list_value(section, "section_include_regex");
    let inc_params = bool_option(section, "section_include_proxy_parameters", false);
    let inc_protocols = list_value(section, "section_include_protocols");
    let inc_transports = list_value(section, "section_include_transports");
    let inc_securities = list_value(section, "section_include_securities");
    let inc_ports = list_value(section, "section_include_ports");

    let exc_prefixes = list_value(section, "section_exclude_prefixes");
    let exc_countries = list_value(section, "section_exclude_countries");
    let exc_outbounds = list_value(section, "section_exclude_outbounds");
    let exc_regex = list_value(section, "section_exclude_regex");
    let exc_params = bool_option(section, "section_exclude_proxy_parameters", false);
    let exc_protocols = list_value(section, "section_exclude_protocols");
    let exc_transports = list_value(section, "section_exclude_transports");
    let exc_securities = list_value(section, "section_exclude_securities");
    let exc_ports = list_value(section, "section_exclude_ports");

    let has_inc = length(inc_prefixes) > 0 || length(inc_countries) > 0 || length(inc_outbounds) > 0 ||
        length(inc_regex) > 0 || (inc_params && (length(inc_protocols) > 0 || length(inc_transports) > 0 || length(inc_securities) > 0 || length(inc_ports) > 0));
    let has_exc = length(exc_prefixes) > 0 || length(exc_countries) > 0 || length(exc_outbounds) > 0 ||
        length(exc_regex) > 0 || (exc_params && (length(exc_protocols) > 0 || length(exc_transports) > 0 || length(exc_securities) > 0 || length(exc_ports) > 0));

    let mode = resolve_effective_filter_mode(option(section, "section_filter_mode", ""), has_inc, has_exc);
    if (mode == "disabled")
        return null;

    return {
        mode,
        country_mode: option(section, "section_detect_server_country", "flag_emoji") || "flag_emoji",
        include_prefixes: inc_prefixes,
        include_countries: inc_countries,
        include_outbounds: inc_outbounds,
        include_regex: inc_regex,
        include_proxy_parameters: inc_params,
        include_protocols: inc_protocols,
        include_transports: inc_transports,
        include_securities: inc_securities,
        include_ports: inc_ports,
        exclude_prefixes: exc_prefixes,
        exclude_countries: exc_countries,
        exclude_outbounds: exc_outbounds,
        exclude_regex: exc_regex,
        exclude_proxy_parameters: exc_params,
        exclude_protocols: exc_protocols,
        exclude_transports: exc_transports,
        exclude_securities: exc_securities,
        exclude_ports: exc_ports
    };
}

function ipv4_to_u32(ip_str) {
    let parts = split(trim(as_string(ip_str)), ".");
    if (length(parts) != 4)
        return -1;
    let acc = 0;
    for (let p in parts) {
        if (match(p, /^[0-9]+$/) == null)
            return -1;
        let oct = int(p, 10);
        if (oct < 0 || oct > 255)
            return -1;
        acc = (acc * 256) + oct;
    }
    return acc;
}

function ip_matches_cidr_or_exact(ip_query, target_cidr) {
    ip_query = lc(trim(as_string(ip_query)));
    target_cidr = lc(trim(as_string(target_cidr)));
    if (ip_query == "" || target_cidr == "")
        return false;
    if (ip_query == target_cidr)
        return true;

    let q_slash = index(ip_query, "/");
    let q_ip = q_slash > 0 ? substr(ip_query, 0, q_slash) : ip_query;

    let t_slash = index(target_cidr, "/");
    let t_ip = t_slash > 0 ? substr(target_cidr, 0, t_slash) : target_cidr;
    let t_prefix = t_slash > 0 ? int(substr(target_cidr, t_slash + 1), 10) : (index(t_ip, ":") >= 0 ? 128 : 32);

    if (q_ip == t_ip)
        return true;

    let q_u32 = ipv4_to_u32(q_ip);
    let t_u32 = ipv4_to_u32(t_ip);
    if (q_u32 >= 0 && t_u32 >= 0 && t_prefix >= 0 && t_prefix <= 32) {
        if (t_prefix == 0)
            return true;
        let shift_div = 1;
        for (let i = 0; i < (32 - t_prefix); i++)
            shift_div *= 2;
        return int(q_u32 / shift_div) == int(t_u32 / shift_div);
    }
    return false;
}

function port_matches_spec(port_query, port_spec) {
    port_query = trim(as_string(port_query));
    port_spec = trim(as_string(port_spec));
    if (port_query == "" || port_spec == "")
        return false;
    if (port_query == port_spec)
        return true;
    let q_num = int(port_query, 10);
    if (q_num <= 0)
        return false;
    for (let token in split(port_spec, /[,\s]+/)) {
        token = trim(token);
        if (token == "")
            continue;
        if (token == port_query)
            return true;
        let sep = index(token, "-");
        if (sep < 0)
            sep = index(token, ":");
        if (sep > 0) {
            let lo = int(substr(token, 0, sep), 10);
            let hi = int(substr(token, sep + 1), 10);
            if (lo > 0 && hi >= lo && q_num >= lo && q_num <= hi)
                return true;
        }
    }
    return false;
}

function extract_atomic_matchers(obj) {
    obj = object_or_empty(obj);
    let split_mixed = function(list_keys, text_keys) {
        let out = [];
        let seen = {};
        for (let lk in list_keys) {
            for (let v in clean_condition_tokens(obj, lk))
                push_unique_str(out, seen, v);
        }
        for (let tk in text_keys) {
            for (let v in clean_condition_tokens(obj, tk))
                push_unique_str(out, seen, v);
        }
        return out;
    };

    let domains = split_mixed([], [ "domain_text" ]);
    let domain_suffixes = split_mixed([ "domain_suffix", "user_domains" ], [ "domain_suffix_text", "user_domains_text" ]);
    let domain_keywords = split_mixed([ "domain_keyword" ], [ "domain_keyword_text" ]);
    let domain_regexes = split_mixed([ "domain_regex" ], [ "domain_regex_text" ]);

    let seen_dom = {};
    let seen_suf = {};
    let seen_kw = {};
    let seen_rx = {};
    for (let d in domains) seen_dom[d] = true;
    for (let d in domain_suffixes) seen_suf[d] = true;
    for (let d in domain_keywords) seen_kw[d] = true;
    for (let d in domain_regexes) seen_rx[d] = true;

    for (let token in clean_condition_tokens(obj, "domain")) {
        if (substr(token, 0, 5) == "full:") {
            let v = trim(substr(token, 5));
            if (v != "") push_unique_str(domains, seen_dom, v);
        } else if (substr(token, 0, 7) == "domain:") {
            let v = trim(substr(token, 7));
            if (v != "") push_unique_str(domain_suffixes, seen_suf, v);
        } else if (substr(token, 0, 8) == "keyword:") {
            let v = trim(substr(token, 8));
            if (v != "") push_unique_str(domain_keywords, seen_kw, v);
        } else if (substr(token, 0, 6) == "regex:" || substr(token, 0, 7) == "regexp:") {
            let colon = index(token, ":");
            let v = trim(substr(token, colon + 1));
            if (v != "") push_unique_str(domain_regexes, seen_rx, v);
        } else {
            let cleaned = substr(token, 0, 1) == "." ? substr(token, 1) : token;
            if (cleaned != "")
                push_unique_str(domain_suffixes, seen_suf, cleaned);
        }
    }

    return {
        domains,
        domain_suffixes,
        domain_keywords,
        domain_regexes,
        lists: split_mixed([ "community_lists", "rule_set", "rule_set_with_subnets", "domain_ip_lists" ], []),
        dest_ips: split_mixed([ "ip_cidr", "fully_routed_ips" ], [ "ip_cidr_text" ]),
        excluded_ips: split_mixed([ "excluded_ips" ], []),
        source_ips: split_mixed([ "source_ip_cidr" ], [ "source_ip_cidr_text" ]),
        source_macs: split_mixed([ "source_macs" ], []),
        ports: split_mixed([ "ports" ], [ "ports_text" ]),
        protocols: split_mixed([ "protocol" ], []),
        dscp: split_mixed([ "dscp" ], []),
        countries: split_mixed([ "geoip_country" ], [])
    };
}

function evaluate_atomic_condition_match(obj, query) {
    let m = extract_atomic_matchers(obj);
    let core_ip = require("core.ip");

    let q_search = lc(trim(as_string(query.search || query.argument || "")));
    let q_domain = lc(trim(as_string(query.domain || "")));
    let q_list = lc(trim(as_string(query.list || query.rule_set || query.community_list || "")));
    let q_dest_ip = lc(trim(as_string(query.dest_ip || query.ip || "")));
    let q_src_ip = lc(trim(as_string(query.source_ip || "")));
    let q_src_mac = lc(replace(trim(as_string(query.source_mac || query.mac || "")), "-", ":"));
    let q_port = trim(as_string(query.port || ""));
    let q_proto = lc(trim(as_string(query.protocol || "")));
    let q_dscp = lc(trim(as_string(query.dscp || "")));
    let q_country = uc(trim(as_string(query.country || query.geoip_country || "")));

    if (q_search != "") {
        if (core_ip.valid_mac(q_search) && q_src_mac == "")
            q_src_mac = lc(replace(q_search, "-", ":"));
        else if (core_ip.valid_ip_or_cidr(q_search) && q_dest_ip == "" && q_src_ip == "") {
            q_dest_ip = q_search;
        } else if (match(q_search, /^[0-9]+$/) != null && int(q_search, 10) > 0 && int(q_search, 10) <= 65535 && q_port == "") {
            q_port = q_search;
        } else {
            if (q_domain == "")
                q_domain = q_search;
            if (q_list == "")
                q_list = q_search;
        }
    }

    let presence_hits = [];
    let category_results = {};
    let configured_categories = [];

    // 1. Domain & Lists category
    let has_domain_or_list = length(m.domains) > 0 || length(m.domain_suffixes) > 0 ||
        length(m.domain_keywords) > 0 || length(m.domain_regexes) > 0 || length(m.lists) > 0;
    if (has_domain_or_list) {
        push(configured_categories, "domain_or_list");
        let cat_matched = false;
        if (q_domain != "") {
            for (let d in m.domains) {
                let dl = lc(d);
                if (q_domain == dl || (q_search != "" && index(dl, q_search) >= 0)) {
                    cat_matched = true;
                    push(presence_hits, "domain:" + d);
                }
            }
            for (let sfx in m.domain_suffixes) {
                let sl = lc( replace(sfx, /^\.+/, "") );
                if (q_domain == sl || (length(q_domain) > length(sl) && substr(q_domain, length(q_domain) - length(sl) - 1) == "." + sl) || (q_search != "" && index(sl, q_search) >= 0)) {
                    cat_matched = true;
                    push(presence_hits, "domain_suffix:" + sfx);
                }
            }
            for (let kw in m.domain_keywords) {
                let kl = lc(kw);
                if (index(q_domain, kl) >= 0 || (q_search != "" && index(kl, q_search) >= 0)) {
                    cat_matched = true;
                    push(presence_hits, "domain_keyword:" + kw);
                }
            }
            for (let rx in m.domain_regexes) {
                if (lc(rx) == q_domain || (q_search != "" && index(lc(rx), q_search) >= 0)) {
                    cat_matched = true;
                    push(presence_hits, "domain_regex:" + rx);
                }
            }
        }
        let list_probe = q_list != "" ? q_list : q_domain;
        if (list_probe != "") {
            for (let lst in m.lists) {
                let ll = lc(lst);
                if (ll == list_probe || index(ll, list_probe) >= 0 || index(list_probe, ll) >= 0) {
                    cat_matched = true;
                    push(presence_hits, "list:" + lst);
                }
            }
        }
        category_results.domain_or_list = cat_matched;
    }

    // 2. Destination IP category
    if (length(m.dest_ips) > 0) {
        push(configured_categories, "dest_ip");
        let cat_matched = false;
        let ip_probes = [];
        if (q_dest_ip != "") push(ip_probes, q_dest_ip);
        if (q_search != "" && q_search != q_dest_ip) push(ip_probes, q_search);
        for (let probe in ip_probes) {
            for (let cidr in m.dest_ips) {
                if (ip_matches_cidr_or_exact(probe, cidr)) {
                    cat_matched = true;
                    push(presence_hits, "ip_cidr:" + cidr);
                }
            }
        }
        category_results.dest_ip = cat_matched;
    }

    // 3. Source IP / Source MAC category
    if (length(m.source_ips) > 0 || length(m.source_macs) > 0) {
        push(configured_categories, "source");
        let cat_matched = false;
        let src_ip_probes = [];
        if (q_src_ip != "")
            push(src_ip_probes, q_src_ip);
        if (q_src_mac != "") {
            for (let res_ip in core_ip.resolve_mac_to_ips(q_src_mac))
                push(src_ip_probes, res_ip);
        }
        // In presence mode, if user passed IP in q_search/q_dest_ip without knowing if it's src or dst, check presence
        let presence_only_ip = (q_src_ip == "" && q_dest_ip != "" && q_search != "") ? q_dest_ip : "";

        for (let mac in m.source_macs) {
            let ml = lc(replace(mac, "-", ":"));
            if (q_src_mac != "" && ml == q_src_mac) {
                cat_matched = true;
                push(presence_hits, "source_mac:" + mac);
            } else {
                for (let res_ip in core_ip.resolve_mac_to_ips(ml)) {
                    for (let sip in src_ip_probes) {
                        if (ip_matches_cidr_or_exact(sip, res_ip)) {
                            cat_matched = true;
                            push(presence_hits, "source_mac_ip:" + mac + "(" + res_ip + ")");
                        }
                    }
                    if (presence_only_ip != "" && ip_matches_cidr_or_exact(presence_only_ip, res_ip))
                        push(presence_hits, "source_mac_ip:" + mac + "(" + res_ip + ")");
                }
            }
        }
        for (let scidr in m.source_ips) {
            if (core_ip.valid_mac(scidr)) {
                let ml = lc(replace(scidr, "-", ":"));
                if (q_src_mac != "" && ml == q_src_mac) {
                    cat_matched = true;
                    push(presence_hits, "source_mac:" + scidr);
                }
            }
            for (let sip in src_ip_probes) {
                if (ip_matches_cidr_or_exact(sip, scidr)) {
                    cat_matched = true;
                    push(presence_hits, "source_ip_cidr:" + scidr);
                }
            }
            if (presence_only_ip != "" && ip_matches_cidr_or_exact(presence_only_ip, scidr))
                push(presence_hits, "source_ip_cidr:" + scidr);
        }
        category_results.source = cat_matched;
    }

    // 4. Ports category
    if (length(m.ports) > 0) {
        push(configured_categories, "ports");
        let cat_matched = false;
        if (q_port != "") {
            for (let p in m.ports) {
                if (port_matches_spec(q_port, p)) {
                    cat_matched = true;
                    push(presence_hits, "port:" + p);
                }
            }
        }
        category_results.ports = cat_matched;
    }

    // 5. Protocol category
    if (length(m.protocols) > 0) {
        push(configured_categories, "protocol");
        let cat_matched = false;
        if (q_proto != "") {
            for (let pr in m.protocols) {
                if (lc(pr) == q_proto) {
                    cat_matched = true;
                    push(presence_hits, "protocol:" + pr);
                }
            }
        }
        category_results.protocol = cat_matched;
    }

    // 6. DSCP category
    if (length(m.dscp) > 0) {
        push(configured_categories, "dscp");
        let cat_matched = false;
        if (q_dscp != "") {
            for (let dv in m.dscp) {
                if (lc(dv) == q_dscp || parse_dscp_value(dv) == parse_dscp_value(q_dscp)) {
                    cat_matched = true;
                    push(presence_hits, "dscp:" + dv);
                }
            }
        }
        category_results.dscp = cat_matched;
    }

    // 7. GeoIP Country category
    if (length(m.countries) > 0) {
        push(configured_categories, "country");
        let cat_matched = false;
        if (q_country != "") {
            for (let c in m.countries) {
                if (uc(c) == q_country) {
                    cat_matched = true;
                    push(presence_hits, "geoip_country:" + c);
                }
            }
        }
        category_results.country = cat_matched;
    }

    let exact_match = length(configured_categories) > 0;
    let missing_categories = [];
    for (let cat in configured_categories) {
        if (!category_results[cat]) {
            exact_match = false;
            push(missing_categories, cat);
        }
    }

    return {
        has_presence: length(presence_hits) > 0,
        presence_hits,
        exact_match,
        configured_categories,
        missing_categories
    };
}

function trace_rules(query, sections_list) {
    query = object_or_empty(query);
    if (sections_list == null) {
        let cursor = uci_core.cursor();
        cursor.load(CONFIG_NAME);
        set_item_sections_from_cursor(cursor, CONFIG_NAME);
        sections_list = [];
        cursor.foreach(CONFIG_NAME, "section", function(sec) {
            push(sections_list, sec);
        });
    }

    let leaf_eval_cache = {};
    for (let cond in condition_sections()) {
        let cid = section_name(cond);
        if (cid != "")
            leaf_eval_cache[cid] = evaluate_atomic_condition_match(cond, query);
    }

    let eval_ast = null;
    eval_ast = function(node) {
        if (node == null)
            return { presence: false, exact: false, hits: [], matched_leaves: [], unmatched_leaves: [] };
        if (node.type == "leaf") {
            let ev = leaf_eval_cache[node.id] || evaluate_atomic_condition_match(node.section, query);
            return {
                presence: ev.has_presence,
                exact: ev.exact_match,
                hits: ev.presence_hits,
                matched_leaves: ev.exact_match ? [ node.id ] : [],
                unmatched_leaves: ev.exact_match ? [] : [ node.id ]
            };
        }
        if (node.type == "not") {
            let sub = eval_ast(node.child);
            return {
                presence: sub.presence,
                exact: !sub.exact,
                hits: sub.hits,
                matched_leaves: sub.matched_leaves,
                unmatched_leaves: sub.unmatched_leaves
            };
        }
        let is_and = (node.type == "and");
        let any_presence = false;
        let exact_acc = is_and ? true : false;
        let hits = [];
        let matched_leaves = [];
        let unmatched_leaves = [];
        let seen_hits = {};
        let seen_m = {};
        let seen_u = {};
        for (let ch in (node.children || [])) {
            let r = eval_ast(ch);
            if (r.presence)
                any_presence = true;
            if (is_and)
                exact_acc = exact_acc && r.exact;
            else
                exact_acc = exact_acc || r.exact;
            for (let h in r.hits) push_unique_str(hits, seen_hits, h);
            for (let ml in r.matched_leaves) push_unique_str(matched_leaves, seen_m, ml);
            for (let ul in r.unmatched_leaves) push_unique_str(unmatched_leaves, seen_u, ul);
        }
        return {
            presence: any_presence,
            exact: exact_acc,
            hits,
            matched_leaves,
            unmatched_leaves
        };
    };

    let condition_results = [];
    let presence_conditions = [];
    let exact_conditions = [];
    for (let cond in condition_sections()) {
        let cid = section_name(cond);
        if (cid == "")
            continue;
        let ast = condition_ast(cid, {});
        let res = eval_ast(ast);
        let q_search = lc(trim(as_string(query.search || "")));
        let id_hit = (q_search != "" && index(lc(cid), q_search) >= 0);
        if (res.presence || res.exact || id_hit) {
            let c_entry = {
                id: cid,
                name: option(cond, "name", cid) || cid,
                presence_match: res.presence || id_hit,
                exact_match: res.exact,
                hits: res.hits,
                matched_leaves: res.matched_leaves,
                unmatched_leaves: res.unmatched_leaves
            };
            push(condition_results, c_entry);
            if (c_entry.presence_match)
                push(presence_conditions, c_entry);
            if (c_entry.exact_match)
                push(exact_conditions, c_entry);
        }
    }

    let section_results = [];
    let presence_sections = [];
    let exact_sections = [];
    let winning_section = null;
    for (let sec in sections_list) {
        let sid = section_name(sec);
        if (sid == "" || !bool_option(sec, "enabled", true))
            continue;
        let inline_eval = evaluate_atomic_condition_match(sec, query);
        let ast = section_condition_ast(sec);
        let ast_eval = ast != null ? eval_ast(ast) : null;

        let presence_match = inline_eval.has_presence || (ast_eval != null && ast_eval.presence);
        let exact_match = false;
        if (ast_eval != null && length(inline_eval.configured_categories) > 0)
            exact_match = ast_eval.exact && inline_eval.exact_match;
        else if (ast_eval != null)
            exact_match = ast_eval.exact;
        else
            exact_match = inline_eval.exact_match;

        let hits = [];
        let seen_h = {};
        for (let h in inline_eval.presence_hits) push_unique_str(hits, seen_h, h);
        if (ast_eval != null)
            for (let h in ast_eval.hits) push_unique_str(hits, seen_h, h);

        if (presence_match || exact_match) {
            let entry = {
                id: sid,
                name: option(sec, "name", sid) || sid,
                action: action(sec),
                presence_match,
                exact_match,
                hits,
                matched_conditions: ast_eval != null ? ast_eval.matched_leaves : [],
                unmatched_conditions: ast_eval != null ? ast_eval.unmatched_leaves : []
            };
            push(section_results, entry);
            if (presence_match)
                push(presence_sections, entry);
            if (exact_match) {
                push(exact_sections, entry);
                if (winning_section == null)
                    winning_section = entry;
            }
        }
    }

    return {
        mode: option(query, "mode", "both") || "both",
        query,
        conditions: condition_results,
        presence_conditions,
        exact_conditions,
        sections: section_results,
        presence_sections,
        exact_sections,
        winning_section
    };
}

function probe_outbound_url(target_url, group_id, timeout_ms) {
    if (type(target_url) == "object") {
        let obj = target_url;
        target_url = obj.url || "";
        group_id = obj.group || obj.group_id || "";
        timeout_ms = obj.timeout || obj.timeout_ms || 4000;
    } else if (substr(trim(as_string(target_url)), 0, 1) == "{") {
        try {
            let obj = json(trim(as_string(target_url)));
            if (type(obj) == "object") {
                target_url = obj.url || "";
                group_id = obj.group || obj.group_id || "";
                timeout_ms = obj.timeout || obj.timeout_ms || 4000;
            }
        } catch (e) {}
    }
    target_url = trim(as_string(target_url));
    if (target_url == "")
        target_url = "https://www.gstatic.com/generate_204";
    group_id = trim(as_string(group_id));
    timeout_ms = int(timeout_ms || 4000, 10);
    if (timeout_ms <= 0)
        timeout_ms = 4000;

    let env_tmp = getenv("TMP_SING_BOX_FOLDER");
    let cfg_path = "/etc/tachyon-core/config.json";
    if (env_tmp != null && env_tmp != "" && common.file_exists(env_tmp + "/config.json"))
        cfg_path = env_tmp + "/config.json";
    else if (common.file_exists("/etc/tachyon-core/config.json"))
        cfg_path = "/etc/tachyon-core/config.json";
    else if (common.file_exists("/etc/sing-box/config.json"))
        cfg_path = "/etc/sing-box/config.json";
    else if (common.file_exists("/tmp/tachyon-core/config.json"))
        cfg_path = "/tmp/tachyon-core/config.json";

    let host = "127.0.0.1:9090";
    let secret = "";
    let sb_cfg = common.read_json_file(cfg_path);
    if (type(sb_cfg) == "object") {
        let ext = sb_cfg?.experimental?.clash_api?.external_controller;
        if (ext) {
            let parts = split(as_string(ext), ":");
            let ip = length(parts) > 1 ? parts[0] : "";
            let port = length(parts) > 1 ? parts[length(parts) - 1] : "9090";
            host = (ip == "0.0.0.0" || ip == "") ? ("127.0.0.1:" + port) : as_string(ext);
        }
        if (sb_cfg?.experimental?.clash_api?.secret)
            secret = as_string(sb_cfg.experimental.clash_api.secret);
    }

    let runtime_urltest = null;
    try { runtime_urltest = require("tachyon_core.urltest"); } catch (e) {}

    let hidden_tags = {};
    let group_tags = {};
    let names_map = {};
    let countries_map = {};
    let prefixes_map = {};
    let sources_map = {};
    let source_id_map = {};
    let protocols_map = {};
    let sec_by_tag = {};
    let sub_titles = {};

    let sec_sub_to_src_id = {};
    for (let sec in uci_core.section_objects(CONFIG_NAME, "section")) {
        let sname = section_name(sec);
        if (sname == "")
            continue;
        let sub_i = 0;
        for (let src in section_effective_outbound_sources(sec)) {
            let st = lc(trim(option(src, "source_type", "subscription")));
            if (st == "subscription" || trim(option(src, "url", "")) != "") {
                sub_i++;
                sec_sub_to_src_id[sname + ":sub:" + sub_i] = section_name(src);
            }
        }
    }

    let cache_dir = getenv("TACHYON_SECTION_CACHE_DIR") || "/var/run/tachyon/section-cache";
    let cache_files = fs.glob(cache_dir + "/*.json") || [];
    for (let cpath in cache_files) {
        let c = common.read_json_file(cpath);
        if (type(c) != "object")
            continue;
        let sec_name = as_string(c.section || "");
        if (type(c.hiddenOutboundTags) == "array") {
            for (let htag in c.hiddenOutboundTags)
                if (trim(as_string(htag)) != "")
                    hidden_tags[as_string(htag)] = true;
        } else {
            for (let htag, hval in object_or_empty(c.hiddenOutboundTags))
                if (hval)
                    hidden_tags[htag] = true;
        }
        if (type(c.hiddenOutbounds) == "array") {
            for (let htag in c.hiddenOutbounds)
                if (trim(as_string(htag)) != "")
                    hidden_tags[as_string(htag)] = true;
        }
        for (let gtag, gval in object_or_empty(c.urltestGroups))
            group_tags[gtag] = true;
        for (let ptag, pval in object_or_empty(c.priorityGroups))
            group_tags[ptag] = true;
        for (let sm in (type(c.subscriptionMetadata) == "array" ? c.subscriptionMetadata : [])) {
            if (type(sm) == "object" && sm.sourceIndex != null && trim(as_string(sm.title || "")) != "")
                sub_titles[sec_name + ":sub:" + as_string(sm.sourceIndex)] = trim(as_string(sm.title));
        }
        let meta = object_or_empty(c.outboundMetadata);
        let m_names = object_or_empty(meta.names);
        let m_countries = object_or_empty(meta.countries);
        let m_prefixes = object_or_empty(meta.prefixes);
        let m_sources = object_or_empty(meta.sources);
        let m_protocols = object_or_empty(meta.protocols);
        for (let tag, nval in m_names) {
            if (lc(as_string(m_protocols[tag] || "")) == "urltest" || lc(as_string(m_protocols[tag] || "")) == "selector") {
                group_tags[tag] = true;
                continue;
            }
            names_map[tag] = as_string(nval || tag);
            if (sec_name != "")
                sec_by_tag[tag] = sec_name;
        }
        for (let tag, cval in m_countries)
            if (trim(as_string(cval)) != "")
                countries_map[tag] = uc(trim(as_string(cval)));
        for (let tag, pval in m_prefixes)
            if (trim(as_string(pval)) != "")
                prefixes_map[tag] = trim(as_string(pval));
        for (let tag, sval in m_sources) {
            let sv = trim(as_string(sval));
            if (sv != "") {
                sources_map[tag] = sv;
                if (sec_name != "" && sec_sub_to_src_id[sec_name + ":" + sv])
                    source_id_map[tag] = sec_sub_to_src_id[sec_name + ":" + sv];
                else if (outbound_source_section(sv) != null)
                    source_id_map[tag] = sv;
            }
        }
        for (let tag, prval in m_protocols)
            if (trim(as_string(prval)) != "")
                protocols_map[tag] = lc(trim(as_string(prval)));
    }

    let candidate_tags = [];
    let seen_tags = {};
    let selector_groups = [];
    let urltest_groups_by_tag = {};
    if (type(sb_cfg) == "object" && type(sb_cfg.outbounds) == "array") {
        let skip_types = { selector: true, urltest: true, direct: true, block: true, dns: true, desync: true };
        for (let ob in sb_cfg.outbounds) {
            if (type(ob) != "object") continue;
            let otype = lc(as_string(ob.type || ""));
            let otag = as_string(ob.tag || "");
            if (otype == "selector" && otag != "" && type(ob.outbounds) == "array") {
                push(selector_groups, { tag: otag, outbounds: ob.outbounds });
                continue;
            }
            if (otype == "urltest" && otag != "" && type(ob.outbounds) == "array") {
                urltest_groups_by_tag[otag] = ob.outbounds;
                continue;
            }
            if (otag == "" || skip_types[otype]) continue;
            if (hidden_tags[otag] || group_tags[otag]) continue;
            if (protocols_map[otag] == null || protocols_map[otag] == "")
                protocols_map[otag] = otype;
            if (!seen_tags[otag]) {
                seen_tags[otag] = true;
                push(candidate_tags, otag);
            }
        }
    }

    for (let tag in candidate_tags) {
        if (!countries_map[tag] && runtime_urltest != null && type(runtime_urltest.countries_from_flag_names) == "function") {
            let detected = runtime_urltest.countries_from_flag_names({ [tag]: names_map[tag] || tag });
            if (detected && detected[tag])
                countries_map[tag] = detected[tag];
        }
        if (!prefixes_map[tag]) {
            let sec_name = sec_by_tag[tag] || "";
            let src_key = sources_map[tag] || "";
            if (sec_name != "" && src_key != "" && sub_titles[sec_name + ":" + src_key])
                prefixes_map[tag] = sub_titles[sec_name + ":" + src_key];
            else if (sec_name != "" && protocols_map[tag])
                prefixes_map[tag] = sec_name + " [" + uc(protocols_map[tag]) + "]";
            else if (protocols_map[tag])
                prefixes_map[tag] = uc(protocols_map[tag]);
        }
    }

    if (group_id == "all" || (match(group_id, /^[0-9]+$/) && outbound_group_section(group_id) == null)) {
        if (match(group_id, /^[0-9]+$/))
            timeout_ms = int(group_id);
        group_id = "";
    }

    if (group_id != "") {
        if (substr(group_id, 0, 4) == "bal:") {
            let bid = substr(group_id, 4);
            let allowed = {};
            for (let ut_tag, members in urltest_groups_by_tag) {
                if (ut_tag == bid || index(ut_tag, "-" + bid + "-out") >= 0) {
                    for (let m in members)
                        allowed[as_string(m)] = true;
                }
            }
            let filtered = [];
            for (let t in candidate_tags)
                if (allowed[t])
                    push(filtered, t);
            candidate_tags = filtered;
        } else if (substr(group_id, 0, 4) == "src:") {
            let sid = substr(group_id, 4);
            let src = outbound_source_section(sid);
            let filtered = [];
            if (src != null) {
                let pfx = bool_option(src, "prefix_nodes", true) ? trim(option(src, "node_prefix", "")) : "";
                let stype = lc(trim(option(src, "source_type", "subscription")));
                if (!is_dpi_or_desync_source_type(stype)) {
                    for (let t in candidate_tags) {
                        if (source_id_map[t] == sid) {
                            push(filtered, t);
                            continue;
                        }
                        if (source_id_map[t] == null && pfx != "" && (lc(prefixes_map[t] || "") == lc(pfx) || index(lc(names_map[t] || t), lc(pfx) + " ") == 0)) {
                            push(filtered, t);
                            continue;
                        }
                        if (source_id_map[t] == null && stype != "subscription" && lc(protocols_map[t] || "") == stype) {
                            push(filtered, t);
                            continue;
                        }
                    }
                }
            }
            candidate_tags = filtered;
        } else if (outbound_group_section(group_id) != null) {
            let gspec = outbound_group_filter_spec(group_id);
            if (gspec != null) {
                let inc_c = {};
                for (let c in (gspec.include_countries || [])) inc_c[uc(trim(as_string(c)))] = true;
                let exc_c = {};
                for (let c in (gspec.exclude_countries || [])) exc_c[uc(trim(as_string(c)))] = true;
                let inc_p = {};
                for (let p in (gspec.include_protocols || [])) inc_p[lc(trim(as_string(p)))] = true;
                let filtered = [];
                for (let t in candidate_tags) {
                    let tname = names_map[t] || t;
                    let tc = countries_map[t] || "";
                    let tp = protocols_map[t] || "";
                    if (gspec.mode == "include" || gspec.mode == "mixed") {
                        if (length(keys(inc_c)) > 0 && !inc_c[tc]) continue;
                        if (length(keys(inc_p)) > 0 && !inc_p[tp]) continue;
                        if (length(gspec.include_prefixes || []) > 0) {
                            let p_ok = false;
                            for (let pfx in gspec.include_prefixes)
                                if (lc(prefixes_map[t] || "") == lc(pfx) || index(lc(tname), lc(pfx)) == 0)
                                    p_ok = true;
                            if (!p_ok) continue;
                        }
                        if (length(gspec.include_regex || []) > 0 && runtime_urltest != null) {
                            let matched_re = runtime_urltest.regex_matching_tag_array([ t ], { [t]: tname }, gspec.include_regex);
                            if (length(matched_re) == 0) continue;
                        }
                    }
                    if (gspec.mode == "exclude" || gspec.mode == "mixed") {
                        if (length(keys(exc_c)) > 0 && exc_c[tc]) continue;
                        if (length(gspec.exclude_regex || []) > 0 && runtime_urltest != null) {
                            let matched_re = runtime_urltest.regex_matching_tag_array([ t ], { [t]: tname }, gspec.exclude_regex);
                            if (length(matched_re) > 0) continue;
                        }
                    }
                    push(filtered, t);
                }
                candidate_tags = filtered;
            }
        } else {
            let filtered = [];
            for (let t in candidate_tags)
                if (index(t, group_id) >= 0 || index(names_map[t] || "", group_id) >= 0)
                    push(filtered, t);
            candidate_tags = filtered;
        }
    }

    let urlencode_seg = function(val) {
        val = as_string(val);
        let out = [];
        for (let i = 0; i < length(val); i++) {
            let ch = substr(val, i, 1);
            if (match(ch, /^[A-Za-z0-9_.~-]$/))
                push(out, ch);
            else
                push(out, sprintf("%%%02X", ord(val, i)));
        }
        return join("", out);
    };

    let results = [];
    let reachable_count = 0;
    if (timeout_ms > 2000)
        timeout_ms = 2000;
    if (timeout_ms < 800)
        timeout_ms = 1800;
    let max_sec = 3;

    let query_str = "?url=" + urlencode_seg(target_url) + "&timeout=" + as_string(timeout_ms);
    let batch_jobs = [];
    let job_idx = 0;

    for (let tag in candidate_tags) {
        job_idx++;
        push(batch_jobs, {
            tag: tag,
            url: "http://" + host + "/proxies/" + urlencode_seg(tag) + "/delay" + query_str,
            file: "/tmp/tachyon-probe-p" + job_idx + ".json"
        });
    }

    let proxy_delays = {};
    let proxy_errors = {};

    if (length(batch_jobs) > 0) {
        let curl_args = [ "curl", "-Z", "--parallel-immediate", "--parallel-max", "64", "-s", "-m", as_string(max_sec) ];
        if (secret != "") {
            push(curl_args, "-H");
            push(curl_args, "Authorization: Bearer " + secret);
        }
        for (let job in batch_jobs) {
            try { fs.unlink(job.file); } catch (e) {}
            push(curl_args, "-o");
            push(curl_args, job.file);
            push(curl_args, job.url);
        }
        common.command_capture(common.command_from_args(curl_args));
        for (let job in batch_jobs) {
            let raw = null;
            try { raw = fs.readfile(job.file); } catch (e) { raw = null; }
            try { fs.unlink(job.file); } catch (e) {}
            if (raw != null && trim(raw) != "") {
                try {
                    let parsed = json(raw);
                    if (type(parsed) == "object") {
                        if (parsed.delay != null && int(parsed.delay) > 0)
                            proxy_delays[job.tag] = int(parsed.delay);
                        else if (parsed.message != null)
                            proxy_errors[job.tag] = as_string(parsed.message);
                    }
                } catch (e) {
                    proxy_errors[job.tag] = "invalid response";
                }
            } else {
                proxy_errors[job.tag] = "unreachable";
            }
        }
    }

    for (let tag in candidate_tags) {
        let delay = proxy_delays[tag] != null && proxy_delays[tag] > 0 ? proxy_delays[tag] : null;
        let err_msg = delay != null ? "" : (proxy_errors[tag] || "unreachable");
        let is_ok = delay != null && delay > 0;
        if (is_ok)
            reachable_count++;
        let display_name = names_map[tag] || tag;
        let cc = countries_map[tag] || "";
        let src_label = prefixes_map[tag] || "—";
        push(results, {
            tag,
            name: display_name,
            country: cc != "" ? cc : "—",
            prefix: src_label,
            source: src_label,
            reachable: is_ok,
            delay_ms: delay,
            error: err_msg
        });
    }

    sort(results, function(a, b) {
        if (a.reachable != b.reachable)
            return a.reachable ? -1 : 1;
        if (a.reachable && b.reachable && a.delay_ms != b.delay_ms)
            return a.delay_ms - b.delay_ms;
        return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    });

    return {
        url: target_url,
        group_id,
        timeout_ms,
        reachable_count,
        total_count: length(results),
        total: length(results),
        results
    };
}

function cli_trace_rules(raw_arg) {
    let query = {};
    raw_arg = trim(as_string(raw_arg));
    if (raw_arg != "") {
        if (substr(raw_arg, 0, 1) == "{") {
            try { query = json(raw_arg); } catch (e) { query = { search: raw_arg }; }
        } else {
            query = { search: raw_arg };
        }
    }
    print(sprintf("%J\n", trace_rules(query, null)));
    return 0;
}

function cli_probe_url(target_url, group_id, timeout_ms) {
    let raw_first = trim(as_string(target_url));
    if (substr(raw_first, 0, 1) == "{") {
        try {
            let parsed = json(raw_first);
            if (type(parsed) == "object") {
                target_url = parsed.url || "";
                group_id = parsed.group != null ? parsed.group : (parsed.group_id || "");
                timeout_ms = parsed.timeout != null ? parsed.timeout : (parsed.timeout_ms || 1800);
            }
        } catch (e) {}
    }
    let cursor = uci_core.cursor();
    cursor.load(CONFIG_NAME);
    set_item_sections_from_cursor(cursor, CONFIG_NAME);
    print(sprintf("%J\n", probe_outbound_url(target_url, group_id, timeout_ms)));
    return 0;
}

function append_unique(result, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;
    seen[value] = true;
    push(result, value);
}

function subscription_download_targets(sections) {
    let result = [];
    let seen = {};

    for (let section in sections) {
        section = object_or_empty(section);
        let name = option(section, ".name", "");

        for (let source in subscription_urls(section)) {
            let target = subscription_download_section(section, source);
            if (target != "")
                append_unique(result, seen, target);
        }
    }

    return result;
}

function subscription_download_target_port(sections, target, base_port) {
    target = as_string(target);
    base_port = int(base_port || 0);

    let targets = subscription_download_targets(sections);
    for (let i = 0; i < length(targets); i++)
        if (targets[i] == target)
            return base_port + 2 + i;

    return 0;
}

// Cascade-delete all child sections (subscription_url, urltest, etc.) that
// belong to the given parent section, along with cross-references and disk caches.
// Returns the number of children removed.
function cascade_delete_section(cursor, config_name, parent_name) {
    let removed = 0;
    config_name = as_string(config_name || CONFIG_NAME);
    parent_name = as_string(parent_name || "");
    if (parent_name == "")
        return 0;

    // 1. Delete priority_level belonging to priority_group in this section
    try {
        let group_names = [];
        cursor.foreach(config_name, "priority_group", function(section) {
            if (option(section, "section", "") == parent_name)
                push(group_names, section_name(section));
        });
        for (let gname in group_names) {
            let level_names = [];
            cursor.foreach(config_name, "priority_level", function(section) {
                if (option(section, "group", "") == gname || option(section, "section", "") == parent_name)
                    push(level_names, section_name(section));
            });
            for (let lname in level_names) {
                cursor.delete(config_name, lname);
                removed++;
            }
            cursor.delete(config_name, gname);
            removed++;
        }
    } catch (e) {}

    // 2. Delete all other child sections (subscription_url, section_interface, urltest, priority_level)
    for (let type_name in [ "subscription_url", "section_interface", "urltest", "priority_level" ]) {
        try {
            let to_delete = [];
            cursor.foreach(config_name, type_name, function(section) {
                if (option(section, "section", "") == parent_name)
                    push(to_delete, section_name(section));
            });
            for (let name in to_delete) {
                cursor.delete(config_name, name);
                removed++;
            }
        } catch (e) {}
    }

    // 3. Clean references in settings
    try {
        let smart_detect = cursor.get(config_name, "settings", "smart_detect_sections");
        if (type(smart_detect) == "array") {
            let filtered = [];
            for (let sec in smart_detect) {
                if (as_string(sec) != parent_name)
                    push(filtered, sec);
            }
            if (length(filtered) != length(smart_detect))
                cursor.set(config_name, "settings", "smart_detect_sections", filtered);
        } else if (as_string(smart_detect) == parent_name) {
            cursor.delete(config_name, "settings", "smart_detect_sections");
        }

        for (let opt in [ "dns_detour_section", "download_lists_via_proxy_section", "download_components_via_proxy_section", "warp_proxy_section" ]) {
            if (as_string(cursor.get(config_name, "settings", opt)) == parent_name)
                cursor.delete(config_name, "settings", opt);
        }
    } catch (e) {}

    // 4. Clean references in other sections
    try {
        cursor.foreach(config_name, "section", function(sec) {
            let sname = section_name(sec);
            if (sname == parent_name) return;
            if (option(sec, "outbound_detour_section", "") == parent_name) {
                cursor.delete(config_name, sname, "outbound_detour_section");
                cursor.set(config_name, sname, "outbound_detour_enabled", "0");
            }
            if (option(sec, "dns_detour_section", "") == parent_name) {
                cursor.delete(config_name, sname, "dns_detour_section");
                cursor.set(config_name, sname, "dns_detour_enabled", "0");
            }
            let gm = list_option(sec, "group_members");
            if (length(gm) > 0) {
                let next_gm = [];
                let gm_changed = false;
                for (let m in gm) {
                    if (trim(as_string(m)) == parent_name)
                        gm_changed = true;
                    else
                        push(next_gm, m);
                }
                if (gm_changed) {
                    if (length(next_gm) > 0)
                        cursor.set(config_name, sname, "group_members", next_gm);
                    else
                        cursor.delete(config_name, sname, "group_members");
                }
            }
        });
    } catch (e) {}

    // 5. Clean references in servers
    try {
        cursor.foreach(config_name, "server", function(srv) {
            let sname = section_name(srv);
            if (option(srv, "routing_section", "") == parent_name) {
                cursor.delete(config_name, sname, "routing_section");
                if (option(srv, "routing_mode", "") == "section")
                    cursor.set(config_name, sname, "routing_mode", "rules");
            }
        });
    } catch (e) {}

    // 6. Delete section cache files
    try {
        remove_file("/var/run/tachyon/section-cache/" + parent_name + ".json");
        remove_file("/etc/tachyon/subscription-cache/" + parent_name + ".json");
        remove_file("/etc/tachyon/subscription-cache/" + parent_name + ".yaml");
        remove_file("/etc/tachyon/subscription-cache/" + parent_name + ".txt");
    } catch (e) {}

    return removed;
}

function cli_delete_section(sec_name) {
    sec_name = trim(as_string(sec_name));
    if (sec_name == "") {
        warn("Usage: tachyon delete_section <section_name>\n");
        return 1;
    }
    let c = uci_core.cursor();
    c.load(CONFIG_NAME);
    let s = c.get_all(CONFIG_NAME, sec_name);
    if (!s) {
        warn("Section '" + sec_name + "' not found\n");
        return 1;
    }
    cascade_delete_section(c, CONFIG_NAME, sec_name);
    c.delete(CONFIG_NAME, sec_name);
    c.commit(CONFIG_NAME);
    print(sprintf("{\"success\":true,\"deleted\":%J}\n", sec_name));
    return 0;
}

let cli_mode = as_string(ARGV[0]);
if (cli_mode == "delete-section")
    exit(cli_delete_section(ARGV[1]));
if (cli_mode == "trace-rules")
    exit(cli_trace_rules(ARGV[1]));
if (cli_mode == "probe-url")
    exit(cli_probe_url(ARGV[1], ARGV[2], ARGV[3]));

return {
    option,
    bool_option,
    list_value,
    whitespace_list_value,
    GEOIP_COUNTRY_MODES,
    GEOIP_COUNTRY_CLOSED_MODES,
    GLOBAL_RULE_OPTIONS,
    global_rule_kinds,
    global_rule_claim,
    global_rules,
    condition_values,
    active_global_rules,
    cascade_delete_section,
    set_item_sections,
    set_item_sections_from_cursor,
    set_item_sections_from_data,
    condition_section,
    condition_sections,
    outbound_source_section,
    outbound_source_sections,
    outbound_group_section,
    outbound_group_sections,
    balancer_section,
    balancer_sections,
    section_condition_refs,
    section_outbound_source_refs,
    section_outbound_group_refs,
    section_balancer_refs,
    condition_refs: section_condition_refs,
    outbound_source_refs: section_outbound_source_refs,
    outbound_group_refs: section_outbound_group_refs,
    balancer_refs: section_balancer_refs,
    is_dpi_or_desync_source_type,
    source_id_for_manual_item,
    section_effective_outbound_sources,
    tokenize_condition_expression,
    parse_condition_expression,
    validate_condition_cycles_for_id,
    validate_condition_graph,
    condition_ast,
    section_condition_ast,
    ast_to_dnf,
    section_leaf_conditions,
    section_effective_clauses,
    resolved_source_ip_cidrs,
    outbound_group_filter_spec,
    section_pool_filter_spec,
    trace_rules,
    probe_outbound_url,
    urltest_group_refs,
    urltest_include_prefixes,
    urltest_exclude_prefixes,
    priority_level_include_prefixes,
    priority_level_exclude_prefixes,
    settings_map,
    item_settings,
    item_option,
    item_bool,
    is_connections_action,
    is_remote_proxy_action,
    is_dpi_or_desync_only_section,
    is_remote_proxy_section,
    normalize_action,
    action,
    connection_urls,
    subscription_urls,
    interfaces,
    outbound_jsons,
    urltests,
    dashboard_filter_mode,
    dashboard_hide_na_servers,
    dashboard_detect_server_country,
    dashboard_include_countries,
    dashboard_include_outbounds,
    dashboard_include_regex,
    dashboard_include_proxy_parameters,
    dashboard_include_protocols,
    dashboard_include_transports,
    dashboard_include_securities,
    dashboard_include_ports,
    dashboard_include_groups,
    dashboard_exclude_countries,
    dashboard_exclude_outbounds,
    dashboard_exclude_regex,
    dashboard_exclude_proxy_parameters,
    dashboard_exclude_protocols,
    dashboard_exclude_transports,
    dashboard_exclude_securities,
    dashboard_exclude_ports,
    dashboard_exclude_groups,
    community_lists,
    rule_sets,
    rule_sets_with_subnets,
    dscp_list,
    dscp_value,
    community_lists_value,
    rule_sets_value,
    rule_sets_with_subnets_value,
    has_connection_sources,
    subscription_url_settings,
    interface_settings,
    urltest_settings,
    subscription_url_enabled,
    subscription_update_enabled,
    subscription_update_interval,
    subscription_dashboard_metadata_enabled,
    subscription_auto_user_agent,
    subscription_auto_hwid,
    subscription_include_urltest_groups,
    subscription_hide_urltest_group_outbounds,
    subscription_urltest_idle_timeout,
    subscription_hide_detour_outbounds,
    subscription_prefix_nodes,
    subscription_node_prefix,
    subscription_user_agent,
    subscription_hwid,
    subscription_custom_device_headers,
    subscription_device_os,
    subscription_ver_os,
    subscription_device_model,
    subscription_device_locale,
    subscription_app_version,
    subscription_accept_language,
    subscription_device_headers,
    device_headers_signature,
    subscription_device_headers_signature,
    subscription_download_section,
    subscription_insecure,
    urltest_text_links,
    interface_domain_resolver_enabled,
    interface_domain_resolver_dns_type,
    interface_domain_resolver_dns_server,
    urltest_check_interval,
    urltest_tolerance,
    urltest_testing_url,
    urltest_display_name,
    urltest_idle_timeout,
    urltest_interrupt_exist_connections,
    urltest_filter_mode,
    urltest_detect_server_country,
    urltest_pin_dashboard,
    urltest_include_countries,
    urltest_include_outbounds,
    urltest_include_regex,
    urltest_include_proxy_parameters,
    urltest_include_protocols,
    urltest_include_transports,
    urltest_include_securities,
    urltest_include_ports,
    urltest_exclude_countries,
    urltest_exclude_outbounds,
    urltest_exclude_regex,
    urltest_exclude_proxy_parameters,
    urltest_exclude_protocols,
    urltest_exclude_transports,
    urltest_exclude_securities,
    urltest_exclude_ports,
    priority_groups,
    priority_group_settings,
    priority_levels,
    priority_level_items,
    priority_group_display_name,
    priority_group_health_url,
    priority_group_active_check_interval,
    priority_group_check_timeout,
    priority_group_recovery_check_interval,
    priority_group_pick_fastest,
    priority_group_switch_to_faster_same_priority,
    priority_group_fastest_check_interval,
    priority_group_interrupt_exist_connections,
    priority_group_pin_dashboard,
    priority_level_display_name,
    priority_level_order,
    priority_level_direct,
    priority_level_filter_mode,
    priority_level_include_countries,
    priority_level_include_outbounds,
    priority_level_include_regex,
    priority_level_include_proxy_parameters,
    priority_level_include_protocols,
    priority_level_include_transports,
    priority_level_include_securities,
    priority_level_include_ports,
    priority_level_exclude_countries,
    priority_level_exclude_outbounds,
    priority_level_exclude_regex,
    priority_level_exclude_proxy_parameters,
    priority_level_exclude_protocols,
    priority_level_exclude_transports,
    priority_level_exclude_securities,
    priority_level_exclude_ports,
    priority_level_countries,
    priority_level_outbounds,
    priority_level_regex,
    priority_level_detect_server_country,
    parse_dscp_value,
    dscp_list,
    dscp_value,
    geoip_country_list,
    geoip_country_mode,
    geoip_country_mode_is_closed,
    geoip_country_value,
    subscription_download_targets,
    subscription_download_target_port,
    has_dns_matchers,
    routed_dns_enabled,
    routed_dns_type,
    routed_dns_servers,
    amnezia_configs,
    item_index_from_cursor,
    cli_delete_section,
    wdtt_sections,
    olcrtc_sections,
    fptn_sections,
    fptn_section_token,
    fptn_transport_mode,
    is_wdtt_action,
    is_olcrtc_action,
    is_fptn_action,
    section_has_routing_matchers,
    section_is_active_provider,
    active_provider_sections,
    active_provider_section_index,
    packet_encoding
};
