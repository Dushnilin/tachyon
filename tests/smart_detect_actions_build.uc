let fs = require("fs");
let source = fs.readfile(ARGV[0]);
source = replace(source, 'let uci_core = require("core.uci");', 'let uci_core = fixture_uci;');
source = replace(source, 'return { create, bind_message, keyboard, apply };', 'let actions = { create, bind_message, keyboard, apply };');
let fixture = replace(fs.readfile(ARGV[1]), "/* IMPLEMENTATION */", source);
let runtime = fs.readfile(ARGV[3]);
let start = index(runtime, "function persist_offset(");
let end = index(runtime, "function worker(", start);
if (start < 0 || end < start) die("Telegram runtime boundaries missing\n");
let functions = substr(runtime, start, end - start);
functions = replace(functions, 'require("service.telegram.smart_detect_actions")', 'fixture_actions');
let send_start = index(runtime, "function send_api(");
let send_end = index(runtime, "function send_daily_digest(", send_start);
functions += replace(substr(runtime, send_start, send_end - send_start),
    'require("service.telegram.smart_detect_actions")', 'fixture_actions');
fs.writefile(ARGV[2], replace(fixture, "/* RUNTIME */", functions));
