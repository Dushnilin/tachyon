// One isolated, bounded probe worker. Only the watchdog may apply its result.
let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let plus = require("service.smart_detect_plus");
let detect = require("service.smart_detect");
const LIB = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const DIR = getenv("TACHYON_SMART_PROBE_DIR") || "/var/run/tachyon/smart-probe";

function remove(path) { try { fs.unlink(path); } catch (e) {} }
function save(path, value) {
    let tmp = path + ".tmp";
    if (!common.write_json_file(tmp, value)) return false;
    fs.chmod(tmp, 0600);
    return fs.rename(tmp, path);
}
function group_members(job) {
    if (!job?.identity || !exec.identity_matches(job.identity, job.identity.pid)) return [];
    let pid = common.as_string(job.identity.pid);
    let raw = fs.readfile("/proc/" + pid + "/cmdline") || "";
    if (index(raw, LIB + "/service/smart_detect_probe.uc") < 0 || index(raw, job.id) < 0) return [];
    let stat = fs.readfile("/proc/" + pid + "/stat") || "";
    let marker = rindex(stat, ") ");
    if (marker < 0 || split(substr(stat, marker + 2), " ")[2] != pid) return [];
    let members = [], directory = fs.opendir("/proc"), entry;
    while ((entry = directory.read()) != null) {
        if (!match(entry, /^[0-9]+$/)) continue;
        stat = fs.readfile("/proc/" + entry + "/stat") || "";
        marker = rindex(stat, ") ");
        if (marker >= 0 && split(substr(stat, marker + 2), " ")[2] == pid)
            push(members, exec.make_identity(entry, "smart-probe"));
    }
    directory.close();
    return members;
}
function stop(job) {
    let members = group_members(job);
    if (length(members)) {
        common.command_success_from_args(["kill", "-TERM", "--", "-" + job.identity.pid]);
        sleep(100);
        for (let identity in members)
            if (exec.identity_matches(identity, identity.pid))
                common.command_success_from_args(["kill", "-KILL", identity.pid]);
    }
    for (let name in ["request.json", "result.json", "job.json", "result.json.tmp", "request.json.tmp", "job.json.tmp"])
        remove(DIR + "/" + name);
}
function cleanup() { stop(common.read_json_file(DIR + "/job.json")); }
function start(request) {
    if (plus.normalize_domain(request?.domain) != request?.domain || type(request.direct_flags) != "array") return null;
    cleanup();
    common.command_success_from_args(["mkdir", "-p", DIR]);
    fs.chmod(DIR, 0700);
    let stamp = clock(), id = sprintf("%d-%d", stamp[0], stamp[1]);
    request = {...request, id};
    if (!save(DIR + "/request.json", request)) return null;
    let process = exec.run_background({
        argv: ["setsid", "ucode", "-L", LIB, "-L", "/usr/lib/tachyon", LIB + "/service/smart_detect_probe.uc", "probe-worker", id],
        env: {TACHYON_LIB: LIB, TACHYON_SMART_PROBE_DIR: DIR}, name: "smart-probe"
    });
    let job = {id, identity: process.identity, started: time()};
    if (!process.identity || !save(DIR + "/job.json", job)) { stop(job); return null; }
    return job;
}
function poll(job) {
    let result = common.read_json_file(DIR + "/result.json");
    if (result?.id == job?.id && type(result.decision) == "object") return result.decision;
    if (time() - int(job?.started || 0) > 35 || !exec.identity_alive(job?.identity)) return {defer:true};
    return null;
}
function worker(id) {
    let request = common.read_json_file(DIR + "/request.json");
    if (request?.id != id) return 1;
    let decision = {defer:true};
    try {
        decision = plus.probe(request.domain, request.item, request.proxy_addr,
            request.direct_flags, detect.probe_status);
    } catch (e) {}
    return save(DIR + "/result.json", {id, decision}) ? 0 : 1;
}
if ((sourcepath(1) == null || sourcepath(1) == "") && ARGV[0] == "probe-worker") exit(worker(ARGV[1]));
return {start, poll, stop, cleanup};
