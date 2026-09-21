#!/usr/bin/env ucode
//
// Post-install verification for components: binary presence, version reads,
// sing-box extended binary validation and human-readable fingerprints.
//

let fs = require("fs");
let common = require("core.common");

let helpers = require("components.helpers");
let versions = require("components.versions");

let as_string = common.as_string;

// ============================================================================
// Fingerprints
// ============================================================================

function format_fingerprint_human(fp) {
    fp = as_string(fp);
    if (helpers.str_startswith(fp, "sha:"))
        return substr(fp, 4, 7);
    if (!helpers.str_startswith(fp, "build:"))
        return fp != "" ? fp : "unknown";
    let body = substr(fp, 6);
    let pairs = split(body, "|");
    let upd = "";
    let size = "";
    for (let p in pairs) {
        if (helpers.str_startswith(p, "upd="))
            upd = substr(p, 4);
        else if (helpers.str_startswith(p, "pub=") && upd == "")
            upd = substr(p, 4);
        else if (helpers.str_startswith(p, "size="))
            size = substr(p, 5);
    }
    let parts = [];
    if (upd != "") {
        let d = match(upd, /^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})/);
        if (d && d[1] && d[2])
            push(parts, d[1] + " " + d[2] + " UTC");
        else
            push(parts, upd);
    }
    if (size != "") {
        let kb = int(int(size) / 1024);
        if (kb > 0)
            push(parts, kb + " KB");
    }
    return length(parts) > 0 ? ("build (" + join(", ", parts) + ")") : fp;
}

// ============================================================================
// Post-install verification
// ============================================================================

function verify_package_post_install(package_name, expected_version) {
    let db_version = versions.installed_package_version(package_name);
    if (db_version == "") {
        helpers.updates_log("Post-install verification failed: " + package_name + " not found in package database", "error");
        return false;
    }
    if (as_string(expected_version) != "" && db_version != as_string(expected_version)) {
        helpers.updates_log("Post-install version mismatch for " + package_name +
            ": expected=" + as_string(expected_version) + " actual=" + db_version, "warn");
    }
    return true;
}

function verify_binary_post_install(binary_path, expected_version, version_cmd_args) {
    if (!helpers.file_exists(binary_path)) {
        helpers.updates_log("Post-install verification failed: binary not found at " + binary_path, "error");
        return false;
    }
    if (type(version_cmd_args) == "array" && length(version_cmd_args) > 0) {
        let actual = versions.read_sing_box_binary_version(binary_path, "");
        if (actual == "") {
            helpers.updates_log("Post-install verification: cannot read version from " + binary_path, "warn");
        } else if (as_string(expected_version) != "" && actual != as_string(expected_version)) {
            helpers.updates_log("Post-install binary version mismatch: expected=" + as_string(expected_version) + " actual=" + actual, "warn");
        }
    }
    return true;
}

function validate_sing_box_extended_binary(binary, library_dir, compressed) {
    let version = versions.read_sing_box_binary_version(binary, library_dir || "");
    if (version != "")
        return version;
    if (compressed) {
        let is_elf = false;
        try {
            let f = fs.open(binary, "r");
            if (f) {
                let header = f.read("4");
                f.close();
                is_elf = (header == "\x7fELF");
            }
        }
        catch (e) {}
        if (is_elf) {
            helpers.updates_log("Compressed binary validated via ELF header check: " + binary, "info");
            return "compressed";
        }
        helpers.updates_log("Compressed binary is not a valid ELF executable: " + binary, "warn");
    }
    return "";
}

// Forward-referenced helpers

function module_exports() {
    return {
        format_fingerprint_human,
        verify_package_post_install,
        verify_binary_post_install,
        validate_sing_box_extended_binary
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/verifier.uc (library module, no CLI)\n");
exit(1);
