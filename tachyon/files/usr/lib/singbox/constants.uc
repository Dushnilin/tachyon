#!/usr/bin/env ucode

const DNS_SERVER_TAG = "dns-server";
const FAKEIP_DNS_SERVER_TAG = "fakeip-server";
const BOOTSTRAP_DNS_SERVER_TAG = "bootstrap-dns-server";
const FAKEIP_DNS_RULE_TAG = "fakeip-dns-rule-tag";
const FAKEIP_RULESET_DNS_RULE_TAG = "fakeip-ruleset-dns-rule-tag";
const SERVICE_FAKEIP_DNS_RULE_TAG = "service-fakeip-dns-rule-tag";

const TPROXY_INBOUND_TAG = "tproxy-in";
const TPROXY_INBOUND_ADDRESS = "0.0.0.0";
const TPROXY_INBOUND6_TAG = "tproxy6-in";
const TPROXY_INBOUND6_ADDRESS = "::1";
const TPROXY_INBOUND_PORT = 1602;
const DNS_INBOUND_TAG = "dns-in";
const DNS_INBOUND_ADDRESS = "127.0.0.42";
const DNS_INBOUND_PORT = 53;
const DNS_BLOCK_INBOUND_TAG = "dns-block-in";
const DNS_BLOCK_INBOUND_ADDRESS = "::";
const DNS_BLOCK_INBOUND_PORT = 1053;
const SOURCE_DNS_INBOUND_TAG = "source-dns-in";
const SOURCE_DNS_INBOUND_ADDRESS = "::";
const SOURCE_DNS_INBOUND_PORT = 1603;
const DNSMASQ_DNS_SERVER_TAG = "dnsmasq-server";
const DNS_SOURCE_SET = "tachyon_dns_sources";
const DNS_SOURCE6_SET = "tachyon_dns_sources6";

const SERVICE_MIXED_INBOUND_TAG = "service-mixed-in";
const SERVICE_MIXED_INBOUND_ADDRESS = "127.0.0.1";
const SERVICE_MIXED_INBOUND_PORT = 4534;
const DIRECT_BYPASS_INBOUND_TAG = "direct-bypass-in";
const DIRECT_BYPASS_OUTBOUND_TAG = "direct-bypass-out";
const DIRECT_BYPASS_DEFAULT_PORT = 2080;
const DIRECT_OUTBOUND_TAG = "direct-out";
const BYPASS_OUTBOUND_TAG = "bypass-out";
const OUTBOUND_MARK = 134217728;
const FAKEIP_INET4_RANGE = "198.18.0.0/15";
const FAKEIP_INET6_RANGE = "fc00::/18";

const DISABLED_UPDATE_INTERVAL = "876000h";
const URLTEST_DEFAULT_IDLE_TIMEOUT = "30m";
const CHECK_PROXY_IP_DOMAIN = "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = "fakeip.podkop.fyi";
const TMP_SING_BOX_FOLDER = "/tmp/sing-box";
const TMP_RULESET_FOLDER = TMP_SING_BOX_FOLDER + "/rulesets";
const ZAPRET_ROUTE_MARK_BASE = 0x01000000;
const ZAPRET2_ROUTE_MARK_BASE = 0x02000000;
const BYEDPI_LISTEN_ADDRESS = "127.0.0.1";
const BYEDPI_PORT_BASE = 1080;

const DOH_BLOCK_IPV4_CIDRS = [
    "1.1.1.1/32", "1.0.0.1/32",
    "8.8.8.8/32", "8.8.4.4/32",
    "9.9.9.9/32", "9.9.9.11/32",
    "149.112.112.112/32",
    "208.67.222.222/32", "208.67.220.220/32",
    "94.140.14.14/32", "94.140.15.15/32",
    "77.88.8.8/32", "77.88.8.1/32"
];

const DOH_BLOCK_IPV6_CIDRS = [
    "2606:4700:4700::1111/128", "2606:4700:4700::1001/128",
    "2001:4860:4860::8888/128", "2001:4860:4860::8844/128",
    "2620:fe::fe/128", "2620:fe::9/128",
    "2620:119:35::35/128", "2620:119:53::53/128",
    "2a10:50c0::ad1:ff/128", "2a10:50c0::ad2:ff/128",
    "2a02:6b8::feed:0ff/128", "2a02:6b8:0:1::feed:0ff/128"
];

