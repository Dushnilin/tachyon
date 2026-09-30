let smart_plus = require("service.smart_detect_plus");
let CONFIG_NAME = "fixture";
let commits=0;let reloads=0;let conflict=false;let commit_ok=true;let reload_ok=true;
let values={};
let cursor={
    unload:function(){}, load:function(){}, changes:function(){return conflict?{fixture:{}}:{};},
    get_all:function(config,name){return values[name];},
    set:function(config,name,key,data){values[name][key]=data;return true;},
    delete:function(config,name,key){delete values[name][key];return true;},
    commit:function(){commits++;return commit_ok;}
};
let uci_core={cursor:function(){return cursor;},get_all:function(config,name){return values[name]||{};}};
let smart_detect={probe_status:function(){reloads++;return reload_ok?0:1;}};
let common={object_or_empty:function(v){return v||{};}};
function log_message(msg,lvl){}
let notifications=[];
function send_telegram_notification(msg){push(notifications,msg);}
let checks=0;
function check(ok,name){if(!ok)die("FAIL: "+name+"\n");checks++;}
/* IMPLEMENTATION */
values={settings:{smart_detect:"1",smart_detect_mode:"plus"},vpn:{user_domains:"EXAMPLE.COM\nexample.com",user_domains_text:"api.example.net"}};
let entries=[{section:"vpn",domain:"example.com"},{section:"vpn",domain:"example.org"}];
check(length(smart_detect_apply_plus_domains(entries))==2,"accept both domains in one batch");
check(commits==1&&reloads==1,"one commit and reload for the batch");
check(length(values.vpn.user_domains)==3&&values.vpn.user_domains_text==null,"normalize and merge legacy values without duplicates");
check(length(smart_detect_apply_plus_domains(entries))==2,"already covered domains settle queue");
check(commits==1&&reloads==1,"unchanged list never causes reload");
conflict=true;
check(length(smart_detect_apply_plus_domains([{section:"vpn",domain:"new.example"}]))==0,"pending UI changes defer write");
check(commits==1&&length(values.vpn.user_domains)==3,"pending changes not committed");
conflict=false;reload_ok=false;
let retry=[{section:"vpn",domain:"retry.example"}];
check(length(smart_detect_apply_plus_domains(retry))==0,"failed reload reported inconclusive");
check(commits==2&&reloads==2,"saved once before failed reload");
reload_ok=true;
check(length(smart_detect_apply_plus_domains(retry))==1,"failed reload can be retried");
check(commits==2&&reloads==3,"retry does not duplicate or recommit domain");
commit_ok=false;
check(length(smart_detect_apply_plus_domains([{section:"vpn",domain:"failed.example"}]))==0,"failed commit is not success");
check(reloads==3,"failed commit never reloads");
values.settings.smart_detect_mode="default";
check(length(smart_detect_apply_plus_domains(entries))==0&&reloads==3,"mode changed during probes prevents Plus write");
check(length(notifications)==0,"disabled Telegram receives no notifications");
values.settings.smart_detect_mode="plus";commit_ok=true;
values.telegram={enabled:"1",bot_token:"fixture",admin_ids:"fixture"};
smart_detect_apply_plus_domains([{section:"vpn",domain:"site.example",source_domain:"api.site.example"}]);
check(length(notifications)==1&&notifications[0]=="🔍 *Smart Detect*: `api.site.example` недоступен напрямую, работает через прокси.\nДомен `site.example` добавлен в секцию *vpn*.","Plus keeps Smart Detect title, original hostname and saved main domain");
smart_detect_apply_plus_domains([{section:"vpn",domain:"site.example"}]);
check(length(notifications)==1,"covered domains do not send duplicate notifications");
print(sprintf("PASS: %d actual-function Plus UCI checks\n",checks));
