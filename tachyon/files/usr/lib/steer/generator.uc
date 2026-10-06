#!/usr/bin/env ucode
//
// steer spec.json generator.
//
// Turns the Tachyon configuration into the steer routing spec
// (/etc/steer/spec.json). Only facts steer can express are written here; the
// switch layer (components/engine_state.uc) parks everything else, so this
// generator never has to guess or silently drop configuration.
//
// Mapping (schema 1 of the steer spec):
//   sections with domain/IP list references -> channels
//   sections by client address/MAC          -> channel `from`
//   proxy outbounds                          -> outputs (interface/vless/direct)
//   direct / direct_bypass                   -> direct output
//   zapret / zapret2 sections                -> kind: zapret output + channel
//
// The generator is pure: it takes the section list and settings and returns a
// spec object. Writing and validating the file is the caller's job.
//

let fs = require("fs");
let common = require("core.common");
let engine = require("core.engine");

let as_string = common.as_string;

// Whether the installed steer build has the vless client. Set per build_spec_v2()
// call; read by build_outputs_v2, which is a separate function.
let steer_vless_supported = true;
let steer_vless_override = null;

// Test seam: the generator decides what to emit, the engine module knows what is
// installed. An explicit answer wins over detection, so a caller driving
// build_spec_v2 directly does not need a steer binary on the machine.
function set_vless_supported(value) { steer_vless_override = value == true; }

const DEFAULT_LAN_DEVICES = [ "br-lan" ];
const DEFAULT_ON_FAIL = "drop";

// ============================================================================
// Helpers
// ============================================================================

function option(section, key, fallback) {
    if (section == null || section[key] == null)
        return fallback;
    let value = section[key];
    if (type(value) == "array")
        return length(value) > 0 ? value[0] : fallback;
    return value;
}

