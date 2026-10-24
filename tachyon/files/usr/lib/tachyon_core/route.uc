#!/usr/bin/env ucode

let common = require("core.common");
let connections = require("config.connections");
let runtime_constants = require("tachyon_core.constants");

let option = common.option;
let bool_option = common.bool_option;
let as_string = common.as_string;
let bool_value = common.bool_value;
let disable_quic_mode = common.disable_quic_mode;

function normalize_port_entry(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return null;
    let number = int(value);
    return number >= 1 && number <= 65535 ? number : null;
}

function bittorrent_policy_mode(settings) {
    let raw = lc(trim(option(settings, "bittorrent_policy", "")));
    if (raw == "direct" || raw == "block" || raw == "off")
        return raw;
    if (bool_option(settings, "isolate_p2p", false))
        return "direct";
    return "off";
}

function p2p_port_rule_verdict(policy_mode) {
    if (as_string(policy_mode) == "block")
        return { action: "reject" };
    return {
        action: "route",
        outbound: runtime_constants.DIRECT_OUTBOUND_TAG
    };
}

// P2P leak protection can be pinned down to the torrent client's own ports so
// nothing sneaks past the protocol sniffer. Each entry is:
// "port", "port-port", "proto", "proto:port" or "proto:port-port" (tcp/udp, comma separated).
// Without a port the whole protocol is routed direct (or rejected when policy_mode == "block").
function p2p_direct_rules(settings, policy_mode) {
    let rules = [];
    let verdict = p2p_port_rule_verdict(policy_mode || "direct");
    for (let entry in split(option(settings, "p2p_ports", ""), ",")) {
        entry = trim(entry);
        if (entry == "")
            continue;
        let proto = "both";
        let port_spec = "";
        let colon = index(entry, ":");
        if (colon >= 0) {
            let p = lc(trim(substr(entry, 0, colon)));
            if (p == "tcp" || p == "udp") {
                proto = p;
                port_spec = trim(substr(entry, colon + 1));
            } else {
                continue;
            }
        } else {
            let p = lc(entry);
            if (p == "tcp" || p == "udp") {
                proto = p;
                port_spec = "";
            } else {
                proto = "both";
                port_spec = entry;
            }
        }

        let networks = proto == "both" ? [ "tcp", "udp" ] : [ proto ];

        if (port_spec != "") {
            let dash = index(port_spec, "-");
            if (dash >= 0) {
                let start = normalize_port_entry(substr(port_spec, 0, dash));
                let end = normalize_port_entry(substr(port_spec, dash + 1));
                if (start != null && end != null && start <= end) {
                    let range_str = sprintf("%d:%d", start, end);
                    let src_rule = {
                        network: networks,
                        source_port_range: [ range_str ],
                        action: verdict.action
                    };
                    if (verdict.outbound != null)
                        src_rule.outbound = verdict.outbound;
                    push(rules, src_rule);
                    let dst_rule = {
                        network: networks,
                        port_range: [ range_str ],
                        action: verdict.action
                    };
                    if (verdict.outbound != null)
                        dst_rule.outbound = verdict.outbound;
                    push(rules, dst_rule);
                }
            } else {
                let port = normalize_port_entry(port_spec);
                if (port != null) {
                    let src_rule = {
                        network: networks,
                        source_port: port,
                        action: verdict.action
                    };
                    if (verdict.outbound != null)
                        src_rule.outbound = verdict.outbound;
                    push(rules, src_rule);
                    let dst_rule = {
                        network: networks,
                        port: [ port ],
                        action: verdict.action
                    };
                    if (verdict.outbound != null)
                        dst_rule.outbound = verdict.outbound;
                    push(rules, dst_rule);
                }
            }
        } else {
            let net_rule = {
                network: networks,
                action: verdict.action
            };
            if (verdict.outbound != null)
                net_rule.outbound = verdict.outbound;
            push(rules, net_rule);
        }
    }
    return rules;
}

