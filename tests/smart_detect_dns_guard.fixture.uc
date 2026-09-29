let smart_detect=require("service.smart_detect");
let process_status=smart_detect.probe_status;
let native_require=require;
let test_engine="sing-box";
let require=function(name){return name=="core.engine"?{get_active:function(){return test_engine;}}:native_require(name);};
let CONFIG_NAME="fixture";
let SMART_DETECT_SEEN_FILE="fixture-seen";
let PENDING_SMART_DOMAINS_TTL=300;
let pending_smart_domains={};
let smart_detect_last_run=0;
let test_clock=1000;
let time=function(){return test_clock;};
let calls=[];let added=[];let saved={};
let direct_codes=[];let proxy_code=0;
let dns_index=0;let core_pid="123";let dns_fails=0;let in_transaction=false;
let change_after_proxy=false;
let fs={readfile:function(path){return null;},writefile:function(path,data){saved=json(data);return true;},
    glob:function(path){return in_transaction?["candidate"]:[];}};
function as_string(value){return value==null?"":""+value;}
function probe(args){
    push(calls,args);
    let code;
    if(index(args,"--proxy")>=0){if(change_after_proxy)dns_index++;code=proxy_code;}
    else code=shift(direct_codes);
    return process_status(["sh","-c","exit " + code]);
}
function command_success_from_args(args){return probe(args)==0;}
smart_detect.probe_status=probe;
let common={object_or_empty:function(v){return v||{};},command_status_from_args:probe,
    read_json_file:function(path){return index(path,"config.json")>=0?{dns:{servers:[{tag:"dns",server:"example"}]}}:{main_index:dns_index,bootstrap_index:0};}};
let uci_core={get_all:function(config,section){return {};}};
let event_controller={smart_detect_queue_order:function(pending,domains){return domains;},
    smart_detect_main_domain:function(host){return "example.com";}};
let controller={proxy_port:function(){return "4534";},dns_consecutive_fails:function(){return dns_fails;},
    create_tick_context:function(){return {settings:{dns_type:"doh",dns_server:["resolver"]},singbox_pid:core_pid,singbox_running:test_engine=="sing-box",is_paused:false,reload_in_progress:false};}};
function settings(){return {smart_detect:"1",smart_detect_sections:["vpn"]};}
function smart_detect_get_proxy_sections(){return ["vpn"];}
function smart_detect_domain_resolves(domain){return true;}
function smart_detect_apply_domains(entries){for(let e in entries)push(added,e.domain);return entries;}
function log_message(message,level){}
function send_telegram_notification(message){die("unexpected notification\n");}
let checks=0;
function check(ok,name){if(!ok)die("FAIL: "+name+"\n");checks++;}
/* IMPLEMENTATION */

function setup(codes, proxy){
    test_engine="sing-box";test_clock=1000;dns_index=0;core_pid="123";dns_fails=0;in_transaction=false;change_after_proxy=false;
    smart_detect_last_run=0;calls=[];added=[];saved={};direct_codes=codes;proxy_code=proxy;
    pending_smart_domains={"api.example.com":test_clock};
    smart_detect_dns_state={};
    smart_detect_streaks={};
    test_clock=970;smart_detect_observe_dns();test_clock=1000;
}

// A block is only acted on after a second, later sample: the first failure
// opens the streak and re-queues the domain.
function confirm(codes,proxy){
    smart_detect_process_pending();
    test_clock=1300;
    direct_codes=codes;
    smart_detect_process_pending();
}

setup([6,6],0);smart_detect_process_pending();
check(length(added)==0 && length(calls)==1,"DNS failure after successful prelookup never adds VPN");
check(pending_smart_domains["api.example.com"] && !saved["api.example.com"],"DNS failure deferred without seen cooldown");
setup([60,60],0);smart_detect_process_pending();
check(length(added)==0 && length(calls)==1,"certificate error is not blocking evidence");
setup([23,23],0);smart_detect_process_pending();
check(length(added)==0,"local I/O error is not blocking evidence");
setup([28,28],0);smart_detect_process_pending();
check(length(added)==0,"one transport failure alone never adds VPN");
confirm([28,28],0);
check(length(added)==1,"stable transport failure with successful proxy still adds VPN");
setup([0],0);smart_detect_process_pending();
check(length(added)==0 && length(calls)==1,"healthy Direct kept");
setup([28,28],28);smart_detect_process_pending();
check(length(added)==0,"both paths fail: no rule");
setup([28,28],0);change_after_proxy=true;confirm([28,28],0);
check(length(added)==0 && pending_smart_domains["api.example.com"],"DNS changed during comparison: retry later");
setup([28,28],0);core_pid="456";smart_detect_process_pending();
check(length(added)==0 && length(calls)==0,"core restart starts grace before any comparison");
setup([28,28],0);in_transaction=true;smart_detect_process_pending();
check(length(added)==0 && length(calls)==0,"active DNS failover transaction blocks comparison");
setup([28,28],0);dns_fails=1;smart_detect_process_pending();
check(length(added)==0 && length(calls)==0,"known unhealthy resolver blocks comparison");
setup([28,28],0);dns_index=1;smart_detect_process_pending();
check(length(calls)==0,"fallback switch starts grace");
test_clock=1030;confirm([28,28],0);
check(length(added)==1,"stable fallback resumes detection after grace");
// Switching engines changes the resolver signature, so the grace restarts once
// more before the first probe is allowed.
setup([28,28],0);test_engine="steer";smart_detect_observe_dns();test_clock=1030;confirm([28,28],0);
check(length(added)==1,"Steer resumes without a sing-box process after resolver grace");
setup([28,28],0);test_engine="steer-extended";in_transaction=true;smart_detect_observe_dns();test_clock=1030;confirm([28,28],0);
check(length(added)==1,"Steer extended is not blocked by stale sing-box candidate files");
print(sprintf("PASS: %d actual-function DNS guard checks\n",checks));