let common = require("core.common");
let as_string = common.as_string;

const RESERVED_TAGS = {
    [DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_SERVER_TAG]: true,
    [BOOTSTRAP_DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_RULE_TAG]: true,
    [FAKEIP_RULESET_DNS_RULE_TAG]: true,
    [SERVICE_FAKEIP_DNS_RULE_TAG]: true,
    [TPROXY_INBOUND_TAG]: true,
    [TPROXY_INBOUND6_TAG]: true,
    [DNS_INBOUND_TAG]: true,
    [DNS_BLOCK_INBOUND_TAG]: true,
    [SOURCE_DNS_INBOUND_TAG]: true,
    [DNSMASQ_DNS_SERVER_TAG]: true,
    [SERVICE_MIXED_INBOUND_TAG]: true,
    [DIRECT_BYPASS_INBOUND_TAG]: true,
    [DIRECT_BYPASS_OUTBOUND_TAG]: true,
    [DIRECT_OUTBOUND_TAG]: true,
    [BYPASS_OUTBOUND_TAG]: true
};

function tag(base, postfix) {
    let candidate = as_string(base) + "-" + as_string(postfix);
    return RESERVED_TAGS[candidate] ? candidate + "-1" : candidate;
}

function inbound_tag(section_name) {
    return tag(section_name, "in");
}

function outbound_tag(section_name) {
    return tag(section_name, "out");
}

function domain_resolver_tag(section_name) {
    return tag(section_name, "domain-resolver");
}

function server_inbound_tag(section_name) {
    return tag("server-" + as_string(section_name), "in");
}

function tailscale_dns_server_tag(section_name) {
    return tag("server-" + as_string(section_name), "tailscale-dns");
}

return {
    DNS_SERVER_TAG,
    FAKEIP_DNS_SERVER_TAG,
    BOOTSTRAP_DNS_SERVER_TAG,
    FAKEIP_DNS_RULE_TAG,
    FAKEIP_RULESET_DNS_RULE_TAG,
    SERVICE_FAKEIP_DNS_RULE_TAG,
    TPROXY_INBOUND_TAG,
    TPROXY_INBOUND_ADDRESS,
    TPROXY_INBOUND6_TAG,
    TPROXY_INBOUND6_ADDRESS,
    TPROXY_INBOUND_PORT,
    DNS_INBOUND_TAG,
    DNS_INBOUND_ADDRESS,
    DNS_INBOUND_PORT,
    DNS_BLOCK_INBOUND_TAG,
    DNS_BLOCK_INBOUND_ADDRESS,
    DNS_BLOCK_INBOUND_PORT,
    SOURCE_DNS_INBOUND_TAG,
    SOURCE_DNS_INBOUND_ADDRESS,
    SOURCE_DNS_INBOUND_PORT,
    DNSMASQ_DNS_SERVER_TAG,
    DNS_SOURCE_SET,
    DNS_SOURCE6_SET,
    SERVICE_MIXED_INBOUND_TAG,
    SERVICE_MIXED_INBOUND_ADDRESS,
    SERVICE_MIXED_INBOUND_PORT,
    DIRECT_BYPASS_INBOUND_TAG,
    DIRECT_BYPASS_OUTBOUND_TAG,
    DIRECT_BYPASS_DEFAULT_PORT,
    DIRECT_OUTBOUND_TAG,
    BYPASS_OUTBOUND_TAG,
    OUTBOUND_MARK,
    FAKEIP_INET4_RANGE,
    FAKEIP_INET6_RANGE,
    DISABLED_UPDATE_INTERVAL,
    URLTEST_DEFAULT_IDLE_TIMEOUT,
    CHECK_PROXY_IP_DOMAIN,
    FAKEIP_TEST_DOMAIN,
    TMP_SING_BOX_FOLDER,
    TMP_RULESET_FOLDER,
    ZAPRET_ROUTE_MARK_BASE,
    ZAPRET2_ROUTE_MARK_BASE,
    BYEDPI_LISTEN_ADDRESS,
    BYEDPI_PORT_BASE,
    DOH_BLOCK_IPV4_CIDRS,
    DOH_BLOCK_IPV6_CIDRS,
    RESERVED_TAGS,
    tag,
    inbound_tag,
    outbound_tag,
    domain_resolver_tag,
    server_inbound_tag,
    tailscale_dns_server_tag
};