function config(settings, runtime) {
    let output_network_interface = option(settings, "output_network_interface", "");
    let mwan3_active = type(runtime) == "object" && bool_value(runtime.mwan3_active);
    let sniff_inbounds = [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.DNS_INBOUND_TAG ];
    if (common.ipv6_supported())
        push(sniff_inbounds, runtime_constants.TPROXY_INBOUND6_TAG);
    if (type(runtime) == "object" && bool_value(runtime.source_aware_dns))
        push(sniff_inbounds, runtime_constants.SOURCE_DNS_INBOUND_TAG);
    if (type(runtime) == "object" && type(runtime.dns_health_inbounds) == "array")
        for (let inbound in runtime.dns_health_inbounds)
            push(sniff_inbounds, inbound);
    let dns_hijack_inbounds = [ runtime_constants.DNS_INBOUND_TAG ];
    if (type(runtime) == "object" && bool_value(runtime.source_aware_dns))
        push(dns_hijack_inbounds, runtime_constants.SOURCE_DNS_INBOUND_TAG);
    if (type(runtime) == "object" && type(runtime.dns_health_inbounds) == "array")
        for (let inbound in runtime.dns_health_inbounds)
            push(dns_hijack_inbounds, inbound);
    if (bool_option(settings, "route_router_traffic", false) && option(settings, "route_router_traffic_section", "") != "")
        push(sniff_inbounds, runtime_constants.REDIRECT_INBOUND_TAG);
    let rules = [
        { action: "sniff", inbound: sniff_inbounds },
        { action: "hijack-dns", inbound: dns_hijack_inbounds }
    ];
    let result = {
        rules,
        rule_set: [],
        final: runtime_constants.DIRECT_OUTBOUND_TAG,
        auto_detect_interface: output_network_interface == "" && !mwan3_active,
        default_domain_resolver: type(runtime) == "object" && as_string(runtime.default_domain_resolver) != ""
            ? as_string(runtime.default_domain_resolver)
            : runtime_constants.DNS_SERVER_TAG,
        default_mark: runtime_constants.OUTBOUND_MARK
    };

    if (output_network_interface != "")
        result.default_interface = output_network_interface;
    if (disable_quic_mode(option(settings, "disable_quic", "0")) != "off") {
        push(result.rules, { action: "reject", network: "udp", port: [ 443 ] });
        push(result.rules, { action: "reject", protocol: "quic" });
    }
    if (bool_option(settings, "wifi_calling_direct", false)) {
        push(result.rules, {
            network: "udp",
            port: [ 500, 4500 ],
            action: "route",
            outbound: runtime_constants.DIRECT_OUTBOUND_TAG
        });
    }
    let bt_mode = bittorrent_policy_mode(settings);
    if (bt_mode == "direct") {
        push(result.rules, { protocol: "bittorrent", action: "route", outbound: runtime_constants.DIRECT_OUTBOUND_TAG });
        for (let rule in p2p_direct_rules(settings, "direct"))
            push(result.rules, rule);
    } else if (bt_mode == "block") {
        push(result.rules, { protocol: "bittorrent", action: "reject" });
        for (let rule in p2p_direct_rules(settings, "block"))
            push(result.rules, rule);
    }
    if (bool_option(settings, "block_doh", false)) {
        if (option(settings, "dns_type", "udp") == "doh")
            warn("block_doh is enabled but upstream DNS type is 'doh'; your own DNS queries would be blocked, switch dns_type to 'udp' or 'dot'\n");
        let doh_cidrs = [];
        for (let cidr in runtime_constants.DOH_BLOCK_IPV4_CIDRS)
            push(doh_cidrs, cidr);
        for (let cidr in runtime_constants.DOH_BLOCK_IPV6_CIDRS)
            push(doh_cidrs, cidr);
        push(result.rules, { action: "reject", inbound: runtime_constants.TPROXY_INBOUND_TAG, ip_cidr: doh_cidrs });
        push(result.rules, { action: "reject", inbound: runtime_constants.TPROXY_INBOUND6_TAG, ip_cidr: doh_cidrs });
    }

    return result;
}

function target(section, outbound_tag_name) {
    let action = option(section, "action", "");
    if (connections.is_connections_action(action) ||
        action == "awg" || action == "warp" ||
        action == "anytls" || action == "snell" || action == "mieru" || action == "naive" || 
        action == "masque" || action == "openvpn" || action == "openconnect" ||
        action == "tewfai" || action == "trusttunnel" || action == "mtproto" || action == "shadowtls" ||
        action == "desync" || action == "chain" || action == "tailscale" ||
        action == "byedpi" || action == "zapret" || action == "zapret2" ||
        action == "wdtt" || action == "olcrtc" || action == "fptn" || action == "group")
        return { action: "route", outbound: outbound_tag_name };
    if (action == "bypass")
        return { action: "route", outbound: runtime_constants.BYPASS_OUTBOUND_TAG };
    if (action == "block")
        return { action: "reject" };
    if (action == "hosts" || action == "dns")
        return { action: "route", outbound: runtime_constants.DIRECT_OUTBOUND_TAG };
    return { unsupported: "unsupported action " + action };
}

function has_resolve_matchers(rule) {
    return rule.domain != null || rule.domain_suffix != null || rule.domain_keyword != null ||
        rule.domain_regex != null || rule.rule_set != null;
}

function resolve_rule_for_section(section, route_rule) {
    let action = option(section, "action", "");
    let should_resolve = action == "byedpi" || action == "zapret" || action == "zapret2" ||
        action == "wdtt" || action == "olcrtc" || action == "desync" ||
        (connections.is_connections_action(action) &&
            bool_option(section, "resolve_real_ip_for_routing", false));

    if (!should_resolve)
        return null;

    if (!has_resolve_matchers(route_rule)) {
        return {
            warning: "Resolve real IP is enabled for '" + section[".name"] + "', but no domain or rule-set matchers found"
        };
    }

    let resolve_rule = {};
    for (let key in [ "inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "port", "port_range" ]) {
        if (route_rule[key] != null)
            resolve_rule[key] = route_rule[key];
    }
    resolve_rule.action = "resolve";
    resolve_rule.server = connections.routed_dns_enabled(section)
        ? runtime_constants.tag(section[".name"], "routed-dns-server")
        : runtime_constants.DNS_SERVER_TAG;
    if (action == "zapret" || action == "zapret2") {
        let opt_key = action == "zapret2" ? "nfqws2_opt" : "nfqws_opt";
        let raw_opt = trim(option(section, opt_key, ""));
        if (raw_opt != "" && index(raw_opt, "--filter-l3=ipv4") >= 0 && match(raw_opt, /--filter-l3=[^[:space:]]*ipv6/) == null)
            resolve_rule.strategy = "ipv4_only";
    }

    return { rule: resolve_rule };
}

return {
    config,
    target,
    has_resolve_matchers,
    resolve_rule_for_section,
    bittorrent_policy_mode,
    p2p_direct_rules,
    normalize_port_entry
};