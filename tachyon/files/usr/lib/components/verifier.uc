#!/usr/bin/env ucode
//
// Post-install verification for components: binary presence, version reads,
// tachyon-core binary validation and human-readable fingerprints.
//

let fs = require("fs");
let common = require("core.common");

let helpers = require("components.helpers");
let versions = require("components.versions");
let core_profile_module = null;

let as_string = common.as_string;

// Lazy on purpose: components_updater_job.sh stages this module into a partial
// -L tree whose tachyon_core/ directory is created but left empty, to pin that
// component verification carries the profile lookup itself rather than
// inheriting it from a require graph.
function core_profile() {
    if (core_profile_module == null)
        core_profile_module = require("tachyon_core.core_profile");
    return core_profile_module;
}

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
        let actual = versions.read_core_binary_version(binary_path, "");
        if (actual == "") {
            helpers.updates_log("Post-install verification: cannot read version from " + binary_path, "warn");
        } else if (as_string(expected_version) != "" && actual != as_string(expected_version)) {
            helpers.updates_log("Post-install binary version mismatch: expected=" + as_string(expected_version) + " actual=" + actual, "warn");
        }
    }
    return true;
}

// Drops the field tachyon-core named from the outbound it named, and reports whether
// anything changed.
//
// The apply path in tachyon_core/runtime.uc calls this same function now, because its
// inlined copy drifted into a crash (to_string does not exist in ucode) that took
// the whole start down on the first rejected field, while this copy stayed tested.
// It is the reason a build that rejects one field can still run: only the offending
// outbound loses it, because deleting it everywhere threw away settings that were
// working. The pre-flight needs the same repair, or a binary that rejects a single
// field is refused outright and the user is told the core build is "incompatible" when
// the truth is that one key could have been dropped.
//
// Reports false once no further repair applies, so the caller stops instead of
// rewriting the same file until it gives up.
function normalize_unknown_field_reason(reason) {
    let s = replace(as_string(reason), /: (json: )*unknown field /g, ": json: unknown field ");
    s = replace(s, /(^|: )(log|ntp|route|dns): ([A-Za-z0-9_.]+): json: unknown field /g, "$1$2.$3: json: unknown field ");
    return s;
}

