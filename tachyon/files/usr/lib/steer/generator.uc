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

const SPEC_SCHEMA = 2;
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
    return out;
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
// Outputs
// ============================================================================

// Resolved through the zapret2 provider's candidate list (fs.stat fallbacks),
// never hardcoded: the nfqws2 binary lands at different paths per build
// (/opt/zapret2/nfq2/nfqws2, /opt/zapret2/nfqws2, /usr/bin/nfqws2, ...).
function resolved_zapret_bin(is_z2) {
    try {
        let provider = require(is_z2 ? "providers.zapret2.common" : "providers.zapret.common").config({});
        if (provider != null && as_string(provider.binary) != "")
            return as_string(provider.binary);
    }
    catch (e) {}
    return is_z2 ? "/opt/zapret2/nfq2/nfqws2" : "/opt/zapret/nfq/nfqws";
}

// Build the outputs map. Proxy sections become interface/vless outputs when the
// device or subscription is known; everything else falls back to a direct
// output so channels referencing it still compile.
function build_outputs(sections, settings) {
    let outputs = {
        direct: { kind: "direct" }
    };

    for (let section in sections) {
        if (!is_enabled(section) || !section_supported(section))
            continue;
        if (!is_proxy_section(section))
            continue;

        let name = safe_name(option(section, "label", option(section, ".name", "proxy")));
        let device = as_string(option(section, "outbound_interface", ""));
        let devices = list_option(section, "outbound_interfaces");
        let on_fail = as_string(option(section, "on_fail", DEFAULT_ON_FAIL));
        if (device != "" && length(devices) == 0)
            devices = [ device ];
        if (length(devices) > 0) {
            outputs[name] = {
                kind: "interface",
                devices,
                on_fail
            };
            continue;
        }

        // A section with a subscription can be driven through steer's own
        // vless client; the file is written by Tachyon's subscription updater.
        let sub_file = as_string(option(section, "steer_sub_file", ""));
        if (sub_file != "") {
            outputs[name] = {
                kind: "vless",
                sub_file,
                on_fail
            };
            let node = option(section, "node", null);
            let nodes = list_option(section, "nodes");
            let sort_by_latency = bool_option(section, "sort_by_latency", false);
            let parsed_node = (node != null && node != "") ? int(node) : null;
            let is_valid_num = (parsed_node != null && parsed_node != "NaN");
            let is_auto = (node == "auto" || node == "urltest" || !is_valid_num || (sort_by_latency && !is_valid_num));
            if (is_auto || length(nodes) > 0) {
                outputs[name].prefer = "latency";
                outputs[name].latency_interval_s = 300;
                outputs[name].latency_tolerance_ms = 50;

                let lat_file = getenv("TACHYON_STEER_LATENCY_CACHE_FILE") || "/var/run/tachyon/steer-latencies.json";
                let lat_data = {};
                let lat_raw = fs.readfile(lat_file);
                if (lat_raw != null) {
                    let parsed_lat = json(lat_raw);
                    if (type(parsed_lat) == "object")
                        lat_data = parsed_lat;
                }

                let sec_cache_dir = getenv("TACHYON_SECTION_CACHE_DIR") || "/var/run/tachyon/section-cache";
                let sec_cache_raw = fs.readfile(sec_cache_dir + "/" + name + ".json");
                let sec_cache = sec_cache_raw ? json(sec_cache_raw) : null;

                let candidate_pool = [];
                let sel_path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
                let sel_raw = fs.readfile(sel_path);
                let sel_data = (sel_raw != null) ? json(sel_raw) : {};
                let active_sel = type(sel_data) == "object" ? (sel_data[name] || sel_data[name + "-out"]) : null;

                if (sec_cache && type(sec_cache.links) == "object") {
                    let tag_to_idx = {};
                    let vless_idx = 0;
                    let ordered_tags = [];
                    if (type(sec_cache.urltestGroups) == "object") {
                        for (let grp_id, grp in sec_cache.urltestGroups) {
                            if (type(grp) == "object" && type(grp.outbounds) == "array") {
                                for (let ob in grp.outbounds) {
                                    let link = sec_cache.links[ob];
                                    if (link != null && match(trim(as_string(link)), /^vless:\/\//) != null && index(ordered_tags, ob) < 0)
                                        push(ordered_tags, ob);
                                }
                            }
                        }
                    }
                    let hidden_ordered = type(sec_cache.hiddenOutboundTags) == "object" ? sec_cache.hiddenOutboundTags : {};
                    for (let tname, link in sec_cache.links) {
                        if (index(ordered_tags, tname) >= 0 || hidden_ordered[tname]) continue;
                        link = trim(as_string(link));
                        if (match(link, /^vless:\/\//) != null)
                            push(ordered_tags, tname);
                    }
                    for (let tname, link in sec_cache.links) {
                        if (index(ordered_tags, tname) >= 0) continue;
                        link = trim(as_string(link));
                        if (match(link, /^vless:\/\//) != null)
                            push(ordered_tags, tname);
                    }
                    for (let tname in ordered_tags) {
                        tag_to_idx[tname] = vless_idx;
                        vless_idx++;
                    }

                    let target_grp = null;
                    if (active_sel != null && type(sec_cache.urltestGroups) == "object") {
                        target_grp = sec_cache.urltestGroups[active_sel];
                        if (!target_grp) {
                            for (let gid, gdata in sec_cache.urltestGroups) {
                                if (gid == active_sel || gdata.displayName == active_sel) {
                                    target_grp = gdata;
                                    break;
                                }
                            }
                        }
                    }

                    if (target_grp && type(target_grp.outbounds) == "array" && length(target_grp.outbounds) > 0) {
                        for (let ob in target_grp.outbounds) {
                            if (tag_to_idx[ob] != null)
                                push(candidate_pool, tag_to_idx[ob]);
                        }
                    }
                }

                if (length(candidate_pool) == 0 && length(nodes) > 0) {
                    for (let n in nodes) {
                        let ni = int(n);
                        if (ni != null && ni != "NaN")
                            push(candidate_pool, ni);
                    }
                }

                if (length(candidate_pool) == 0 && is_auto) {
                    let sub_raw = fs.readfile(sub_file);
                    if (sub_raw != null) {
                        let lines = split(trim(sub_raw), "\n");
                        for (let i = 0; i < length(lines); i++) {
                            if (trim(lines[i]) != "")
                                push(candidate_pool, i);
                        }
                    } else {
                        for (let i = 0; i < 16; i++)
                            push(candidate_pool, i);
                    }
                }

                let sorted_pool = sort(candidate_pool, function(a, b) {
                    let da = lat_data["proxy-" + a];
                    let db = lat_data["proxy-" + b];
                    let sa = (da != null && int(da) > 0) ? int(da) : (da == null ? 5000000 + a : 9000000 + a);
                    let sb = (db != null && int(db) > 0) ? int(db) : (db == null ? 5000000 + b : 9000000 + b);
                    return sa - sb;
                });

                let unique_nodes = [];
                let seen = {};
                for (let ni in sorted_pool) {
                    if (!seen[ni]) {
                        push(unique_nodes, ni);
                        seen[ni] = true;
                    }
                }
                if (length(unique_nodes) > 16)
                    unique_nodes = slice(unique_nodes, 0, 16);
                if (length(unique_nodes) > 0)
                    outputs[name].nodes = unique_nodes;
            } else if (is_valid_num) {
                outputs[name].node = parsed_node;
            }

            let sec_name = safe_name(section[".name"]);
            if (sec_name != "" && sec_name != name && !outputs[sec_name])
                outputs[sec_name] = outputs[name];
            continue;
        }

        // Nothing steer can point at: park via a direct output placeholder.
        outputs[name] = { kind: "direct" };
        let sec_name = safe_name(section[".name"]);
        if (sec_name != "" && sec_name != name && !outputs[sec_name])
            outputs[sec_name] = outputs[name];
        continue;
    }

    // Zapret sections become kind: zapret outputs; steer runs nfqws itself.
    for (let section in sections) {
        if (!is_enabled(section) || !is_zapret_section(section))
            continue;
        let action = as_string(option(section, "action", ""));
        let name = safe_name(option(section, "label", option(section, ".name", "zapret")));
        let sec_name = safe_name(section[".name"]);
        let opts_file = as_string(option(section, "steer_opts_file", ""));
        if (opts_file == "")
            opts_file = engine.STEER_ZAPRET_DIR + "/" + name + ".opts";
        let out_entry = {
            kind: "zapret",
            on_fail: "direct",
            opts_file: opts_file
        };
        // zapret2 uses nfqws2 (supports Lua strategies); store the resolved
        // binary path in the spec so steer-nfqws picks the right executable.
        out_entry.nfqws_bin = resolved_zapret_bin(action == "zapret2");
        outputs[name] = out_entry;
        if (sec_name != "" && sec_name != name && !outputs[sec_name])
            outputs[sec_name] = out_entry;
    }

    return outputs;
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

function build_channels(sections, catalog, outputs) {
    let channels = [];

    for (let section in sections) {
        if (!is_enabled(section) || !is_rule_section(section) || !section_supported(section))
            continue;

        let match_obj = channel_match(section, catalog);
        let clients = channel_clients(section);
        let has_files = (match_obj.domains_files != null && length(match_obj.domains_files) > 0) ||
                        (match_obj.prefixes_files != null && length(match_obj.prefixes_files) > 0);
        let has_clients = length(clients.macs) > 0 || length(clients.addrs) > 0;
        if (!has_files && !has_clients)
            continue;

        let action = as_string(option(section, "action", ""));
        let out_name = safe_name(option(section, "outbound", option(section, "label", option(section, ".name", "channel"))));
        if (action == "bypass" || action == "hosts" || action == "direct_bypass" || action == "torrserver_direct")
            out_name = "direct";
        else if (action == "zapret" || action == "zapret2") {
            let z_name = safe_name(option(section, "label", option(section, ".name", "zapret")));
            let z_sec = safe_name(section[".name"]);
            if (outputs && outputs[z_name])
                out_name = z_name;
            else if (outputs && outputs[z_sec])
                out_name = z_sec;
            else
                out_name = "direct";
        } else if (outputs) {
            if (!outputs[out_name]) {
                let sec_fallback = safe_name(section[".name"]);
                let lbl_fallback = safe_name(option(section, "label", ""));
                let ob_fallback = safe_name(option(section, "outbound", ""));
                if (outputs[sec_fallback])
                    out_name = sec_fallback;
                else if (outputs[lbl_fallback])
                    out_name = lbl_fallback;
                else if (outputs[ob_fallback])
                    out_name = ob_fallback;
                else
                    out_name = "direct";
            }
        }

        let label = as_string(option(section, "label", option(section, ".name", "channel")));

        // zapret/zapret2 channels use the default fakeip mode.
        // steer 1.5.7+ deprecated mode=realip; fakeip now correctly routes
        // DPI-bypass traffic through nftables marks without needing realip.

        // Addresses: one channel. scope=device (priority over global rules) only
        // when every entry is a single host — steer rejects subnets there.
        if (length(clients.addrs) > 0 || length(keys(match_obj)) > 0) {
            let channel = {
                name: label,
                match: match_obj,
                out: out_name
            };
            if (length(clients.addrs) > 0) {
                channel.from = clients.addrs;
                if (clients.addrs_single)
                    channel.scope = "device";
            }
            push(channels, channel);
        }

        // MACs: steer forbids mixing them with addresses in one `from`, so they
        // go into a separate channel ("заведите два канала" — contract).
        if (length(clients.macs) > 0) {
            let mac_channel = {
                name: label + " (MAC)",
                match: match_obj,
                from: clients.macs,
                scope: "device",
                out: out_name
            };
            push(channels, mac_channel);
        }
    }

    return channels;
}

// ============================================================================
// Spec assembly
// ============================================================================

function build_spec(sections, settings, catalog) {
    settings = settings || {};
    let lan_devices = list_option(settings, "source_network_interfaces");
    if (length(lan_devices) == 0)
        lan_devices = DEFAULT_LAN_DEVICES;

    let outputs = build_outputs(sections, settings);
    return {
        schema: SPEC_SCHEMA,
        dns_redirect: bool_option(settings, "dns_redirect", true),
        lan_devices,
        outputs,
        channels: build_channels(sections, catalog, outputs)
    };
}

function serialize_spec(spec) {
    return sprintf("%J\n", spec);
}

// ============================================================================
// Module exports
// ============================================================================

function module_exports() {
    return {
        SPEC_SCHEMA,
        safe_name,
        is_rule_section,
        is_proxy_section,
        is_zapret_section,
        section_supported,
        build_outputs,
        build_channels,
        build_spec,
        serialize_spec,
        set_list_materializer
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/generator.uc (library module, no CLI)\n");
exit(1);
