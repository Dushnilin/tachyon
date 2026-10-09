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

// Drops the field sing-box named from the outbound it named, and reports whether
// anything changed.
//
// The apply path in singbox/runtime.uc calls this same function now, because its
// inlined copy drifted into a crash (to_string does not exist in ucode) that took
// the whole start down on the first rejected field, while this copy stayed tested.
// It is the reason a build that rejects one field can still run: only the offending
// outbound loses it, because deleting it everywhere threw away settings that were
// working. The pre-flight needs the same repair, or a binary that rejects a single
// field is refused outright and the user is told the variant is "incompatible" when
// the truth is that one key could have been dropped.
//
// Reports false once no further repair applies, so the caller stops instead of
// rewriting the same file until it gives up.
function repair_unknown_outbound_field(config_file, reason) {
    let out_m = match(as_string(reason), /outbounds\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let ep_m = match(as_string(reason), /endpoints\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let inb_m = match(as_string(reason), /inbounds\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);

    let m = out_m || ep_m || inb_m;
    if (!m || !m[1] || !m[2]) return false;

    let field = m[2];
    let index = int(m[1]);
    if (index < 0) return false;

    let cfg_text = as_string(fs.readfile(config_file) || "");
    if (length(cfg_text) == 0) return false;

    let cfg = json(cfg_text);
    if (type(cfg) != "object") return false;

    let target = null;
    if (out_m) {
        if (type(cfg.outbounds) != "array" || index >= length(cfg.outbounds)) return false;
        target = cfg.outbounds[index];
    } else if (ep_m) {
        if (type(cfg.endpoints) != "array" || index >= length(cfg.endpoints)) return false;
        target = cfg.endpoints[index];
    } else if (inb_m) {
        if (type(cfg.inbounds) != "array" || index >= length(cfg.inbounds)) return false;
        target = cfg.inbounds[index];
    }
    if (type(target) != "object") return false;

    let parts = split(field, ".");
    let leaf = parts[length(parts) - 1];
    for (let step = 0; step < length(parts) - 1; step++) {
        if (type(target) != "object") return false;
        target = target[parts[step]];
    }

    if (type(target) != "object" || target[leaf] == null) return false;

    if (ep_m && leaf == "amnezia" && type(target.amnezia) == "object") {
        for (let k, v in target.amnezia) {
            if (target[k] == null)
                target[k] = v;
        }
    }

    delete target[leaf];
    fs.writefile(config_file, sprintf("%J", cfg));
    return true;
}

function check_sing_box_config_with_binary(binary, config_path, library_dir, target_variant) {
    binary = as_string(binary);
    if (binary == "" || !helpers.file_exists(binary))
        return { ok: false, reason: "sing-box binary not found at " + binary };

    helpers.init_tmp_dir();
    let err_file = helpers.make_tmp_file("sb-chk");
    if (err_file == "")
        return { ok: true };

    let env_map = {
        GODEBUG: "madvdontneed=1",
        GOGC: "30"
    };
    let lib_path = as_string(library_dir || "");
    if (lib_path != "") {
        if (lib_path == "/usr/lib")
            lib_path = "/usr/lib:/lib";
        else
            lib_path = lib_path + ":/usr/lib:/lib";
        env_map.LD_LIBRARY_PATH = lib_path;
    }

    let ver_out = trim(common.command_output_from_args([ binary, "version" ]));
    let ver_str = common.parse_sing_box_version(ver_out);

    let active_variant_file = getenv("SB_VARIANT_STATE_FILE") || "/etc/tachyon/sing-box-variant";
    let active_variant = trim(fs.readfile(active_variant_file) || "");
    let target_var = as_string(target_variant || "");
    if (target_var == "") {
        if (index(ver_out, "tachyon-core") >= 0 || index(ver_str, "-tachyon.") >= 0)
            target_var = "tachyon-core";
        else if (index(ver_str, "-lx") >= 0)
            target_var = "lx";
        else if (index(ver_str, "extended") >= 0)
            target_var = "extended";
        else
            target_var = active_variant != "" ? active_variant : "stable";
    }

    let is_variant_switch = (target_var != "" && active_variant != "" && target_var != active_variant);

    config_path = as_string(config_path || "/etc/sing-box/config.json");

    // When changing core/variant, the existing config on disk was built for the
    // old variant/core and may contain incompatible options (e.g. endpoints[0].amnezia).
    // Configs must be regenerated for the target variant and checked only after regeneration.
    if (!is_variant_switch && helpers.file_exists(config_path) && helpers.file_nonempty(config_path)) {
        let check_cmd = helpers.command_env(env_map) + " " +
            common.command_from_args([ binary, "-c", config_path, "check" ]) +
            " >" + common.shell_quote(err_file) + " 2>&1";
        let status = common.command_status(check_cmd);
        if ((status == 247 || status == 137) && fs.stat("/proc/sys/vm/drop_caches") != null) {
            system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null");
            env_map.GOGC = "15";
            check_cmd = helpers.command_env(env_map) + " " +
                common.command_from_args([ binary, "-c", config_path, "check" ]) +
                " >" + common.shell_quote(err_file) + " 2>&1";
            status = common.command_status(check_cmd);
        }

        if (status == 0) {
            helpers.remove_file(err_file);
            return { ok: true };
        }
    }

    let candidate_cfg = helpers.make_tmp_file("sb-cand");
    let version_file = helpers.make_tmp_file("sb-cand-ver");
    let variant_file = helpers.make_tmp_file("sb-cand-var");
    let cand_status = -1;
    if (candidate_cfg != "" && version_file != "") {
        fs.writefile(version_file, ver_str + "\n");
        if (variant_file != "")
            fs.writefile(variant_file, target_var + "\n");
        let gen_env = {
            SB_PREFLIGHT_BINARY: binary,
            SB_VERSION_OVERRIDE: ver_str,
            SB_VERSION_STATE_FILE: version_file,
            RECORD_FLASH_WEAR: "0"
        };
        if (variant_file != "")
            gen_env.SB_VARIANT_STATE_FILE = variant_file;
        if (lib_path != "")
            gen_env.LD_LIBRARY_PATH = lib_path;
        let gen_cmd = helpers.command_env(gen_env) + " " +
            common.command_from_args([
                "ucode", "-L", helpers.LIB_DIR, helpers.LIB_DIR + "/singbox/generator.uc",
                "generate-config", candidate_cfg, "127.0.0.1", "0", "0", ""
            ]) + " >/dev/null 2>&1";
        if (common.command_status(gen_cmd) == 0 && helpers.file_nonempty(candidate_cfg)) {
            let repaired = false;
            for (let attempt = 0; attempt < 4; attempt++) {
                let cand_check_cmd = helpers.command_env(env_map) + " " +
                    common.command_from_args([ binary, "-c", candidate_cfg, "check" ]) +
                    " >" + common.shell_quote(err_file) + " 2>&1";
                cand_status = common.command_status(cand_check_cmd);
                if (cand_status == 0) {
                    repaired = true;
                    break;
                }
                let cand_reason = "";
                for (let line in split(as_string(helpers.read_file(err_file)), "\n")) {
                    line = trim(line);
                    if (line != "") { cand_reason = line; break; }
                }
                if (!repair_unknown_outbound_field(candidate_cfg, cand_reason)) {
                    repaired = false;
                    break;
                }
                helpers.updates_log("Pre-flight: the candidate sing-box rejected a field, retrying without it", "warn");
            }
            helpers.remove_file(candidate_cfg);
            helpers.remove_file(version_file);
            if (variant_file != "") helpers.remove_file(variant_file);
            if (repaired) {
                helpers.remove_file(err_file);
                return { ok: true };
            }
        } else {
            helpers.remove_file(candidate_cfg);
            helpers.remove_file(version_file);
            if (variant_file != "") helpers.remove_file(variant_file);
        }
    }

    let raw = helpers.read_file(err_file);
    helpers.remove_file(err_file);

    let reason = "";
    for (let line in split(raw, "\n")) {
        line = trim(line);
        if (line != "") {
            reason = line;
            break;
        }
    }
    if (reason == "") {
        if (cand_status == 247 || cand_status == 137)
            reason = "Out of memory (OOM killed, exit status " + cand_status + ")";
        else
            reason = "exit status " + cand_status;
    }

    helpers.updates_log("Pre-flight check failed: binary " + binary + " rejected config for " + target_var + ": " + reason, "error");
    return { ok: false, reason: reason };
}

// Forward-referenced helpers

function module_exports() {
    return {
        format_fingerprint_human,
        repair_unknown_outbound_field,
        verify_package_post_install,
        verify_binary_post_install,
        validate_sing_box_extended_binary,
        check_sing_box_config_with_binary
    };
}

return module_exports();
