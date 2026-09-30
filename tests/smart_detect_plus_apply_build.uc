let fs = require("fs");
let source = fs.readfile(ARGV[0]);
let start = index(source, "let smart_plus_reload_pending = false;");
let end = index(source, "function smart_detect_apply_domains", start);
if (start < 0 || end < start) die("Apply boundaries missing\n");
fs.writefile(ARGV[2], replace(fs.readfile(ARGV[1]), "/* IMPLEMENTATION */", substr(source,start,end-start)));
