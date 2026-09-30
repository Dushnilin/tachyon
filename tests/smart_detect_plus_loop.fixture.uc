let smart_detect=require("service.smart_detect");
let smart_plus=require("service.smart_detect_plus");
let pending_smart_plus={};
let smart_plus_last_run=0;
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
let fs={mkdir:function(path){return true;},readfile:function(path){return null;},writefile:function(path,data){saved=json(data);return true;},
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
function settings(){return {smart_detect:"1",smart_detect_mode:"plus",smart_detect_sections:["vpn"]};}
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
    pending_smart_plus={"api.example.com":{queued:test_clock,scheme:"https",priority:3}};
    smart_plus_last_run=0;
    smart_detect_dns_state={};
    smart_detect_streaks={};
    test_clock=970;smart_detect_observe_dns();test_clock=1000;
}

setup([28,28],0);smart_detect_process_pending();
check(length(added)==1&&added[0]=="example.com","Plus writes main domain after body probes");
check(length(calls)==3&&index(calls[0],"-I")<0,"actual Plus loop uses GET");
setup([28,28],0);change_after_proxy=true;smart_detect_process_pending();
check(length(added)==0&&pending_smart_plus["api.example.com"],"Plus detects DNS switch during probes");
setup([6],0);smart_detect_process_pending();
check(length(added)==0&&length(calls)==1&&pending_smart_plus["api.example.com"],"Plus DNS error never creates a rule or cooldown");
setup([28,28],0);dns_fails=1;smart_detect_process_pending();
check(length(calls)==0,"Plus holds known DNS outage");
setup([28,28],0);in_transaction=true;smart_detect_process_pending();
check(length(calls)==0,"Plus holds active DNS transaction");
setup([0],0);smart_detect_process_pending();
check(length(added)==0&&saved["api.example.com"]==1000,"healthy Direct gets only Plus cooldown");
print(sprintf("PASS: %d actual-function Plus loop checks\n",checks));
