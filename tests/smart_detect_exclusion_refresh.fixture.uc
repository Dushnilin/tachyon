let fs=require("fs");let real_require=require;
let actual=real_require("service.smart_detect_exclusions");
let cfg={smart_detect_exclude_lists:["discord","telegram"]};
let probed=[];let prepared=[];let downloaded=[];let warnings=[];let prepare_ok=true;let download_ok=true;let all_count=0;
let require=function(name){
    if(name=="service.smart_detect_exclusions")return {
        selected_lists:actual.selected_lists,supported:actual.supported,
        prepare_list:function(name,path){push(prepared,{name,path});return prepare_ok;}
    };
    if(name=="singbox.rulesets")return {is_community:actual.supported,
        is_referenceable_srs_file:function(path){push(probed,path);return true;}};
    if(name=="config.connections")return {};
    if(name=="core.url")return {};
    return real_require(name);
};
let TMP_RULESET_FOLDER="/test-rulesets";let CONFIG_NAME="fixture";
let uci_core={get_all:function(config,type){return type=="settings"?cfg:{};}};
function command_success_from_args(args){return true;}
function command_status(command){return 0;}
function log_message(message,level){if(level=="warn")push(warnings,message);}
function bool_option(settings,key,fallback){return settings[key]=="1";}
function import_all_preset_lists(settings){all_count++;return true;}
function import_community_srs_file(name,settings){push(downloaded,name);return download_ok;}
/* STARTUP */
function update_exclusions(settings){let ok=true;/* UPDATE */return ok;}
let count=0;function check(value,label){if(!value)die("FAIL: "+label+"\n");count++;}
prepare_community_rulesets();
check(length(probed)==2&&length(prepared)==2,"startup prepares exclusion-only presets with no routing sections");
check(prepared[0].path=="/test-rulesets/community-discord.srs","startup uses the prepared ruleset directory");
prepared=[];probed=[];
check(update_exclusions(cfg)&&length(downloaded)==2&&length(prepared)==2,"regular update downloads and decodes exclusion-only selections");
downloaded=[];prepared=[];
check(update_exclusions({...cfg,download_all_presets:"1"})&&all_count==1&&length(downloaded)==0&&length(prepared)==2,"download-all reuses presets without duplicate fetches");
prepare_ok=false;
check(!update_exclusions(cfg)&&length(warnings)==2,"decode failure is reported while module retains its old cache");
prepare_ok=true;download_ok=false;
check(!update_exclusions(cfg),"download failure remains visible even with an old usable ruleset");
downloaded=[];prepared=[];probed=[];cfg={};
prepare_community_rulesets();update_exclusions(cfg);
check(length(probed)==0&&length(prepared)==0&&length(downloaded)==0,"empty selection causes no preset IO");
print("PASS: ",count," actual startup/update exclusion integration checks\n");
