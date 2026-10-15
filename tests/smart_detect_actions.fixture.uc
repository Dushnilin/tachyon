let db = {};
let saved = {};
let pending = false;
let commit_ok = true;
let set_ok = true;
let commits = 0;
let cursor = {
    load: function() { db = json(sprintf("%J", saved)); },
    unload: function() {},
    changes: function() { return pending ? { fixture: {} } : {}; },
    get_all: function(config, name) { return db[name]; },
    set: function(config, name, key, value) { if (!set_ok) return false; db[name][key] = value; return true; },
    delete: function(config, name, key) { delete db[name][key]; return true; },
    commit: function() { if (!commit_ok) return false; saved = json(sprintf("%J", db)); commits++; return true; }
};
let fixture_uci = { cursor: function() { return cursor; } };
/* IMPLEMENTATION */
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }
function reset(expand) {
    saved = { settings: { smart_detect_expand_to_root: expand, smart_detect_exclude: ["keep.example"] },
        vpn: { user_domains: ["manual.example", "site.co.uk", "other.example"], user_domains_text: "legacy.example\n" } };
    pending = false; set_ok = true; commit_ok = true;
}
function receipt() {
    let section = saved.vpn;
    let id = actions.create([{ section: "vpn", domain: "site.co.uk", source_domain: "api.site.co.uk",
        snapshot: sprintf("%J", [section.user_domains, section.user_domains_text]) },
        { section: "vpn", domain: "other.example", snapshot: sprintf("%J", [section.user_domains, section.user_domains_text]) }], "42");
    check(id != null && actions.bind_message(id, "42", 7), "message bound receipt");
    return id;
}
function command(id, kind, i) { return "/sd " + kind + " " + id + " " + (i || 0); }
reset("1");
let id = receipt();
let rows = actions.keyboard(id, k => k);
check(length(rows) == 2 && length(rows[0]) == 2, "one pair of buttons per batch entry");
check(length(rows[0][0].callback_data) <= 64, "callback fits Telegram wire limit");
check(actions.apply(command(id,"undo"), "43", 7).key == "sd_obsolete", "different chat rejected");
check(actions.apply(command(id,"undo"), "42", 8).key == "sd_obsolete", "different message rejected");
pending = true;
check(actions.apply(command(id,"undo"), "42", 7).key == "sd_pending" && commits == 0, "pending UCI changes untouched");
pending = false;
let result = actions.apply(command(id,"exclude"), "42", 7);
check(result.changed && result.domain == "site.co.uk", "PSL root exclusion enabled");
check(index(saved.settings.smart_detect_exclude,"site.co.uk") >= 0 && index(saved.settings.smart_detect_exclude,"keep.example") >= 0, "manual exclusions retained");
check(length(saved.vpn.user_domains) == 2 && saved.vpn.user_domains[0] == "manual.example" && saved.vpn.user_domains[1] == "other.example" && saved.vpn.user_domains_text == "legacy.example\n", "only automatic entry removed, legacy text retained");
check(actions.apply(command(id,"exclude"), "42", 7).key == "sd_obsolete", "repeated callback never mutates twice");
check(length(actions.keyboard(id,k=>k)) == 1, "completed row removed, remaining row kept");
check(actions.apply(command(id,"undo",1), "42", 7).changed, "remaining batch action uses updated receipt");
check(length(actions.keyboard(id,k=>k)) == 0, "completed keyboard cleared");
reset("0"); id = receipt();
result = actions.apply(command(id,"exclude"), "42", 7);
check(result.domain == "api.site.co.uk" && index(saved.settings.smart_detect_exclude,"site.co.uk") < 0, "disabled expansion keeps subdomain");
reset("1"); id = receipt();
saved.settings.smart_detect_expand_to_root = "0";
check(actions.apply(command(id,"exclude"),"42",7).domain == "api.site.co.uk", "current expansion setting used at click time");
reset("1"); id = receipt();
let before = sprintf("%J",saved);
saved.vpn.user_domains = ["manual.example","site.co.uk","changed.example"];
let edited = sprintf("%J",saved);
check(actions.apply(command(id,"undo"),"42",7).key == "sd_obsolete" && sprintf("%J",saved) == edited, "edited rule list preserved");
reset("1"); id = receipt(); commit_ok = false;
before = sprintf("%J",saved);
check(actions.apply(command(id,"undo"),"42",7).key == "sd_failed" && sprintf("%J",saved) == before, "failed commit not reported as success");
commit_ok = true;
check(actions.apply(command(id,"undo"),"42",7).changed, "failed commit can be retried");
check(index(saved.settings.smart_detect_exclude,"site.co.uk") < 0, "undo does not create permanent exclusion");
reset("1"); id = receipt(); set_ok = false;
check(actions.apply(command(id,"undo"),"42",7).key == "sd_failed", "failed set is not committed");
set_ok = true;
let path = STATE_DIR + "/" + id + ".json";
let expired = json(fs.readfile(path)); expired.created = time()-86401; fs.writefile(path,sprintf("%J",expired));
check(actions.apply(command(id,"undo"),"42",7).key == "sd_obsolete", "expired receipt rejected");
check(actions.apply("/sd undo ../../etc/passwd 0","42",7).key == "sd_obsolete", "path traversal rejected");
check(actions.create([{section:"vpn",domain:"manual.example",snapshot:"outdated"}],"42") == null, "delivery drift cannot claim ownership");
reset("1"); saved.vpn.user_domains = ["site.co.uk"]; id = receipt();
check(actions.apply(command(id,"undo"),"42",7).changed && saved.vpn.user_domains == null, "last automatic entry deletes empty list option");
reset("1"); saved.vpn.user_domains = "site.co.uk"; id = receipt();
check(actions.apply(command(id,"undo"),"42",7).changed && saved.vpn.user_domains == null, "scalar UCI domain value supported");
reset("1"); id = receipt(); delete saved.vpn;
check(actions.apply(command(id,"undo"),"42",7).key == "sd_obsolete", "deleted section not recreated by stale button");
// Exercise the actual bot send and polling paths without contacting Telegram.
let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let escape_html = value => value;
let i18n = require("service.i18n");
let t = i18n.bind("ru");
let BIN_PATH = "/fixture/tachyon";
let OFFSET_FILE = STATE_DIR + "/offset";
let batch = [];
let calls = [];
let messages = [];
let quiet = false;
let reload_ok = true;
let reloads = 0;
let botcfg = { enabled: "1", bot_token: "fixture", admin_ids: "42", language: "ru" };
function settings() { return botcfg; }
function in_quiet_hours() { return quiet; }
function is_admin(id, admins) { return index(split(admins,","),""+id) >= 0; }
function tg_request(token, method, payload) {
    push(calls, {method,payload});
    return method == "getUpdates" ? {ok:true,result:batch} : {ok:true,result:{}};
}
function send_message(token,chat,text,mode,keyboard) {
    push(messages,{chat,text,keyboard});
    return {ok:true,result:{message_id:7}};
}
function command_success_from_args(args) {
    if (args[0] == BIN_PATH) {
        check(calls[length(calls)-2]?.method == "answerCallbackQuery", "callback answered before reload");
        reloads++;
        return reload_ok;
    }
    return true;
}
function dispatch_command() { die("Smart Detect callback escaped its handler\n"); }
let fixture_actions = actions;
/* RUNTIME */
reset("1");
let section = saved.vpn;
let entries = [{section:"vpn",domain:"site.co.uk",source_domain:"api.site.co.uk",snapshot:sprintf("%J",[section.user_domains,section.user_domains_text])}];
check(send_api("🔍 Smart Detect fixture",entries) == 0 && length(messages) == 1, "notification delivered once");
check(messages[0].keyboard[0][0].text == "В исключение" && messages[0].keyboard[0][1].text == "Отменить", "localized buttons attached by send_api");
let callback = messages[0].keyboard[0][0].callback_data;
function poll(sender, chat, message, data) {
    calls = [];
    batch = [{update_id:100,callback_query:{id:"fixture-callback",from:{id:sender},message:{message_id:message,chat:{id:chat}},data}}];
    check(process_updates("fixture","42,-100"), "poll handled");
}
let initial_commits = commits;
poll(99,42,7,callback);
check(commits == initial_commits && calls[1].payload.text == "Access Denied", "unauthorized sender cannot mutate allowed chat");
poll(42,-100,7,callback);
check(commits == initial_commits && reloads == 0, "forwarded callback cannot mutate different chat");
poll(42,42,8,callback);
check(commits == initial_commits && reloads == 0, "wrong message cannot mutate");
poll(42,42,7,callback);
check(commits == initial_commits+1 && reloads == 1, "authorized callback commits and reloads once");
check(calls[2].method == "editMessageReplyMarkup" && length(calls[2].payload.reply_markup.inline_keyboard) == 0, "handled message loses completed buttons");
poll(42,42,7,callback);
check(commits == initial_commits+1 && reloads == 1, "replayed Telegram update causes no second change");
quiet = true; let sent = length(messages);
send_api("fixture",entries);
check(length(messages) == sent, "quiet hours preserved");
quiet = false;
send_api("ordinary notification");
check(messages[length(messages)-1].keyboard == null, "ordinary notifications unchanged");
reset("0");
section = saved.vpn;
entries[0].snapshot = sprintf("%J",[section.user_domains,section.user_domains_text]);
send_api("reload failure fixture",entries);
callback = messages[length(messages)-1].keyboard[0][1].callback_data;
reload_ok = false;
poll(42,42,7,callback);
check(messages[length(messages)-1].text == t("sd_reload_failed"), "reload failure reported separately from saved action");
print(sprintf("PASS: %d Smart Detect notification action checks\n",checks));
