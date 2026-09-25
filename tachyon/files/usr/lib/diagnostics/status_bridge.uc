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

function status_capture(args, input) {
    let full = [ "ucode", "-L", LIB_DIR, STATUS_UC ];
    for (let a in args) push(full, as_string(a));
    let cmd = command_from_args(full);
    if (input != null) {
        let pipe = fs.popen(cmd, "w");
        if (!pipe) return { status: 1, output: "" };
        pipe.write(as_string(input));
        let status = normalize_status(pipe.close());
        return { status, output: "" };
    }
    return command_capture(cmd);
}

function status_output(args, input) {
    let full = [ "ucode", "-L", LIB_DIR, STATUS_UC ];
    for (let a in args) push(full, as_string(a));
    let cmd = command_from_args(full);
    if (input != null) {
        let pipe = fs.popen(cmd, "w");
        if (pipe) {
            pipe.write(as_string(input));
            pipe.close();
        }
    }
    let res = command_capture(cmd);
    return res.status == 0 ? res.output : "";
}

function status_success(args, input) {
    let full = [ "ucode", "-L", LIB_DIR, STATUS_UC ];
    for (let a in args) push(full, as_string(a));
    let cmd = command_from_args(full);
    if (input != null) {
        let pipe = fs.popen(cmd, "w");
        if (pipe) {
            pipe.write(as_string(input));
            let status = normalize_status(pipe.close());
            return status == 0;
        }
        return false;
    }
    return command_status(cmd) == 0;
}

return {
    normalize_status,
    status_capture,
    status_output,
    status_success
};
