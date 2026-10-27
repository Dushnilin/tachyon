let smart_plus = require("service.smart_detect_plus");
let CONFIG_NAME = "fixture";
let commits=0;let reloads=0;let conflict=false;let commit_ok=true;let reload_ok=true;
let values={};
function settings(){return values.settings;}
function as_string(value){return value == null ? "" : ""+value;}
function command_status(command){reloads++;return 0;}
let cursor={
    unload:function(){}, load:function(){}, changes:function(){return conflict?{fixture:{}}:{};},
    get_all:function(config,name){return values[name];},
    set:function(config,name,key,data){values[name][key]=data;return true;},
    delete:function(config,name,key){delete values[name][key];return true;},
    list_add:function(config,name,key,data){push(values[name][key],data);return true;},
    commit:function(){commits++;return commit_ok;}
};
let uci_core={cursor:function(){return cursor;},get_all:function(config,name){return values[name]||{};}};
let smart_detect={probe_status:function(){reloads++;return reload_ok?0:1;}};
let common={object_or_empty:function(v){return v||{};}};
function get_connections(){return null;}
function log_message(msg,lvl){}
let notifications=[];
let notification_entries=[];
function send_telegram_notification(msg, key, cooldown, entries){push(notifications,msg);push(notification_entries,entries);}
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
check(notification_entries[0][0].domain=="site.example"&&notification_entries[0][0].source_domain=="api.site.example", "Plus notification actions keep original hostname and saved target");
check(length(notifications)==1&&notifications[0]=="🔍 *Smart Detect*: `api.site.example` недоступен напрямую, работает через прокси.\nДомен `site.example` добавлен в секцию *vpn*.","Plus keeps Smart Detect title, original hostname and saved main domain");
smart_detect_apply_plus_domains([{section:"vpn",domain:"site.example"}]);
check(length(notifications)==1,"covered domains do not send duplicate notifications");
let previous_domains = sprintf("%J", values.vpn.user_domains);
let previous_commits = commits;
values.settings.smart_detect_exclude = ["example.org"];
check(length(smart_detect_apply_plus_domains([{section:"vpn",domain:"example.org",source_domain:"api.example.org"}])) == 0, "final UCI write rechecks newly selected exclusions");
check(commits == previous_commits && sprintf("%J", values.vpn.user_domains) == previous_domains, "new exclusions do not delete existing routing rules or commit unrelated changes");
values.settings.smart_detect_exclude = ["cdn.safe.example"];
smart_detect_apply_plus_domains([{section:"vpn",domain:"safe.example",source_domain:"api.safe.example"}]);
check(index(values.vpn.user_domains, "api.safe.example") >= 0 && index(values.vpn.user_domains, "safe.example") < 0, "final UCI write narrows an unsafe parent expansion");
values={settings:{smart_detect:"1",smart_detect_mode:"default",smart_detect_exclude:["example.com"]},vpn:{user_domains:["manual.example"]}};
previous_commits=commits;let previous_reloads=reloads;
check(length(smart_detect_apply_domains([{section:"vpn",domain:"api.example.com"}]))==0,"Default final write rechecks manual exclusions");
check(commits==previous_commits&&reloads==previous_reloads&&length(values.vpn.user_domains)==1,"Default exclusions preserve existing rules without commit or reload");
check(length(smart_detect_apply_domains([{section:"vpn",domain:"allowed.example"}]))==1,"Default still adds eligible domains");
conflict=true;
check(length(smart_detect_apply_domains([{section:"vpn",domain:"pending.example"}]))==0&&index(values.vpn.user_domains,"pending.example")<0,"Default defers pending UI changes");
conflict=false;values.settings.smart_detect_exclude_lists=["unknown"];
check(length(smart_detect_apply_domains([{section:"vpn",domain:"missing.example"}]))==0,"Default final write waits for missing preset cache");
values={settings:{smart_detect:"1",smart_detect_mode:"plus"},grp:{action:"group",enabled:"1",group_members:["vpn"],user_domains:["existing.example"]}};
previous_commits=commits;previous_reloads=reloads;
check(length(smart_detect_apply_plus_domains([{section:"grp",domain:"grouped.example",source_domain:"sub.grouped.example"}]))==1,"Plus writes detected domain to group section user_domains");
check(commits==previous_commits+1&&reloads==previous_reloads+1&&index(values.grp.user_domains,"grouped.example")>=0,"Plus commits and reloads group section user_domains");
values={settings:{smart_detect:"1",smart_detect_mode:"default"},grp:{action:"group",enabled:"1",group_members:["vpn"],user_domains:["existing.example"]}};
previous_commits=commits;previous_reloads=reloads;
check(length(smart_detect_apply_domains([{section:"grp",domain:"default-group.example"}]))==1,"Default writes detected domain to group section user_domains");
check(commits==previous_commits+1&&reloads==previous_reloads+1&&index(values.grp.user_domains,"default-group.example")>=0,"Default commits and reloads group section user_domains");
print(sprintf("PASS: %d actual-function Smart Detect UCI checks\n",checks));
