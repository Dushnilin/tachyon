#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATUS_UC = LIB_DIR + "/diagnostics/status.uc";

let as_string = common.as_string;
let command_from_args = common.command_from_args;
let command_capture = common.command_capture;
let command_status = common.command_status;

function normalize_status(status) {
    status = int(status);
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function status_command(args) {
    let full = [ "ucode", "-L", LIB_DIR, STATUS_UC ];
    for (let a in args) push(full, as_string(a));
    return command_from_args(full);
}

// status.uc reads its input from stdin. A write-only pipe opened with the "w" mode delivers the
// input but sends the child's stdout to ours, so the caller got an empty
// string; and status_output() then ran the command a second time with no
// stdin at all. A temp file redirected into stdin keeps one process, one
// stdin and a captured stdout.
function with_stdin_file(input, run) {
    let stamp = clock();
    let path = sprintf("/tmp/tachyon-status-in.%d.%d.%d", time(), stamp[0], stamp[1]);
    if (fs.writefile(path, as_string(input)) == null)
        return null;
    fs.chmod(path, 0600);
    let result = run(" < " + common.shell_quote(path));
    fs.unlink(path);
    return result;
}

function status_capture(args, input) {
    let cmd = status_command(args);
    if (input != null) {
        let res = with_stdin_file(input, (redirect) => command_capture(cmd + redirect));
        return res || { status: 1, output: "" };
    }
    return command_capture(cmd);
}

function status_output(args, input) {
    let res = status_capture(args, input);
    return res.status == 0 ? res.output : "";
}

function status_success(args, input) {
    if (input != null)
        return status_capture(args, input).status == 0;
    return command_status(status_command(args)) == 0;
}


return {
    normalize_status,
    status_capture,
    status_output,
    status_success
};
