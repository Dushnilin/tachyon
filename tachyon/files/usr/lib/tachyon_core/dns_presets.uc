#!/usr/bin/env ucode

let common = require("core.common");
let as_string = common.as_string;

let DNS_PRESETS = {
    udp: [
        { name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], servers_v6: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["8.8.8.8", "8.8.4.4"], servers_v6: ["2001:4860:4860::8888", "2001:4860:4860::8844"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"], servers_v6: ["2620:fe::fe", "2620:fe::9"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["94.140.14.14", "94.140.15.15"], servers_v6: ["2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Control D", servers: ["76.76.2.0", "76.76.10.0"], servers_v6: ["2606:1a40::", "2606:1a40:1::"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Mullvad", servers: ["194.242.2.2"], servers_v6: ["2a07:e340::2"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "DNS.SB", servers: ["185.222.222.222", "45.11.45.11"], servers_v6: ["2a09::", "2a11::"], tags: ["privacy", "no-logs"], country: "🌐" },
        { name: "DNS0.EU", servers: ["193.110.81.0", "185.253.5.0"], servers_v6: ["2a0f:fc80::", "2a0f:fc81::"], tags: ["privacy", "zero-logs"], country: "🇪🇺" },
        { name: "CZ.NIC ODVR", servers: ["193.17.47.1", "185.43.135.1"], servers_v6: ["2001:148f:ffff::1", "2001:148f:fffe::1"], tags: ["dnssec", "privacy"], country: "🇨🇿" },
        { name: "OpenDNS", servers: ["208.67.222.222", "208.67.220.220"], servers_v6: ["2620:119:35::35", "2620:119:53::53"], tags: ["security"], country: "🌐" },
        { name: "AliDNS", servers: ["223.5.5.5", "223.6.6.6"], servers_v6: ["2400:3200::1", "2400:3200:baba::1"], tags: ["fast"], country: "🇨🇳" },
        { name: "CleanBrowsing", servers: ["185.228.168.9", "185.228.169.9"], servers_v6: ["2a0d:2a00:1::", "2a0d:2a00:2::"], tags: ["security", "family"], country: "🌐" },
        { name: "Yandex", servers: ["77.88.8.8", "77.88.8.1"], servers_v6: ["2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"], tags: [], country: "🇷🇺" },
        { name: "Cloudflare IPv6", servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["ipv6", "privacy", "fast"], country: "🌐" },
        { name: "Google IPv6", servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"], tags: ["ipv6", "fast"], country: "🌐" },
        { name: "Quad9 IPv6", servers: ["2620:fe::fe", "2620:fe::9"], tags: ["ipv6", "privacy", "security"], country: "🌐" },
        { name: "AdGuard IPv6", servers: ["2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"], tags: ["ipv6", "privacy", "adblock"], country: "🌐" },
        { name: "Yandex IPv6", servers: ["2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"], tags: ["ipv6"], country: "🇷🇺" }
    ],
    dot: [
        { name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], servers_v6: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["dns.google"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["dns.quad9.net"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["dns.adguard-dns.com"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Control D", servers: ["p0.freedns.controld.com"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Mullvad", servers: ["dns.mullvad.net"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["dns.nextdns.io"], tags: ["privacy", "customizable"], country: "🌐" },
        { name: "DNS.SB", servers: ["dot.sb"], tags: ["privacy", "no-logs"], country: "🌐" },
        { name: "DNS0.EU", servers: ["zero.dns0.eu"], tags: ["privacy", "zero-logs"], country: "🇪🇺" },
        { name: "CZ.NIC ODVR", servers: ["odvr.nic.cz"], tags: ["dnssec", "privacy"], country: "🇨🇿" },
        { name: "CleanBrowsing", servers: ["family-filter-dns.cleanbrowsing.org"], tags: ["security", "family"], country: "🌐" },
        { name: "Yandex", servers: ["common.dot.dns.yandex.net"], tags: [], country: "🇷🇺" },
        { name: "Cloudflare IPv6", servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["ipv6", "privacy", "fast"], country: "🌐" },
        { name: "Google IPv6", servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"], tags: ["ipv6", "fast"], country: "🌐" }
    ],
    doh: [
        { name: "Cloudflare", servers: ["https://cloudflare-dns.com/dns-query"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["https://dns.google/dns-query"], tags: ["fast"], country: "🌐" },
        { name: "Quad9", servers: ["https://dns.quad9.net/dns-query"], tags: ["privacy", "security"], country: "🌐" },
        { name: "AdGuard", servers: ["https://dns.adguard-dns.com/dns-query"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Control D", servers: ["https://freedns.controld.com/p0"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Mullvad", servers: ["https://dns.mullvad.net/dns-query"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["https://dns.nextdns.io/dns-query"], tags: ["privacy", "customizable"], country: "🌐" },
        { name: "DNS.SB", servers: ["https://doh.dns.sb/dns-query"], tags: ["privacy", "no-logs"], country: "🌐" },
        { name: "DNS0.EU", servers: ["https://zero.dns0.eu"], tags: ["privacy", "zero-logs"], country: "🇪🇺" },
        { name: "CZ.NIC ODVR", servers: ["https://odvr.nic.cz/doh"], tags: ["dnssec", "privacy"], country: "🇨🇿" },
        { name: "AliDNS", servers: ["https://dns.alidns.com/dns-query"], tags: ["fast"], country: "🇨🇳" },
        { name: "CleanBrowsing", servers: ["https://doh.cleanbrowsing.org/doh/family-filter/"], tags: ["security", "family"], country: "🌐" }
    ],
    doq: [
        { name: "Cloudflare", servers: ["1.1.1.1:784", "1.0.0.1:784"], servers_v6: ["[2606:4700:4700::1111]:784", "[2606:4700:4700::1001]:784"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Google", servers: ["dns.google:784"], tags: ["fast"], country: "🌐" },
        { name: "AdGuard", servers: ["dns.adguard-dns.com:785"], tags: ["privacy", "adblock"], country: "🌐" },
        { name: "Control D", servers: ["p0.freedns.controld.com:853"], tags: ["privacy", "fast"], country: "🌐" },
        { name: "Mullvad", servers: ["dns.mullvad.net:784"], tags: ["privacy", "no-logs"], country: "🇸🇪" },
        { name: "NextDNS", servers: ["dns.nextdns.io:784"], tags: ["privacy", "customizable"], country: "🌐" },
        { name: "DNS0.EU", servers: ["zero.dns0.eu:853"], tags: ["privacy", "zero-logs"], country: "🇪🇺" },
        { name: "Cloudflare IPv6", servers: ["[2606:4700:4700::1111]:784", "[2606:4700:4700::1001]:784"], tags: ["ipv6", "privacy", "fast"], country: "🌐" }
    ]
};

let BOOTSTRAP_PRESETS = [
    { name: "Cloudflare UDP", servers: ["1.1.1.1", "1.0.0.1"], servers_v6: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["fast", "reliable"], country: "🌐" },
    { name: "Google UDP", servers: ["8.8.8.8", "8.8.4.4"], servers_v6: ["2001:4860:4860::8888", "2001:4860:4860::8844"], tags: ["fast", "reliable"], country: "🌐" },
    { name: "Quad9 UDP", servers: ["9.9.9.9", "149.112.112.112"], servers_v6: ["2620:fe::fe", "2620:fe::9"], tags: ["security"], country: "🌐" },
    { name: "AdGuard UDP", servers: ["94.140.14.14", "94.140.15.15"], servers_v6: ["2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"], tags: ["privacy"], country: "🌐" },
    { name: "Control D UDP", servers: ["76.76.2.0", "76.76.10.0"], servers_v6: ["2606:1a40::", "2606:1a40:1::"], tags: ["privacy"], country: "🌐" },
    { name: "Mullvad UDP", servers: ["194.242.2.2"], servers_v6: ["2a07:e340::2"], tags: ["privacy"], country: "🇸🇪" },
    { name: "DNS.SB UDP", servers: ["185.222.222.222"], servers_v6: ["2a09::"], tags: ["privacy"], country: "🌐" },
    { name: "DNS0.EU UDP", servers: ["193.110.81.0"], servers_v6: ["2a0f:fc80::"], tags: ["privacy"], country: "🇪🇺" },
    { name: "Yandex UDP", servers: ["77.88.8.8", "77.88.8.1"], servers_v6: ["2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"], tags: [], country: "🇷🇺" },
    { name: "Cloudflare UDP IPv6", servers: ["2606:4700:4700::1111", "2606:4700:4700::1001"], tags: ["ipv6", "fast", "reliable"], country: "🌐" },
    { name: "Google UDP IPv6", servers: ["2001:4860:4860::8888", "2001:4860:4860::8844"], tags: ["ipv6", "fast", "reliable"], country: "🌐" },
    { name: "Yandex UDP IPv6", servers: ["2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"], tags: ["ipv6"], country: "🇷🇺" }
];

function get_presets(dns_type) {
    return DNS_PRESETS[as_string(dns_type)] || DNS_PRESETS.udp;
}

function get_bootstrap_presets() {
    return BOOTSTRAP_PRESETS;
}

function get_preset_servers(preset) {
    return preset.servers;
}

function get_preset_v6_servers(preset) {
    return type(preset) == "object" && type(preset.servers_v6) == "array" ? preset.servers_v6 : [];
}

function get_preset_dual_stack_servers(preset) {
    let combined = [];
    for (let s in (type(preset) == "object" && type(preset.servers) == "array" ? preset.servers : []))
        push(combined, s);
    for (let s in get_preset_v6_servers(preset))
        push(combined, s);
    return combined;
}

function format_preset(preset, index) {
    let tags_str = "";
    if (length(preset.tags) > 0)
        tags_str = " [" + join(", ", preset.tags) + "]";
    let v6_str = (type(preset.servers_v6) == "array" && length(preset.servers_v6) > 0)
        ? "\n    IPv6: " + join(", ", preset.servers_v6)
        : "";
    return preset.country + " " + preset.name + tags_str + "\n    " + join(", ", preset.servers) + v6_str;
}

function format_presets_list(dns_type) {
    let presets = get_presets(dns_type);
    let text = "📋 <b>Рекомендованные DNS серверы</b> (" + dns_type + ")\n\n";
    for (let i = 0; i < length(presets); i++) {
        text += "<b>" + (i + 1) + ".</b> " + format_preset(presets[i], i) + "\n\n";
    }
    return text;
}

function format_bootstrap_presets_list() {
    let text = "📋 <b>Рекомендованные Bootstrap DNS серверы</b> (UDP)\n\n";
    text += "Bootstrap DNS используется для начального разрешения имён.\n";
    text += "Рекомендуется использовать быстрые UDP серверы.\n\n";
    for (let i = 0; i < length(BOOTSTRAP_PRESETS); i++) {
        text += "<b>" + (i + 1) + ".</b> " + format_preset(BOOTSTRAP_PRESETS[i], i) + "\n\n";
    }
    return text;
}

function format_protocol_info() {
    let text = "🔍 <b>Поддержка DNS протоколов провайдерами</b>\n\n";
    text += "<b>Cloudflare</b>\n";
    text += "  UDP: 1.1.1.1, 1.0.0.1 / 2606:4700:4700::1111\n";
    text += "  DoT: 1.1.1.1, 1.0.0.1 / 2606:4700:4700::1111\n";
    text += "  DoH: cloudflare-dns.com\n";
    text += "  DoQ: 1.1.1.1:784, [2606:4700:4700::1111]:784\n\n";
    text += "<b>Google</b>\n";
    text += "  UDP: 8.8.8.8, 8.8.4.4 / 2001:4860:4860::8888\n";
    text += "  DoT: dns.google\n";
    text += "  DoH: dns.google\n";
    text += "  DoQ: dns.google:784\n\n";
    text += "<b>Quad9</b>\n";
    text += "  UDP: 9.9.9.9, 149.112.112.112 / 2620:fe::fe\n";
    text += "  DoT: dns.quad9.net\n";
    text += "  DoH: dns.quad9.net\n";
    text += "  DoQ: ❌\n\n";
    text += "<b>AdGuard</b>\n";
    text += "  UDP: 94.140.14.14, 94.140.15.15 / 2a10:50c0::ad1:ff\n";
    text += "  DoT: dns.adguard.com\n";
    text += "  DoH: dns.adguard.com\n";
    text += "  DoQ: dns.adguard.com:785\n\n";
    text += "<b>Mullvad</b>\n";
    text += "  UDP: 194.242.2.2 / 2a07:e340::2\n";
    text += "  DoT: dns.mullvad.net\n";
    text += "  DoH: dns.mullvad.net\n";
    text += "  DoQ: dns.mullvad.net:784\n\n";
    text += "<b>NextDNS</b>\n";
    text += "  UDP: ❌\n";
    text += "  DoT: dns.nextdns.io\n";
    text += "  DoH: dns.nextdns.io\n";
    text += "  DoQ: dns.nextdns.io:784\n";
    return text;
}

return {
    DNS_PRESETS,
    BOOTSTRAP_PRESETS,
    get_presets,
    get_bootstrap_presets,
    get_preset_servers,
    get_preset_v6_servers,
    get_preset_dual_stack_servers,
    format_preset,
    format_presets_list,
    format_bootstrap_presets_list,
    format_protocol_info
};
