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

let common = require("core.common");
let engine = require("core.engine");

let as_string = common.as_string;

const SPEC_SCHEMA = 1;
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
        if (device != "" && length(devices) == 0)
            devices = [ device ];
        if (length(devices) > 0) {
            outputs[name] = {
                kind: "interface",
                devices,
                on_fail: DEFAULT_ON_FAIL
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
                on_fail: DEFAULT_ON_FAIL
            };
            continue;
        }

        // Nothing steer can point at: park via a direct output placeholder.
        outputs[name] = { kind: "direct" };
    }

    // Zapret sections become kind: zapret outputs; steer runs nfqws itself.
    for (let section in sections) {
        if (!is_enabled(section) || !is_zapret_section(section))
            continue;
        let name = safe_name(option(section, "label", option(section, ".name", "zapret")));
        let opts_file = as_string(option(section, "steer_opts_file", ""));
        outputs[name] = {
            kind: "zapret",
            on_fail: "direct"
        };
        if (opts_file != "")
            outputs[name].opts_file = opts_file;
    }

    return outputs;
}

// ============================================================================
// Channels
// ============================================================================

function channel_match(section) {
    let match_obj = {};

    let domains = [];
    for (let value in list_option(section, "domain"))
        push(domains, value);
    for (let value in list_option(section, "remote_domain_lists"))
        push(domains, value);
    if (length(domains) > 0)
        match_obj.domains_files = domains;

    let prefixes = [];
    for (let value in list_option(section, "subnet"))
        push(prefixes, value);
    for (let value in list_option(section, "remote_subnet_lists"))
        push(prefixes, value);
    if (length(prefixes) > 0)
        match_obj.prefixes_files = prefixes;

    return match_obj;
}

function channel_from(section) {
    let from = [];
    for (let value in list_option(section, "source_network_interfaces"))
        push(from, value);
    for (let value in list_option(section, "client_addresses"))
        push(from, value);
    for (let value in list_option(section, "mac_addresses"))
        push(from, value);
    return from;
}

function build_channels(sections) {
    let channels = [];

    for (let section in sections) {
        if (!is_enabled(section) || !is_rule_section(section) || !section_supported(section))
            continue;

        let match_obj = channel_match(section);
        if (length(keys(match_obj)) == 0)
            continue;

        let action = as_string(option(section, "action", ""));
        let out_name = safe_name(option(section, "label", option(section, ".name", "channel")));
        if (action == "bypass" || action == "hosts" || action == "direct_bypass" || action == "torrserver_direct")
            out_name = "direct";

        let channel = {
            name: as_string(option(section, "label", option(section, ".name", "channel"))),
            match: match_obj,
            out: out_name
        };

        let from = channel_from(section);
        if (length(from) > 0)
            channel.from = from;

        push(channels, channel);
    }

    return channels;
}

// ============================================================================
// Spec assembly
// ============================================================================

function build_spec(sections, settings) {
    settings = settings || {};
    let lan_devices = list_option(settings, "source_network_interfaces");
    if (length(lan_devices) == 0)
        lan_devices = DEFAULT_LAN_DEVICES;

    return {
        schema: SPEC_SCHEMA,
        lan_devices,
        outputs: build_outputs(sections, settings),
        channels: build_channels(sections)
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
        serialize_spec
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/generator.uc (library module, no CLI)\n");
exit(1);