function repair_unknown_outbound_field(config_file, reason) {
    let norm_reason = normalize_unknown_field_reason(reason);
    if (index(as_string(reason), "unknown log level: panic") >= 0) {
        let cfg_text = as_string(fs.readfile(config_file) || "");
        if (length(cfg_text) == 0) return false;
        let cfg = json(cfg_text);
        if (type(cfg) == "object" && type(cfg.log) == "object" && cfg.log.level == "panic") {
            cfg.log.level = "fatal";
            fs.writefile(config_file, sprintf("%J", cfg));
            return true;
        }
    }

    let ep_peer_m = match(norm_reason, /endpoints\[(\d+)\]\.peers\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    if (ep_peer_m && ep_peer_m[1] && ep_peer_m[2] && ep_peer_m[3]) {
        let ep_idx = int(ep_peer_m[1]);
        let peer_idx = int(ep_peer_m[2]);
        let field = ep_peer_m[3];
        if (ep_idx < 0 || peer_idx < 0) return false;
        let cfg_text = as_string(fs.readfile(config_file) || "");
        if (length(cfg_text) == 0) return false;
        let cfg = json(cfg_text);
        if (type(cfg) != "object" || type(cfg.endpoints) != "array" || ep_idx >= length(cfg.endpoints))
            return false;
        let ep = cfg.endpoints[ep_idx];
        if (type(ep) != "object" || type(ep.peers) != "array" || peer_idx >= length(ep.peers))
            return false;
        let target = ep.peers[peer_idx];
        if (type(target) != "object" || target[field] == null)
            return false;
        delete target[field];
        fs.writefile(config_file, sprintf("%J", cfg));
        return true;
    }

    let rrule_m = match(norm_reason, /route\.rules\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let drule_m = match(norm_reason, /dns\.rules\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let dsrv_m = match(norm_reason, /dns\.servers\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let sub_m = rrule_m || drule_m || dsrv_m;
    if (sub_m && sub_m[1] && sub_m[2]) {
        let idx = int(sub_m[1]);
        let field = sub_m[2];
        if (idx < 0) return false;
        let cfg_text = as_string(fs.readfile(config_file) || "");
        if (length(cfg_text) == 0) return false;
        let cfg = json(cfg_text);
        if (type(cfg) != "object") return false;
        let arr = null;
        if (rrule_m) {
            if (type(cfg.route) != "object" || type(cfg.route.rules) != "array" || idx >= length(cfg.route.rules))
                return false;
            arr = cfg.route.rules;
        } else if (drule_m) {
            if (type(cfg.dns) != "object" || type(cfg.dns.rules) != "array" || idx >= length(cfg.dns.rules))
                return false;
            arr = cfg.dns.rules;
        } else if (dsrv_m) {
            if (type(cfg.dns) != "object" || type(cfg.dns.servers) != "array" || idx >= length(cfg.dns.servers))
                return false;
            arr = cfg.dns.servers;
        }
        let target = arr[idx];
        if (type(target) != "object") return false;
        let parts = split(field, ".");
        let leaf = parts[length(parts) - 1];
        for (let step = 0; step < length(parts) - 1; step++) {
            if (type(target) != "object") return false;
            target = target[parts[step]];
        }
        if (type(target) != "object" || target[leaf] == null) return false;
        delete target[leaf];
        if (rrule_m || drule_m) {
            let rule_obj = arr[idx];
            let non_matcher = rrule_m
                ? { action: true, outbound: true, server: true, strategy: true, override_address: true, override_port: true, method: true, no_drop: true, sniffer: true, timeout: true, inbound: true }
                : { action: true, server: true, strategy: true, rewrite_ttl: true, client_subnet: true, disable_cache: true, rcode: true, answer: true, ns: true, extra: true, method: true, no_drop: true };
            let has_matcher = false;
            for (let k in keys(rule_obj)) {
                if (!non_matcher[k]) {
                    has_matcher = true;
                    break;
                }
            }
            if (!has_matcher)
                splice(arr, idx, 1);
        }
        fs.writefile(config_file, sprintf("%J", cfg));
        return true;
    }

    let out_m = match(norm_reason, /outbounds\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let ep_m = match(norm_reason, /endpoints\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);
    let inb_m = match(norm_reason, /inbounds\[(\d+)\]\.([A-Za-z0-9_.]+): json: unknown field/);

    let m = out_m || ep_m || inb_m;
    if (m && m[1] && m[2]) {
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

    let gen_m = match(norm_reason, /([A-Za-z0-9_.]+): json: unknown field/);
    if (gen_m && gen_m[1]) {
        let field = gen_m[1];
        let cfg_text = as_string(fs.readfile(config_file) || "");
        if (length(cfg_text) == 0) return false;
        let cfg = json(cfg_text);
        if (type(cfg) != "object") return false;

        let parts = split(field, ".");
        let target = cfg;
        let leaf = parts[length(parts) - 1];
        for (let step = 0; step < length(parts) - 1; step++) {
            if (type(target) != "object") return false;
            target = target[parts[step]];
        }
        if (type(target) == "object" && target[leaf] != null) {
            delete target[leaf];
            fs.writefile(config_file, sprintf("%J", cfg));
            return true;
        }
    }

    return false;
}

function check_core_config_with_binary(binary, config_path, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !helpers.file_exists(binary))
        return { ok: false, reason: "tachyon-core binary not found at " + binary };

    helpers.init_tmp_dir();
    let err_file = helpers.make_tmp_file("core-chk");
    if (err_file == "")
        return { ok: true };

    let env_map = {};
    let lib_path = as_string(library_dir || "");
    if (lib_path != "") {
        if (lib_path == "/usr/lib")
            lib_path = "/usr/lib:/lib";
        else
            lib_path = lib_path + ":/usr/lib:/lib";
        env_map.LD_LIBRARY_PATH = lib_path;
    }
    let env_prefix = helpers.command_env(env_map);
    let env_space = env_prefix != "" ? env_prefix + " " : "";

    let ver_out = trim(common.command_output_from_args([ binary, "version" ]));
    let ver_str = common.parse_core_version(ver_out);
    if (ver_str == "") {
        helpers.remove_file(err_file);
        helpers.updates_log("Pre-flight check failed: binary " + binary + " is invalid or unable to report version", "error");
        return { ok: false, reason: "binary unable to report version" };
    }

    config_path = as_string(config_path || "/etc/tachyon-core/config.json");

    if (helpers.file_exists(config_path) && helpers.file_nonempty(config_path)) {
        let check_cmd = env_space +
            common.command_from_args([ binary, "-c", config_path, "check" ]) +
            " >" + common.shell_quote(err_file) + " 2>&1";
        let status = common.command_status(check_cmd);
        if ((status == 247 || status == 137) && fs.stat("/proc/sys/vm/drop_caches") != null) {
            system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null");
            status = common.command_status(check_cmd);
        }

        if (status == 0) {
            helpers.remove_file(err_file);
            return { ok: true };
        }
    }

    let candidate_cfg = helpers.make_tmp_file("core-cand");
    let version_file = helpers.make_tmp_file("core-cand-ver");
    let cand_status = -1;
    if (candidate_cfg != "" && version_file != "") {
        fs.writefile(version_file, ver_str + "\n");
        let gen_env = {
            TACHYON_CORE_PREFLIGHT_BINARY: binary,
            TACHYON_CORE_VERSION_OVERRIDE: ver_str,
            TACHYON_CORE_VERSION_FILE: version_file,
            RECORD_FLASH_WEAR: "0"
        };
        if (lib_path != "")
            gen_env.LD_LIBRARY_PATH = lib_path;
        let target_supports_xhttp = core_profile().supports_xhttp(ver_str, "tachyon-core", ver_out) === true;
        let gen_cmd = helpers.command_env(gen_env) + " " +
            common.command_from_args([
                "ucode", "-L", helpers.LIB_DIR, helpers.LIB_DIR + "/tachyon_core/generator.uc",
                "generate-config", candidate_cfg, "127.0.0.1", "0", (target_supports_xhttp ? "1" : "0"), ""
            ]) + " >" + common.shell_quote(err_file) + " 2>&1";
        let gen_status = common.command_status(gen_cmd);
        if (gen_status == 0 && helpers.file_nonempty(candidate_cfg)) {
            helpers.remove_file(err_file);
            let repaired = false;
            for (let attempt = 0; attempt < 16; attempt++) {
                let cand_check_cmd = env_space +
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
                helpers.updates_log("Pre-flight: the candidate tachyon-core rejected a field, retrying without it", "warn");
            }
            helpers.remove_file(candidate_cfg);
            helpers.remove_file(version_file);
            if (repaired) {
                helpers.remove_file(err_file);
                return { ok: true };
            }
        } else {
            helpers.remove_file(candidate_cfg);
            helpers.remove_file(version_file);
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
    let is_gen_failure = (cand_status == -1);
    if (reason == "") {
        if (cand_status == 247 || cand_status == 137)
            reason = "Out of memory (OOM killed, exit status " + cand_status + ")";
        else if (is_gen_failure)
            reason = "candidate configuration generation failed";
        else
            reason = "exit status " + cand_status;
    }

    if (is_gen_failure) {
        if (index(reason, "no enabled sections") >= 0) {
            helpers.updates_log("Pre-flight: no enabled sections yet in configuration, skipping pre-flight check", "info");
            return { ok: true };
        }
        helpers.updates_log("Pre-flight check failed: unable to generate configuration for tachyon-core: " + reason, "error");
    }
    else {
        helpers.updates_log("Pre-flight check failed: binary " + binary + " rejected config for tachyon-core: " + reason, "error");
    }
    return { ok: false, reason: reason };
}

// Forward-referenced helpers

function module_exports() {
    return {
        format_fingerprint_human,
        normalize_unknown_field_reason,
        repair_unknown_outbound_field,
        verify_package_post_install,
        verify_binary_post_install,
        check_core_config_with_binary
    };
}

return module_exports();
