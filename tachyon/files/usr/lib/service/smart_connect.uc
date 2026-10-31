// Lifecycle bridge. Probe/cache decisions stay entirely in the connector.
let fs=require("fs");
let common=require("core.common");
let uci=require("core.uci");
let engine=require("tachyon_core.smart_connect");
const CONFIG=getenv("TACHYON_CONFIG_NAME") || "tachyon";
const DIR=(getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/smart-connect";
const INIT="/etc/init.d/tachyon-smart-connect";

function stop() {
    if (fs.stat(INIT)) common.command_status_from_args([INIT,"stop"]);
    try {fs.unlink(DIR+"/config.json");} catch(e) {}
    try {fs.unlink(DIR+"/status.json");} catch(e) {}
}
function sync(prepare) {
    let cfg=uci.get_all(CONFIG,"settings") || {};
    // Keep an old helper alive until the old core has stopped referring to it.
    if (!engine.enabled(cfg)) { if (!prepare) stop();return true; }
    let core=common.read_json_file(cfg.config_path || "/etc/tachyon-core/config.json");
    if (!core) return false;
    let p=engine.plan(core,cfg,uci.section_objects(CONFIG,"section") || [],uci.section_objects(CONFIG,"outbound_source") || []);
    if (!p || p.error) {warn(p?.error || "Smart Connect unavailable","\n");return false;}
    if (!fs.stat("/usr/bin/tachyon-smart-connect") || !fs.stat(INIT)) {
        warn("Install the architecture-specific tachyon-smart-connect helper before enabling the chain\n");return false;
    }
    if (!common.command_success_from_args(["mkdir","-p",DIR])) return false;
    fs.chmod(DIR,0700);
    let path=DIR+"/config.json", tmp=path+".tmp";
    if (!common.write_json_file(tmp,p.helper)) return false;
    fs.chmod(tmp,0600);
    if (!common.command_success_from_args(["/usr/bin/tachyon-smart-connect","-check","-config",tmp])) {
        fs.unlink(tmp);return false;
    }
    if (!fs.rename(tmp,path)) return false;
    // A running helper reloads the atomic file in place. Calling `start` is
    // idempotent under procd and never restarts existing connections.
    if (!common.command_success_from_args([INIT,"start"])) return false;
    // procd start may return before the process is listening. Never redirect
    // the core to a helper still parsing the trust store or old configuration.
    for (let attempt=0;attempt<50;attempt++) {
        let ready=common.read_json_file(DIR+"/status.json");
        if (ready?.generation==p.helper.generation && ready?.pid>0 &&
            fs.readlink("/proc/"+ready.pid+"/exe")=="/usr/bin/tachyon-smart-connect")
            return true;
        common.command_status_from_args(["sleep","0.1"]);
    }
    warn("Smart Connect did not become ready before core activation\n");
    return false;
}
if ((sourcepath(1)==null || sourcepath(1)=="") && ARGV[0]) {
    if (ARGV[0]=="sync") exit(sync()?0:1);
    if (ARGV[0]=="prepare") exit(sync(true)?0:1);
    if (ARGV[0]=="stop") {stop();exit(0);}
    if (ARGV[0]=="status") { print(fs.readfile(DIR+"/status.json") || '{"entries":[],"pending":0}');print("\n");exit(0); }
    exit(1);
}
return {sync,stop};
