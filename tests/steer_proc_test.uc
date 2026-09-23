#!/usr/bin/env ucode
let fs = require("fs");

let provider_bin = "/opt/zapret2/nfq2/nfqws2";
let count = 0;
let proc_dir = fs.opendir("/proc");
if (proc_dir) {
    let entry;
    while ((entry = proc_dir.read()) != null) {
        if (!match(entry, /^[0-9]+$/))
            continue;
        let exe_path = "/proc/" + entry + "/exe";
        let link = null;
        try { link = fs.readlink(exe_path); } catch (e) {}
        if (link == provider_bin)
            count++;
    }
    proc_dir.close();
}
print("steer_process_count = " + count + "\n");

// Test steer table detection
let common = require("core.common");
let output = common.command_output("nft list table inet steer 2>/dev/null | head -3");
print("steer table exists = " + (trim(output) != "" ? "YES" : "NO") + "\n");
print("steer_manages = " + (trim(output) != "" && count > 0 ? "YES" : "NO") + "\n");
