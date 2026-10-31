let fs=require("fs");
let module=require("tachyon_core.smart_connect");
function base() {return {
    inbounds:[{tag:"tproxy-in",type:"tproxy",listen_port:1600}],
    outbounds:[{tag:"direct-out",type:"direct"},{tag:"zapret-out",type:"direct",routing_mark:33554433},{tag:"proxy-out",type:"selector",outbounds:["node"]},{tag:"node",type:"socks",server:"127.0.0.1",server_port:19999}],
    dns:{servers:[{tag:"dns-server",type:"udp",server:"1.1.1.1"},{tag:"zapret-routed-dns-server",type:"https",server:"1.1.1.1"}],rules:[{server:"fakeip-server",domain_suffix:["example.com"]}]},
    route:{final:"direct-out",rules:[
        {action:"sniff",inbound:["tproxy-in"]},
        {action:"reject",domain_suffix:["blocked.example"]},
        {action:"route",domain_suffix:["manual.example"],outbound:"proxy-out"},
        {action:"resolve",inbound:["tproxy-in"],domain_suffix:["vpn.example"],server:"dns-server"},
        {action:"route",inbound:["tproxy-in"],domain_suffix:["vpn.example"],outbound:"proxy-out"},
        {action:"resolve",inbound:["tproxy-in"],domain_suffix:["example.com"],server:"zapret-routed-dns-server"},
        {action:"route",inbound:["tproxy-in"],domain_suffix:["example.com"],outbound:"zapret-out"}
    ]}
};}
let cfg={smart_detect:"1",smart_detect_chain:"1",smart_detect_chain_zapret:"zapret",smart_detect_chain_vpn:"proxy",smart_detect_exclude:["bank.example"]};
let sections=[{".name":"zapret",enabled:"1",action:"zapret2"},{".name":"proxy",enabled:"1",action:"connection"}];
let disabled=base();let before=sprintf("%J",disabled);assert(module.configure(disabled,{},sections)==null,"opt-in");assert(sprintf("%J",disabled)==before,"disabled configuration unchanged");
let core=base(),p=module.configure(core,cfg,sections);assert(!p.error,p.error);
assert(length(core.inbounds)==6,"only fixed shared listeners, no per-domain listener");
for(let i=1;i<length(core.inbounds);i++)assert(core.inbounds[i].listen=="127.0.0.1","listeners are loopback only");
assert(p.helper.zapret_budget_ms==3000,"default budget");
assert(index(p.helper.excluded_domains,"bank.example")>=0,"manual exclusions passed to connector");
let probe=core.route.rules[1];assert(probe.inbound=="smart-connect-direct-in"&&probe.outbound=="direct-out","Direct probe forced away from user routes");
assert(core.route.rules[2].outbound=="zapret-out"&&core.route.rules[3].outbound=="proxy-out","Zapret and selected VPN probes forced");
assert(core.dns.rules[0].server=="zapret-routed-dns-server"&&core.dns.rules[1].server=="dns-server","real section DNS precedes FakeIP");
let override=-1,resolve=-1,manual=-1;
for(let i,r in core.route.rules){
    if(r.action=="resolve"&&r.server=="zapret-routed-dns-server")resolve=i;
    if(r.outbound=="smart-connect-zapret-out"&&override<0)override=i;
    if(r.outbound=="proxy-out"&&r.domain_suffix?.[0]=="manual.example")manual=i;
    if(r.outbound=="smart-connect-zapret-out")assert(index(sprintf("%J",r),"vpn.example")<0,"unrelated resolve rule must not enter Zapret chain");
}
assert(override>=0&&override<resolve,"connector selected before the original IP is resolved");
assert(manual<override,"manual VPN rules retain precedence");
let fallback=core.route.rules[-1];assert(fallback.outbound=="smart-connect-auto-out"&&fallback.network=="tcp"&&length(fallback.port)==2,"only LAN web TCP enters fallback");
let bad={...cfg,smart_detect_chain_vpn:"zapret"};assert(module.configure(base(),bad,sections).error,"identical sections rejected");
bad={...cfg,smart_detect_chain_vpn:"missing"};assert(module.configure(base(),bad,sections).error,"missing section rejected");
let collision=base();push(collision.inbounds,{tag:"user",listen_port:14711});assert(module.configure(collision,cfg,sections).error,"port collision rejected");
let unknown=base();unknown.outbounds[1].routing_mark=null;assert(module.configure(unknown,cfg,sections).error,"ordinary Direct cannot masquerade as Zapret");
print("PASS: Smart Connect configuration, forced probes, precedence, exclusions and opt-in\n");
if (ARGV[0]) fs.writefile(ARGV[0],sprintf("%J",p.helper));
