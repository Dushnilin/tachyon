let fs=require("fs");
let source=fs.readfile(ARGV[0]);
let template=fs.readfile(ARGV[1]);
let begin=index(source,"let smart_detect_dns_state = {};");
let end=index(source,"// ─── OOM response",begin);
if(begin<0 || end<begin)die("Smart Detect source boundaries not found\n");
if(!fs.writefile(ARGV[2],replace(template,"/* IMPLEMENTATION */",substr(source,begin,end-begin))))
    die("Could not write isolated fixture\n");
