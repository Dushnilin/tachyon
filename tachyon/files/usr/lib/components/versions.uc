#!/usr/bin/env ucode
//
// Version comparison, extraction and normalization for component updates.
//
// Pure layer on top of components/helpers.uc: no global state, no side
// effects beyond spawning helper/module subprocesses.
//

let common = require("core.common");

let helpers = require("components.helpers");

let as_string = common.as_string;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let command_from_args = common.command_from_args;
let command_env = helpers.command_env;
let command_output_lenient = helpers.command_output_lenient;

// ============================================================================
// Comparison
// ============================================================================

function compare_versions(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);
    if (lhs == "" || rhs == "")
        return null;
    if (lhs == rhs)
        return 0;

    if (helpers.is_apk()) {
        let apk_result = trim(command_output_from_args([ "apk", "version", "-t", lhs, rhs ]));
        if (apk_result == ">")
            return 1;
        if (apk_result == "<")
            return -1;
        if (apk_result == "=")
            return 0;
    }

    if (helpers.command_exists("opkg")) {
        if (command_success_from_args([ "opkg", "compare-versions", lhs, ">", rhs ]))
            return 1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "<", rhs ]))
            return -1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "=", rhs ]))
            return 0;
    }

    return helpers.module_success([ helpers.LIB_DIR + "/core/helpers.uc", "version-at-least", lhs, rhs ]) ? 1 : -1;
}

function status_from_compare(compare_result) {
    if (compare_result == -1)
        return "outdated";
    if (compare_result == 0)
        return "latest";
    if (compare_result == 1)
        return "dev";
    return "";
}

// ============================================================================
// Installed / available versions
// ============================================================================

function installed_package_version(package_name) {
    package_name = as_string(package_name);
    if (helpers.is_apk()) {
        if (!helpers.pkg_is_installed(package_name))
            return "";
        return trim(helpers.module_output([ helpers.LIB_DIR + "/core/packages.uc", "apk-version", package_name ]));
    }
    return trim(helpers.module_output([ helpers.LIB_DIR + "/core/packages.uc", "opkg-version", package_name ]));
}

function opkg_package_version_from_list(package_name, output) {
    return trim(helpers.helper_output_input(output, "updates-opkg-package-version", [ package_name ]));
}

function available_package_version(package_name) {
    package_name = as_string(package_name);
    if (helpers.is_apk())
        return trim(helpers.module_output([ helpers.LIB_DIR + "/core/packages.uc", "apk-available-version", package_name ]));
    return opkg_package_version_from_list(package_name, command_output_from_args([ "opkg", "list", package_name ]));
}

function extract_arch_package_version(package_name, package_arch) {
    return trim(helpers.helper_output("updates-arch-package-version", [ package_name, package_arch ]));
}

function extract_zapret_bundle_version(bundle_name) {
    return trim(helpers.helper_output("updates-zapret-bundle-version", [ bundle_name ]));
}

function extract_zapret2_bundle_version(bundle_name) {
    return trim(helpers.helper_output("updates-zapret2-bundle-version", [ bundle_name ]));
}

function normalize_zapret_version(value) {
    return trim(helpers.helper_output("updates-normalize-zapret-version", [ value ]));
}

function normalize_sing_box_version(value) {
    return trim(helpers.helper_output("updates-normalize-sing-box-version", [ value ]));
}

// ============================================================================
// sing-box binary version parsing
// ============================================================================

function extract_sing_box_version_from_output(output) {
    output = as_string(output);
    for (let line in split(output, "\n")) {
        line = trim(line);
        let fields = split(line, /[ \t\r\n]+/);
        if (length(fields) >= 3 && lc(fields[0]) == "sing-box" && lc(fields[1]) == "version")
            return fields[2];
        if (length(fields) >= 2 && lc(fields[0]) == "version")
            return fields[1];
    }
    return "";
}

function read_sing_box_binary_version(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !helpers.file_exists(binary)) {
        helpers.updates_log("sing-box binary not found at " + binary, "warn");
        return "";
    }

    command_success_from_args([ "chmod", "0755", binary ]);

    let command = command_from_args([ binary, "version" ]);
    let lib_path = as_string(library_dir || "");
    if (lib_path != "") {
        if (lib_path == "/usr/lib")
            lib_path = "/usr/lib:/lib";
        else
            lib_path = lib_path + ":/usr/lib:/lib";
        command = command_env({ LD_LIBRARY_PATH: lib_path }) + " " + command;
    }

    let raw_output = command_output_lenient("(" + command + ") 2>&1");
    let version = extract_sing_box_version_from_output(raw_output);
    if (version == "")
        version = trim(helpers.helper_output_input(raw_output, "stdin-first-line-last-field", []));
    if (version == "") {
        let trimmed_raw = trim(raw_output);
        helpers.updates_log("Failed to parse sing-box version from binary " + binary + (trimmed_raw != "" ? "; output: " + trimmed_raw : "; binary produced no output"), "warn");
    }
    return version;
}

// Forward-referenced helpers

function module_exports() {
    return {
        compare_versions,
        status_from_compare,
        installed_package_version,
        opkg_package_version_from_list,
        available_package_version,
        extract_arch_package_version,
        extract_zapret_bundle_version,
        extract_zapret2_bundle_version,
        normalize_zapret_version,
        normalize_sing_box_version,
        extract_sing_box_version_from_output,
        read_sing_box_binary_version
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/versions.uc (library module, no CLI)\n");
exit(1);