function list_option(section, key) {
    if (section == null || section[key] == null)
        return [];
    let value = section[key];
    if (type(value) == "array")
        return value;
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function bool_option(section, key, fallback) {
    if (section == null || section[key] == null)
        return fallback;
    let value = as_string(section[key]);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function is_enabled(section) {
    return bool_option(section, "enabled", true);
}

// Spec v2 caps every name at 31 bytes, in each namespace separately: clients,
// lists, outputs, upstreams. A longer name is a rejection, and the values we
// derive names from are user labels, so truncation has to happen here rather
// than being left to whatever label happens to fit.
const NAME_MAX_BYTES = 31;

function truncate_name(name) {
    if (length(name) <= NAME_MAX_BYTES)
        return name;
    let trimmed = substr(name, 0, NAME_MAX_BYTES);
    // Never end on a separator: a trailing "-" or "." is ugly and can collide
    // with a sibling name we are about to synthesize.
    while (length(trimmed) > 0) {
        let last = substr(trimmed, -1);
        if (last == "-" || last == ".")
            trimmed = substr(trimmed, 0, length(trimmed) - 1);
        else
            break;
    }
    return length(trimmed) > 0 ? trimmed : "n";
}

// `lan` (clients) and `all` (lists) are taken words. A synthesized name that
// lands on one of them is a reference to the wrong thing at best.
function unique_name(taken, base, reserved) {
    let candidate = base;
    let suffix = 1;
    while (taken[candidate] != null ||
        (reserved != null && index(reserved, candidate) >= 0)) {
        let tail = "-" + as_string(suffix);
        candidate = substr(base, 0, NAME_MAX_BYTES - length(tail)) + tail;
        suffix++;
    }
    return candidate;
}

function safe_name(value) {
    // steer rejects output/device names outside [A-Za-z0-9_.-].
    value = as_string(value);
    let out = "";
    for (let ch in split(value, "")) {
        if (match(ch, /[A-Za-z0-9_.-]/) != null)
            out += ch;
        else
            out += "_";
    }
    if (out == "")
        out = "channel";
    return truncate_name(out);
}

// ============================================================================
// Section classification
// ============================================================================

// A section that carries routing rules (domain/IP lists, client filters).
function is_rule_section(section) {
    let action = as_string(option(section, "action", ""));
    if (action == "connection" || action == "subscription" || action == "provider")
        return true;
    if (action == "bypass" || action == "hosts")
        return true;
    if (action == "direct_bypass" || action == "torrserver_direct")
        return true;
    if (action == "zapret" || action == "zapret2")
        return true;
    return false;
}

function is_proxy_section(section) {
    let action = as_string(option(section, "action", ""));
    return action == "connection" || action == "subscription" || action == "provider";
}

function is_zapret_section(section) {
    let action = as_string(option(section, "action", ""));
    return action == "zapret" || action == "zapret2";
}

// Sections that steer cannot express are skipped here and parked by the switch
// layer, so the generated spec stays valid for the active engine.
function section_supported(section) {
    let action = as_string(option(section, "action", ""));
    if (action == "anytls" || action == "awg" || action == "fptn" ||
        action == "wdtt" || action == "olcrtc" || action == "byedpi")
        return false;
    return true;
}


// ============================================================================
// Channels
// ============================================================================

// Injected by the runtime so the generator stays free of filesystem/network
// dependencies in tests. Signature: (section, catalog) -> { domains, prefixes }.
let materialize_lists = null;

function set_list_materializer(fn) {
    materialize_lists = fn;
}

function channel_match(section, catalog) {
    let match_obj = {};

    // Materialise this section's lists as steer plain-text files. steer cannot
    // read sing-box rule-set JSON, so the conversion happens here rather than
    // pointing the spec at sing-box artefacts.
    let lists = null;
    if (materialize_lists != null)
        lists = materialize_lists(section, catalog);

    let domains = [];
    let prefixes = [];
    if (lists != null) {
        if (as_string(lists.domains) != "")
            push(domains, lists.domains);
        if (as_string(lists.prefixes) != "")
            push(prefixes, lists.prefixes);
    }

    if (length(domains) > 0)
        match_obj.domains_files = domains;
    if (length(prefixes) > 0)
        match_obj.prefixes_files = prefixes;

    let proto = lc(as_string(option(section, "proto", option(section, "protocol", ""))));
    if (proto == "tcp" || proto == "udp")
        match_obj.proto = proto;
    else if (proto == "both" || proto == "all")
        match_obj.proto = "both";

    let ports_val = option(section, "ports", option(section, "destination_ports", null));
    if (ports_val != null && (match_obj.domains_files != null || match_obj.prefixes_files != null)) {
        // steer: ports narrow the match, they are never the match itself — a
        // channel without an address/domain list (or any) is rejected. Ports
        // are strings ("443", "50000-65535"), max 16 entries, no overlaps.
        let ports = [];
        let items = type(ports_val) == "array" ? ports_val : split(as_string(ports_val), /[ \t\r\n,]+/);
        for (let p in items) {
            p = trim(as_string(p));
            if (p != "")
                push(ports, p);
            if (length(ports) >= 16)
                break;
        }
        if (length(ports) > 0)
            match_obj.ports = ports;
    }

    return match_obj;
}

// steer rejects a `from` that mixes addresses and MACs (nft cannot express the
// OR), and scope=device accepts only single hosts: a bare address, an address
// with /32, or a MAC. Subnets, ranges and interface names must not land there.
function is_mac_value(value) {
    return match(as_string(value), /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) != null;
}

function is_single_host_value(value) {
    value = as_string(value);
    if (value == "")
        return false;
    if (is_mac_value(value) || index(value, ":") >= 0)
        return true;
    if (index(value, "-") >= 0)
        return false;
    let slash = index(value, "/");
    if (slash >= 0)
        return substr(value, slash) == "/32";
    return match(value, /^[0-9.]+$/) != null;
}

// Client filters of one section, split the way steer wants them: MACs and
// addresses never share a channel. Interface names are dropped — steer has no
// per-channel interface match (lan_devices covers capture globally).
function channel_clients(section) {
    let macs = [];
    let addrs = [];
    for (let value in list_option(section, "client_addresses")) {
        value = as_string(value);
        if (is_mac_value(value))
            push(macs, value);
        else if (value != "")
            push(addrs, value);
    }
    for (let value in list_option(section, "mac_addresses")) {
        value = as_string(value);
        if (is_mac_value(value) && index(macs, value) < 0)
            push(macs, value);
    }
    let addrs_single = true;
    for (let value in addrs)
        if (!is_single_host_value(value))
            addrs_single = false;
    return { macs, addrs, addrs_single };
}



function serialize_spec(spec) {
    return sprintf("%J\n", spec);
}

// ============================================================================
// Spec v2 (spec.json with a top-level `version: 2`)
// ============================================================================
//
// This is a different document from the contract-v1 output Tachyon used to
// write, not a newer number of the same one: spec v2 is recognised by
// `version: 2`, its sections are lan / clients / lists / outputs / rules / dns,
// and carrying `version` together with `schema` is a rejection. Only steer 2.0
// and newer read it, so engine_runtime refuses to write one for an older kernel.
//
// v1 stays the default until this output is accepted by a real kernel: an
// unknown key is a hard rejection there, so a half-finished migration takes the
// proxy down rather than degrading.

const SPEC_VERSION_V2 = 2;

// steer v2 counts pool nodes in `nodes` (a list); v1 also had a scalar `node`.
//
// The scalar is parsed by hand rather than through int(): int() on a non-numeric
// string does not reliably yield something distinguishable from a number, and
// the difference matters - a node that fails to parse must fall back to "first
// working", never turn into a bogus `nodes` entry.
function parse_node_number(value) {
    let text = trim(as_string(value));
    if (text == "" || match(text, /^[0-9]+$/) == null)
        return null;
    let parsed = int(text, 10);
    if (parsed == null || parsed < 1)
        return null;
    return parsed;
}

function section_auto_selects(section) {
    let node = option(section, "node", null);
    let nodes = list_option(section, "nodes");
    let sort_by_latency = bool_option(section, "sort_by_latency", false);
    let parsed_node = parse_node_number(node);
    let is_valid_num = (parsed_node != null);
    let is_auto = (node == "auto" || node == "urltest" || !is_valid_num ||
        (sort_by_latency && !is_valid_num));
    return { auto: is_auto || length(nodes) > 0, parsed_node, is_valid_num };
}

// Outputs v2, plus the name every rule must point at for that section. The two
// differ wherever a section is auto-selecting: in v1 one output could be both a
// tunnel and self-selecting, while in v2 a group is its own output whose members

// Spec v2 states `interval`, `idle_timeout` and `tolerance` in plain seconds and
// milliseconds. UCI stores sing-box durations ("3m", "1h30m", "500ms"), so they
// have to be converted rather than passed through - "3m" in a spec field that
// wants a number is not a shortened interval, it is a rejected spec.
const DURATION_UNITS = {
    "ms": null,   // sub-second; steer has no use for it, handled below
    "s": 1,
    "m": 60,
    "h": 3600,
    "d": 86400
};

function duration_to_seconds(value) {
    let text = trim(as_string(value));
    if (text == "")
        return null;

    // sing-box allows compound durations like "1h30m". Consume one term at a
    // time from the front; anything left over that is not a term means the
    // value is not a duration we understand, and guessing would put a wrong
    // number into a spec field where it is a rejection.
    let rest = text;
    let total = 0;
    while (length(rest) > 0) {
        let term = match(rest, /^([0-9]+)(ms|s|m|h|d)/);
        if (term == null)
            return null;
        let amount = int(term[1], 10);
        if (amount == null)
            return null;
        if (term[2] == "ms") {
            // Steer's smallest documented interval is 5 s, so a sub-second value
            // has no honest conversion - rounding it to 0 would mean "measure
            // every 5 seconds", which is not what the user asked for.
            return null;
        }
        total += amount * DURATION_UNITS[term[2]];
        rest = substr(rest, length(term[0]));
    }
    return total;
}

// int() does not reliably signal "not a number" - on a non-numeric string it
// yields the string "NaN", which is neither null nor comparable and would be
// written straight into the spec as `"tolerance": "NaN"`. So the digits are
// checked first and anything unrecognised is treated as absent, which lets
// steer apply its own default instead of taking the whole spec down.
function clamp_int(value, low, high) {
    let text = trim(as_string(value));
    if (text == "" || match(text, /^-?[0-9]+$/) == null)
        return null;
    let parsed = int(text, 10);
    if (parsed == null)
        return null;
    if (parsed < low)
        return low;
    if (parsed > high)
        return high;
    return parsed;
}

// The four keys are only legal on `pick: latency`. Emitting any of them on
// another pick is a parse rejection, which takes down the whole spec, so this
// returns them only when the caller is actually building a latency group.
// At most one latency group per section can be expressed in spec v2, so more
// than one urltest child is configuration this engine cannot honour. Silently
// taking the first would apply settings the user did not pick and drop the rest
// without a word, which is the failure this generator is supposed to avoid -
// so nothing is applied and the section is named.
function urltest_group_settings(section) {
    let list = list_option(section, "steer_urltest_settings");
    let found = null;
    let count = 0;
    for (let entry in list)
        if (type(entry) == "object") {
            count++;
            if (found == null)
                found = entry;
        }
    if (count > 1) {
        warn("steer: section " + as_string(option(section, ".name", "?")) + " has " +
            as_string(count) + " URLTest groups; spec v2 can express only one per section, " +
            "so none of them is applied\n");
        return null;
    }
    return found;
}

function latency_group_keys(section) {
    let keys = {};
    let settings = urltest_group_settings(section);
    if (settings == null)
        return keys;

    let url = trim(as_string(option(settings, "testing_url", "")));
    // ucode has no \s inside a character class - it means a literal backslash and
    // an "s" - so the spaces are listed out. Only http(s) is a check address
    // steer accepts; anything else is left out rather than written.
    if (url != "" && match(url, /^https?:\/\/[^/ \t]+/) != null)
        keys.url = url;

    let tolerance = clamp_int(option(settings, "tolerance", ""), 0, 60000);
    if (tolerance != null)
        keys.tolerance = tolerance;

    let interval = clamp_int(duration_to_seconds(option(settings, "check_interval", "")), 5, 86400);
    if (interval != null)
        keys.interval = interval;

    // idle_timeout 0 means "always measure" and is steer's router default, so an
    // absent or unparseable value is left out rather than guessed at.
    let idle = clamp_int(duration_to_seconds(option(settings, "idle_timeout", "")), 0, 86400);
    if (idle != null)
        keys.idle_timeout = idle;

    return keys;
}

// are other outputs, so the rule has to target the group rather than the tunnel.
function build_outputs_v2(sections, settings) {
    let outputs = { direct: { kind: "direct" } };
    let targets = {};
    let unsupported = [];

    for (let section in sections) {
        if (!is_enabled(section) || !section_supported(section))
            continue;
        if (!is_proxy_section(section))
            continue;

        let name = safe_name(option(section, "label", option(section, ".name", "proxy")));
        let on_fail = as_string(option(section, "on_fail", DEFAULT_ON_FAIL));

        // v1 took a list of devices; v2 takes exactly one, so several become a
        // group over per-device outputs. This adds a node to the output graph.
        let device = as_string(option(section, "outbound_interface", ""));
        let devices = list_option(section, "outbound_interfaces");
        if (device != "" && length(devices) == 0)
            devices = [ device ];
        if (length(devices) > 0) {
            if (length(devices) == 1) {
                outputs[name] = { kind: "interface", device: devices[0], on_fail };
            }
            else {
                let members = [];
                for (let index_value, dev in devices) {
                    let member_name = safe_name(name + "-" + (index_value + 1));
                    outputs[member_name] = {
                        kind: "interface",
                        device: dev,
                        on_fail: "direct"
                    };
                    push(members, member_name);
                }
                outputs[name] = {
                    kind: "group",
                    pick: "order",
                    members,
                    on_fail
                };
            }
            targets[name] = name;
            let sec_name = safe_name(section[".name"]);
            if (sec_name != "" && sec_name != name && outputs[sec_name] == null)
                targets[sec_name] = name;
            continue;
        }

        let sub_file = as_string(option(section, "steer_sub_file", ""));
        if (sub_file != "" && steer_vless_supported) {
            // v1 wrote `kind: vless` + `sub_file` + `prefer` into one object. v2
            // splits them: the tunnel keeps the subscription, and auto-selection
            // becomes a separate group output that references it.
            let tunnel = {
                kind: "tunnel",
                protocol: "vless",
                subscription: sub_file,
                on_fail
            };
            let select = section_auto_selects(section);

            // Nodes apply whether the section is pinned or auto-selecting: a
            // pinned node is the difference between "use node 2" and "use the
            // first working one", so dropping it here would silently change
            // which server carries the traffic.
            let explicit = list_option(section, "nodes");
            if (length(explicit) > 0) {
                let unique_nodes = [];
                for (let item in explicit) {
                    let parsed = parse_node_number(item);
                    if (parsed != null && index(unique_nodes, parsed) < 0)
                        push(unique_nodes, parsed);
                }
                if (length(unique_nodes) > 16)
                    unique_nodes = slice(unique_nodes, 0, 16);
                if (length(unique_nodes) > 0)
                    tunnel.nodes = unique_nodes;
            }
            else if (select.is_valid_num) {
                tunnel.nodes = [ select.parsed_node ];
            }

            if (select.auto) {
                outputs[name + "-tun"] = tunnel;
                let group = {
                    kind: "group",
                    pick: "latency",
                    members: [ name + "-tun" ],
                    on_fail
                };
                // Only ever on a latency group: these keys are a parse rejection
                // on any other pick.
                let keys = latency_group_keys(section);
                for (let key in keys)
                    group[key] = keys[key];
                outputs[name] = group;
            }
            else {
                outputs[name] = tunnel;
            }
            targets[name] = name;
            let sec_name = safe_name(section[".name"]);
            if (sec_name != "" && sec_name != name && outputs[sec_name] == null)
                targets[sec_name] = name;
            continue;
        }

        // Nothing steer can point at: park via a direct output placeholder.
        outputs[name] = { kind: "direct" };
        targets[name] = name;
        let sec_name = safe_name(section[".name"]);
        if (sec_name != "" && sec_name != name && outputs[sec_name] == null)
            targets[sec_name] = name;
    }

    // Zapret sections become kind: zapret outputs; steer runs nfqws itself.
    for (let section in sections) {
        if (!is_enabled(section) || !is_zapret_section(section))
            continue;
        let name = safe_name(option(section, "label", option(section, ".name", "zapret")));
        let strategy = as_string(option(section, "steer_opts_file", ""));
        if (strategy == "")
            strategy = engine.STEER_ZAPRET_DIR + "/" + name + ".opts";
        let action = as_string(option(section, "action", ""));
        let out_entry = {
            kind: "zapret",
            on_fail: "direct",
            strategy
        };
        // v1 also stored `nfqws_bin`, the resolved nfqws2 path so steer would
        // launch the Lua-capable binary. Spec v2 has no such key and an unknown
        // key is a rejection, so it is not written at all. zapret2 Lua strategies
        // are the casualty; engine_state has to park them on steer rather than
        // let them look configured.
        if (action == "zapret2")
            push(unsupported, name + " (zapret2 Lua strategy: no v2 nfqws_bin key)");
        outputs[name] = out_entry;
        targets[name] = name;
    }

    return { outputs, targets, unsupported };
}

// v1 inlined the list files into the channel (`match.domains_files`). v2 has no
// such key: a named `lists` section carries them and rules reference it by name
// through `to`. Names must be synthesized and unique.
// Spec v2 `rules.for` is a list of *names* from the top-level `clients`
// section, not a list of addresses. v1 inlined raw addresses and MACs straight
// into the channel, so this is a real migration step and not a rename: emitting
// the addresses where names belong is a dangling reference and rejects the whole
// spec. `addr` and `mac` cannot share one client (nft has no "or" inside a rule),
// so a section carrying both gets two clients and two rules.
function build_clients_v2(sections) {
    let clients = {};
    let refs = {};

    for (let section in sections) {
        if (!is_enabled(section) || !is_rule_section(section) || !section_supported(section))
            continue;

        let picked = channel_clients(section);
        let addrs = picked.addrs || [];
        let macs = picked.macs || [];
        if (length(addrs) == 0 && length(macs) == 0)
            continue;

        let base = safe_name(option(section, ".name", "client"));
        let names = [];

        if (length(addrs) > 0) {
            let client_name = unique_name(clients, base, [ "lan" ]);
            clients[client_name] = { addr: addrs };
            push(names, client_name);
        }
        if (length(macs) > 0) {
            let client_name = unique_name(clients, base + "-mac", [ "lan" ]);
            clients[client_name] = { mac: macs };
            push(names, client_name);
        }
        refs[as_string(section[".name"])] = names;
    }

    return { clients, refs };
}
function build_lists_v2(sections, catalog) {
    let lists = {};
    let refs = {};

    for (let section in sections) {
        if (!is_enabled(section) || !is_rule_section(section) || !section_supported(section))
            continue;

        let match_obj = channel_match(section, catalog);
        let domains = match_obj.domains_files || [];
        let prefixes = match_obj.prefixes_files || [];
        if (length(domains) == 0 && length(prefixes) == 0)
            continue;

        let base = safe_name(option(section, ".name", "list"));
        let list_name = unique_name(lists, base, [ "all" ]);

        let entry = {};
        if (length(domains) > 0)
            entry.domains_file = domains;
        if (length(prefixes) > 0)
            entry.prefixes_file = prefixes;
        if (match_obj.proto != null)
            entry.proto = match_obj.proto;
        if (match_obj.ports != null)
            entry.ports = match_obj.ports;
        lists[list_name] = entry;
        refs[as_string(section[".name"])] = list_name;
    }

    return { lists, refs };
}

function build_rules_v2(sections, catalog, outputs, targets, client_refs, list_refs) {
    let rules = [];

    for (let section in sections) {
        if (!is_enabled(section) || !is_rule_section(section) || !section_supported(section))
            continue;

        let match_obj = channel_match(section, catalog);
        let clients = channel_clients(section);
        let sec_key = as_string(section[".name"]);
        let domains = match_obj.domains_files || [];
        let prefixes = match_obj.prefixes_files || [];
        let has_files = length(domains) > 0 || length(prefixes) > 0;
        let has_clients = length(clients.macs) > 0 || length(clients.addrs) > 0;
        if (!has_files && !has_clients)
            continue;

        let action = as_string(option(section, "action", ""));
        let out_name = safe_name(option(section, "outbound", option(section, "label", option(section, ".name", "rule"))));
        if (action == "bypass" || action == "hosts" || action == "direct_bypass" || action == "torrserver_direct")
            out_name = "direct";
        else if (action == "zapret" || action == "zapret2") {
            let z_name = safe_name(option(section, "label", option(section, ".name", "zapret")));
            if (outputs && outputs[z_name])
                out_name = z_name;
            else if (targets && targets[z_name])
                out_name = targets[z_name];
            else
                out_name = "direct";
        }
        else if (outputs) {
            if (!outputs[out_name]) {
                let candidates = [
                    targets ? targets[safe_name(section[".name"])] : null,
                    targets ? targets[safe_name(option(section, "label", ""))] : null,
                    targets ? targets[safe_name(option(section, "outbound", ""))] : null
                ];
                out_name = "direct";
                for (let candidate in candidates)
                    if (candidate != null && outputs[candidate]) {
                        out_name = candidate;
                        break;
                    }
            }
        }

        let label = safe_name(option(section, "label", option(section, ".name", "rule")));
        let list_name = list_refs ? list_refs[sec_key] : null;
        let my_clients = (client_refs && client_refs[sec_key]) || [];

        // One rule per client: v2 rules take `for` as a list of client names,
        // and a rule that mixes an address client with a MAC client cannot be
        // compiled (nft has no "or" within a rule).
        // A section with only list files and no clients still needs a rule: a v2 rule
        // without `for` is the default clients, so it must be emitted without the
        // key rather than skipped.
        let emit = my_clients;
        if (length(emit) == 0)
            emit = [ null ];

        for (let slot, client_name in emit) {
            let rule = { name: (length(my_clients) > 1
                    ? truncate_name(label + "-" + as_string(slot + 1))
                    : label),
                out: out_name };
            if (list_name != null)
                rule.to = [ list_name ];
            else
                rule.to = [ "all" ];
            if (client_name != null)
                rule.for = [ client_name ];
            if (client_name != null && clients.addrs_single)
                rule.scope = "device";
            // v1 carried the resolver choice on the channel; v2 keeps it per
            // rule, and losing it would silently change DNS behaviour.
            if (as_string(option(section, "mode", "")) == "realip")
                rule.resolve = "realip";
            push(rules, rule);
        }
    }

    return rules;
}

function build_spec_v2(sections, settings, catalog) {
    settings = settings || {};

    steer_vless_supported = (steer_vless_override != null)
        ? steer_vless_override
        : true;
    if (steer_vless_override == null) {
        try {
            let engine_mod = require("engine");
            if (engine_mod && type(engine_mod.steer_has_extended_build) == "function")
                steer_vless_supported = engine_mod.steer_has_extended_build();
        }
        catch (e) {
        }
    }

    let built = build_outputs_v2(sections, settings);
    if (!steer_vless_supported && built != null) {
        let dropped = [];
        for (let name in built.outputs)
            if (type(built.outputs[name]) == "object" &&
                built.outputs[name].kind == "tunnel")
                delete built.outputs[name];
        for (let name in built.targets) {
            if (built.targets[name] == name && built.outputs[name] == null)
                push(dropped, name);
            built.targets[name] = "direct";
        }
        if (length(dropped) > 0)
            warn("steer: installed build has no vless client, sections left without a tunnelled output: " +
                join(", ", dropped) + ". Install the steer-extended package to route them through a proxy.\n");
    }
    for (let note in built.unsupported)
        warn("steer: " + note + "\n");

    let lan_devices = list_option(settings, "source_network_interfaces");
    if (length(lan_devices) == 0)
        lan_devices = DEFAULT_LAN_DEVICES;

    let built_clients = build_clients_v2(sections);
    let built_lists = build_lists_v2(sections, catalog);

    return {
        version: SPEC_VERSION_V2,
        lan: { devices: lan_devices },
        clients: built_clients.clients,
        lists: built_lists.lists,
        outputs: built.outputs,
        rules: build_rules_v2(sections, catalog, built.outputs, built.targets,
            built_clients.refs, built_lists.refs),
        dns: {
            mode: bool_option(settings, "dns_redirect", true) ? "fakeip" : "realip"
        }
    };
}

// ============================================================================
// Module exports
// ============================================================================

function module_exports() {
    return {
        safe_name,
        is_rule_section,
        is_proxy_section,
        is_zapret_section,
        section_supported,
        build_spec_v2,
        SPEC_VERSION_V2,
        set_vless_supported,
        serialize_spec,
        set_list_materializer
    };
}

return module_exports();
