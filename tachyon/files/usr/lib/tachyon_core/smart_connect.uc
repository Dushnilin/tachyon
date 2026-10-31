// Opt-in connection-time routing. No learned domains are written to UCI, and
// selecting/recovering an IP never regenerates the core configuration.
let common = require("core.common");
let exclusions = require("service.smart_detect_exclusions");

const PORTS = {auto:14700, zapret:14701, direct_proxy:14710, zapret_proxy:14711,
    vpn_proxy:14712, direct_dns:14720, zapret_dns:14721};
const PREFIX = "smart-connect-";

function enabled(settings) { return settings?.smart_detect == "1" && settings?.smart_detect_chain == "1"; }
function list(value) { return type(value) == "array" ? value : (value ? [value] : []); }
function endpoint(port) { return "127.0.0.1:" + port; }
function clone(value) { return json(sprintf("%J",value)); }

function plan(config, settings, sections, sources) {
    if (!enabled(settings)) return null;
    let zapret = settings.smart_detect_chain_zapret;
    let vpn = settings.smart_detect_chain_vpn;
    if (!zapret || !vpn || zapret == vpn) return {error:"Smart Detect chain requires distinct Zapret and VPN sections"};
    let selected = {};
    for (let section in sections) if (section.enabled != "0") selected[section[".name"]] = section;
    if (!selected[zapret] || !selected[vpn]) return {error:"Smart Detect chain section is disabled or unavailable"};
    let outputs = {};
    for (let out in config.outbounds || []) outputs[out.tag] = out;
    for (let out in config.endpoints || []) outputs[out.tag] = out;
    let ztag = zapret + "-out", vtag = vpn + "-out";
    if (!outputs[ztag] || outputs[ztag].type != "direct" || !outputs[ztag].routing_mark)
        return {error:"Smart Detect chain needs a generated Zapret/Zapret2 direct outbound with its routing mark"};
    if (!outputs[vtag] || index(["block", "dns"], outputs[vtag].type) >= 0 ||
        (outputs[vtag].type == "direct" && !outputs[vtag].bind_interface))
        return {error:"Smart Detect chain VPN section must provide a remote proxy or tunnel"};
    let indexes = exclusions.state(settings);
    if (!indexes.ready) return {error:"Smart Detect chain exclusion lists are not ready"};
    let dns = {};
    for (let server in config.dns.servers || []) dns[server.tag] = server;
    let zdns = dns[zapret + "-routed-dns-server"] ? zapret + "-routed-dns-server" : "dns-server";
    if (!dns[zdns] || !dns["dns-server"]) return {error:"Smart Detect chain DNS resolver is unavailable"};
    let budget = int(settings.smart_detect_chain_budget_ms || "3000");
    if (budget < 100 || budget > 10000) return {error:"Smart Detect chain Zapret budget must be 100..10000 ms"};
    let safe_dns = [];
    for (let tag in ["dns-server",zdns]) {
        let d=dns[tag];push(safe_dns,{tag,type:d.type,server:d.server,server_port:d.server_port,path:d.path,detour:d.detour});
    }
    let helper = {
        listen_auto:endpoint(PORTS.auto), listen_zapret:endpoint(PORTS.zapret),
        direct_proxy:endpoint(PORTS.direct_proxy), zapret_proxy:endpoint(PORTS.zapret_proxy), vpn_proxy:endpoint(PORTS.vpn_proxy),
        direct_dns:endpoint(PORTS.direct_dns), zapret_dns:endpoint(PORTS.zapret_dns),
        zapret_budget_ms:budget, direct_budget_ms:1500, cache_seconds:300, retry_seconds:300,
        cache_limit:1024, max_connections:128, max_probes:4,
        excluded_domains:keys(indexes.suffixes), excluded_keywords:indexes.keywords,
        excluded_regex:keys(indexes.regexes_seen),
        status_path:(getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/smart-connect/status.json"
    };
    let strategies=[];
    for (let source in sources || []) if (source.source_type=="zapret" || source.source_type=="zapret2")
        push(strategies,{id:source[".name"],nfqws:source.nfqws_opt,nfqws2:source.nfqws2_opt});
    helper.generation = sprintf("%J",{zapret,vpn,mark:outputs[ztag].routing_mark,dns:safe_dns,strategies,
        strategy:selected[zapret].nfqws2_opt || selected[zapret].nfqws_opt,
        sources:selected[zapret].outbound_source_refs,exclusions:helper.excluded_domains,
        keywords:helper.excluded_keywords,regexes:helper.excluded_regex,budget});
    return {helper, ztag, vtag, zdns};
}

function matcher(rule) {
    let copy=clone(rule);
    for (let key in ["action","outbound","server","strategy","disable_cache","rewrite_ttl","client_subnet","timeout"])
        delete copy[key];
    return copy;
}
function web_rule(rule, outbound) {
    return {type:"logical",mode:"and",rules:[matcher(rule),{network:"tcp",port:[80,443]}],action:"route",outbound};
}

function configure(config, settings, sections, sources) {
    let p=plan(config,settings,sections,sources);
    if (!p || p.error) return p;
    let used_ports={}, used_tags={};
    for (let inbound in config.inbounds || []) { used_ports[inbound.listen_port]=true;used_tags[inbound.tag]=true; }
    for (let port in values(PORTS)) if (used_ports[port]) return {error:"Smart Detect chain listener port collision: " + port};
    for (let out in config.outbounds || []) if (index(out.tag,PREFIX)==0) return {error:"Reserved Smart Detect chain outbound tag: " + out.tag};
    for (let tag in keys(used_tags)) if (index(tag,PREFIX)==0) return {error:"Reserved Smart Detect chain inbound tag: " + tag};

    let pinned=[];
    for (let route in ["direct","zapret","vpn"]) {
        let tag=PREFIX+route+"-in";
        push(config.inbounds,{type:"socks",tag,listen:"127.0.0.1",listen_port:PORTS[route+"_proxy"]});
        push(pinned,{action:"route",inbound:tag,outbound:route=="direct" ? "direct-out" : (route=="zapret" ? p.ztag : p.vtag)});
    }
    let dns_in=[];
    for (let route in ["direct","zapret"]) {
        let tag=PREFIX+route+"-dns-in";push(dns_in,tag);
        push(config.inbounds,{type:"direct",tag,listen:"127.0.0.1",listen_port:PORTS[route+"_dns"]});
        unshift(config.dns.rules,{action:"route",inbound:tag,server:route=="direct" ? "dns-server" : p.zdns,disable_cache:true});
    }
    unshift(pinned,{action:"hijack-dns",inbound:dns_in});
    let auto_tag=PREFIX+"auto-out", zapret_tag=PREFIX+"zapret-out";
    push(config.outbounds,{type:"socks",tag:auto_tag,server:"127.0.0.1",server_port:PORTS.auto,version:"5"});
    push(config.outbounds,{type:"socks",tag:zapret_tag,server:"127.0.0.1",server_port:PORTS.zapret,version:"5"});
    let rules=[];
    // Insert before the selected section's resolve step, so a stale/broken
    // resolved IP cannot preempt the connector's independent DNS/IP selection.
    let original=config.route.rules || [];
    let index_map={};
    for (let i=0;i<length(original);i++) {
        let rule=original[i];
        if ((rule.action=="resolve" && original[i+1]?.outbound==p.ztag) || rule.outbound==p.ztag) {
            push(rules,web_rule(rule,zapret_tag));
        }
        index_map[i]=length(pinned)+length(rules);
        push(rules,rule);
    }
    // Explicit block, bypass, VPN, server, source and full-tunnel rules have
    // already been evaluated. Only otherwise-Direct LAN web traffic enters here.
    if (config.route.final=="direct-out") {
        let clients=["tproxy-in","tproxy6-in","tun-in","client-mixed-in"];
        push(rules,{inbound:clients,ip_is_private:true,action:"route",outbound:"direct-out"});
        push(rules,{inbound:clients,network:"tcp",port:[80,443],action:"route",outbound:auto_tag});
    }
    config.route.rules=[...pinned,...rules];
    p.route_index_map=index_map;
    return p;
}

return {enabled,plan,configure,PORTS};
