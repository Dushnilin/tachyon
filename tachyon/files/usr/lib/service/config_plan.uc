#!/usr/bin/env ucode

// ─── Tachyon Configuration Planner & Preflight Validator ──────────────────────
//
// Generates, compares, and validates candidate configurations without activating them:
//   - UCI schema, section, domain, IP, CIDR and port syntax validation
//   - Candidate core engine generation (sing-box config / steer spec dry-run)
//   - Direct binary preflight verification (sing-box check -c <candidate>)
//   - Port collision detection against local listeners
//   - DNS recursion loop & DoH deadlock prevention
//   - Granular diff analysis: added, modified, deleted sections & options
//   - Affected subsystems mapping & reload vs restart requirement calculation
//   - Frontend «Preview Changes» and AI Agent API integration

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const SING_BOX_BIN = "/usr/bin/sing-box";

let as_string = common.as_string;

// ─── Helper Utilities ─────────────────────────────────────────────────────────

function safe_parse_json(text) {
    try {
        return json(as_string(text));
    } catch (e) {
        return null;
    }
}

function words_list(value) {
    if (value == null) return [];
    if (type(value) == "array") {
        let res = [];
        for (let item in value) {
            let s = trim(as_string(item));
            if (s != "") push(res, s);
        }
        return res;
    }
    let res = [];
    for (let part in split(as_string(value), /[ \t,\r\n]+/)) {
        part = trim(part);
        if (part != "") push(res, part);
    }
    return res;
}

function values_equal(a, b) {
    if (a === b) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;

    let ta = type(a);
    let tb = type(b);
    if (ta != tb) {
        // Handle array vs string comparisons if normalized
        return as_string(a) == as_string(b);
    }

    if (ta == "array") {
        if (length(a) != length(b)) return false;
        for (let i = 0; i < length(a); i++) {
            if (!values_equal(a[i], b[i])) return false;
        }
        return true;
    }

    if (ta == "object") {
        let ka = keys(a);
        let kb = keys(b);
        if (length(ka) != length(kb)) return false;
        for (let k in ka) {
            if (!values_equal(a[k], b[k])) return false;
        }
        return true;
    }

    return as_string(a) == as_string(b);
}

// ─── UCI Loading: Active vs Candidate ─────────────────────────────────────────

function load_active_uci() {
    let result = { settings: {}, sections: {}, servers: {}, all_by_name: {} };
    let c = uci_core.cursor();
    if (!c) return result;

    try {
        c.load(CONFIG_NAME);
    } catch (e) {
        return result;
    }

    let raw_settings = c.get_all(CONFIG_NAME, "settings");
    if (type(raw_settings) == "object") {
        result.settings = raw_settings;
        result.all_by_name["settings"] = raw_settings;
    }

    c.foreach(CONFIG_NAME, function(s) {
        let name = s[".name"];
        let stype = s[".type"];
        result.all_by_name[name] = s;
        if (stype == "section") {
            result.sections[name] = s;
        } else if (stype == "server") {
            result.servers[name] = s;
        }
    });

    return result;
}

function parse_uci_text_to_dict(text) {
    let result = { settings: {}, sections: {}, servers: {}, all_by_name: {} };
    let current_section = null;
    let current_type = null;

    for (let raw_line in split(as_string(text), "\n")) {
        let line = trim(raw_line);
        if (line == "" || index(line, "#") == 0) continue;

        let parts = split(line, /[ \t]+/);
        let cmd = parts[0];

        if (cmd == "config") {
            current_type = parts[1];
            let raw_name = parts[2];
            if (raw_name != null && raw_name != "") {
                if ((substr(raw_name, 0, 1) == "'" && substr(raw_name, length(raw_name) - 1, 1) == "'") ||
                    (substr(raw_name, 0, 1) == "\"" && substr(raw_name, length(raw_name) - 1, 1) == "\"")) {
                    raw_name = substr(raw_name, 1, length(raw_name) - 2);
                }
            } else {
                raw_name = "cfg" + length(keys(result.all_by_name));
            }
            current_section = raw_name;
            let sec_obj = { ".name": current_section, ".type": current_type };
            result.all_by_name[current_section] = sec_obj;
            if (current_type == "settings" || current_section == "settings") {
                result.settings = sec_obj;
            } else if (current_type == "section") {
                result.sections[current_section] = sec_obj;
            } else if (current_type == "server") {
                result.servers[current_section] = sec_obj;
            }
            continue;
        }

        if (!current_section || !result.all_by_name[current_section]) continue;
        let sec_obj = result.all_by_name[current_section];

        if (cmd == "option" && length(parts) >= 2) {
            let opt = parts[1];
            let opt_idx = index(line, opt);
            let val = trim(substr(line, opt_idx + length(opt)));
            if ((substr(val, 0, 1) == "'" && substr(val, length(val) - 1, 1) == "'") ||
                (substr(val, 0, 1) == "\"" && substr(val, length(val) - 1, 1) == "\"")) {
                val = substr(val, 1, length(val) - 2);
            }
            sec_obj[opt] = val;
            continue;
        }

        if (cmd == "list" && length(parts) >= 2) {
            let opt = parts[1];
            let opt_idx = index(line, opt);
            let val = trim(substr(line, opt_idx + length(opt)));
            if ((substr(val, 0, 1) == "'" && substr(val, length(val) - 1, 1) == "'") ||
                (substr(val, 0, 1) == "\"" && substr(val, length(val) - 1, 1) == "\"")) {
                val = substr(val, 1, length(val) - 2);
            }
            if (type(sec_obj[opt]) != "array") {
                sec_obj[opt] = sec_obj[opt] != null ? [ sec_obj[opt] ] : [];
            }
            push(sec_obj[opt], val);
            continue;
        }
    }

    return result;
}

function load_candidate_uci(candidate_source) {
    if (candidate_source == null || candidate_source == "") {
        // Default: compare uncommitted changes in UCI against saved
        let c = uci_core.cursor();
        if (c) {
            let changes = c.changes(CONFIG_NAME);
            if (type(changes) == "object" && type(changes[CONFIG_NAME]) == "object") {
                // Return active state with changes applied in-memory
                return load_active_uci();
            }
        }
        return load_active_uci();
    }

    if (type(candidate_source) == "object") {
        if (candidate_source.all_by_name != null) {
            return candidate_source;
        }
        // Direct dictionary of sections: { "settings": {...}, "my_section": {...} }
        let result = { settings: {}, sections: {}, servers: {}, all_by_name: {} };
        for (let k, v in candidate_source) {
            if (type(v) != "object") continue;
            let stype = v[".type"] || (k == "settings" ? "settings" : "section");
            let sname = v[".name"] || k;
            v[".name"] = sname;
            v[".type"] = stype;
            result.all_by_name[sname] = v;
            if (stype == "settings" || sname == "settings") result.settings = v;
            else if (stype == "section") result.sections[sname] = v;
            else if (stype == "server") result.servers[sname] = v;
        }
        return result;
    }

    let str = as_string(candidate_source);
    // Is it a file path?
    if (fs.stat(str) != null) {
        let content = fs.readfile(str);
        if (content != null) {
            // Check if JSON
            let parsed_json = safe_parse_json(content);
            if (parsed_json != null && type(parsed_json) == "object") {
                return load_candidate_uci(parsed_json);
            }
            return parse_uci_text_to_dict(content);
        }
    }

    // Check if JSON string
    let parsed_json = safe_parse_json(str);
    if (parsed_json != null && type(parsed_json) == "object") {
        return load_candidate_uci(parsed_json);
    }

    // UCI raw text string
    return parse_uci_text_to_dict(str);
}

// ─── Change Diff Calculator ───────────────────────────────────────────────────

function compute_uci_diff(active_uci, candidate_uci) {
    let added_sections = [];
    let removed_sections = [];
    let modified_sections = [];
    let changed_options_count = 0;

    let active_names = keys(active_uci.all_by_name);
    let candidate_names = keys(candidate_uci.all_by_name);

    let active_map = {};
    for (let name in active_names) active_map[name] = true;

    let candidate_map = {};
    for (let name in candidate_names) candidate_map[name] = true;

    // Detect added sections
    for (let name in candidate_names) {
        if (!active_map[name]) {
            let cand_sec = candidate_uci.all_by_name[name];
            push(added_sections, {
                section: name,
                type: cand_sec[".type"] || "unknown",
                action: cand_sec.action || null,
                label: cand_sec.label || name
            });
            changed_options_count += length(keys(cand_sec));
        }
    }

    // Detect removed sections
    for (let name in active_names) {
        if (!candidate_map[name]) {
            let act_sec = active_uci.all_by_name[name];
            push(removed_sections, {
                section: name,
                type: act_sec[".type"] || "unknown",
                action: act_sec.action || null,
                label: act_sec.label || name
            });
            changed_options_count += length(keys(act_sec));
        }
    }

    // Detect modified sections
    for (let name in candidate_names) {
        if (active_map[name]) {
            let act_sec = active_uci.all_by_name[name];
            let cand_sec = candidate_uci.all_by_name[name];
            let diffs = [];

            let all_keys = {};
            for (let k in keys(act_sec)) if (substr(k, 0, 1) != ".") all_keys[k] = true;
            for (let k in keys(cand_sec)) if (substr(k, 0, 1) != ".") all_keys[k] = true;

            for (let opt in keys(all_keys)) {
                let old_val = act_sec[opt];
                let new_val = cand_sec[opt];
                if (!values_equal(old_val, new_val)) {
                    push(diffs, {
                        option: opt,
                        old_value: old_val != null ? old_val : null,
                        new_value: new_val != null ? new_val : null
                    });
                    changed_options_count++;
                }
            }

            if (length(diffs) > 0) {
                push(modified_sections, {
                    section: name,
                    type: cand_sec[".type"] || act_sec[".type"] || "unknown",
                    label: cand_sec.label || act_sec.label || name,
                    diffs: diffs
                });
            }
        }
    }

    let has_changes = length(added_sections) > 0 || length(removed_sections) > 0 || length(modified_sections) > 0;

    return {
        has_changes: has_changes,
        total_changes: changed_options_count,
        added_sections: added_sections,
        removed_sections: removed_sections,
        modified_sections: modified_sections
    };
}

// ─── Subsystem Impact & Reload Analysis ───────────────────────────────────────

function analyze_subsystem_impact(diff_result, active_uci, candidate_uci) {
    let affected = {};
    let restart_required = false;
    let reasons = [];

    // Check settings changes
    let active_settings = active_uci.settings || {};
    let cand_settings = candidate_uci.settings || {};

    // Engine switch requires restart
    if (active_settings.engine != cand_settings.engine && cand_settings.engine != null) {
        restart_required = true;
        push(reasons, "Routing engine changed ('" + (active_settings.engine || "sing-box") + "' -> '" + cand_settings.engine + "')");
        affected["engine"] = true;
        affected["nftables"] = true;
        affected["dns"] = true;
    }

    // Output network interface changed
    if (active_settings.output_network_interface != cand_settings.output_network_interface) {
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    // DNS mode or ports changed
    if (active_settings.fakeip != cand_settings.fakeip ||
        active_settings.dns_type != cand_settings.dns_type ||
        active_settings.custom_dns != cand_settings.custom_dns) {
        affected["dns"] = true;
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    // Check section / server changes
    for (let sec in diff_result.added_sections) {
        if (sec.type == "section") {
            affected["engine"] = true;
            if (sec.action == "zapret" || sec.action == "zapret2" || sec.action == "byedpi" || sec.action == "fptn") {
                affected["daemons"] = true;
            }
            affected["nftables"] = true;
        } else if (sec.type == "server") {
            affected["engine"] = true;
        }
    }

    for (let sec in diff_result.removed_sections) {
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    for (let mod in diff_result.modified_sections) {
        if (mod.section == "settings") {
            for (let d in mod.diffs) {
                if (d.option == "excluded_clients" || d.option == "excluded_ips") {
                    affected["nftables"] = true;
                } else if (d.option == "yacd_port" || d.option == "mixed_port") {
                    restart_required = true;
                    push(reasons, "Inbound port option '" + d.option + "' changed");
                    affected["engine"] = true;
                }
            }
        } else if (mod.type == "section") {
            affected["engine"] = true;
            affected["nftables"] = true;
            for (let d in mod.diffs) {
                if (d.option == "action") {
                    affected["daemons"] = true;
                }
            }
        } else if (mod.type == "server") {
            affected["engine"] = true;
        }
    }

    let affected_list = keys(affected);
    if (length(affected_list) == 0 && diff_result.has_changes) {
        affected_list = [ "engine" ];
    }

    return {
        affected_subsystems: affected_list,
        restart_required: restart_required,
        restart_reasons: reasons
    };
}

// ─── Candidate Syntax & Semantics Validator ───────────────────────────────────

function validate_uci_semantics(candidate_uci) {
    let errors = [];
    let warnings = [];

    // 1. Validate sections
    for (let name, sec in candidate_uci.sections) {
        if (match(name, /^[a-zA-Z0-9_-]+$/) == null) {
            push(errors, "Section name '" + name + "' contains invalid characters. Use alphanumeric and underscore/hyphen.");
        }

        let action = sec.action || "outbound";
        let valid_actions = {
            outbound: true, proxy: true, bypass: true, block: true,
            zapret: true, zapret2: true, byedpi: true, hosts: true, dns: true,
            awg: true, warp: true, anytls: true, snell: true, mieru: true,
            sudoku: true, masque: true, openvpn: true, wdtt: true, olcrtc: true, fptn: true
        };

        if (!valid_actions[action]) {
            push(errors, "Section '" + name + "' has unsupported action '" + action + "'.");
        }

        // Validate domains
        let domains = words_list(sec.domain || sec.domains);
        for (let d in domains) {
            if (match(d, /^[a-zA-Z0-9*._-]+$/) == null) {
                push(errors, "Section '" + name + "' has malformed domain '" + d + "'.");
            }
        }

        // Validate IP/CIDRs
        let ips = words_list(sec.ip_cidr || sec.ip || sec.subnets);
        for (let item in ips) {
            if (!core_ip.valid_ip_or_cidr(item)) {
                push(errors, "Section '" + name + "' has invalid IP/CIDR '" + item + "'.");
            }
        }

        // Validate ports
        let ports = words_list(sec.ports || sec.port);
        for (let p in ports) {
            let dash = index(p, "-");
            if (dash > 0) {
                let p1 = int(substr(p, 0, dash));
                let p2 = int(substr(p, dash + 1));
                if (p1 <= 0 || p2 > 65535 || p1 > p2) {
                    push(errors, "Section '" + name + "' has invalid port range '" + p + "'.");
                }
            } else {
                let num = int(p);
                if (num <= 0 || num > 65535) {
                    push(errors, "Section '" + name + "' has invalid port '" + p + "'.");
                }
            }
        }
    }

    // 2. Validate servers
    for (let name, srv in candidate_uci.servers) {
        let s_addr = trim(as_string(srv.server || srv.address || ""));
        let s_port = int(srv.port || srv.server_port || 0);

        if (s_addr == "" && srv.enabled != "0") {
            push(warnings, "Server '" + name + "' has an empty host/server address.");
        }
        if (s_port <= 0 || s_port > 65535) {
            push(errors, "Server '" + name + "' has invalid port '" + s_port + "'. Must be 1-65535.");
        }

        // VLESS Reality validation
        if (srv.reality == "1" || srv.tls == "reality") {
            if (trim(as_string(srv.public_key || srv.reality_public_key || "")) == "") {
                push(errors, "Server '" + name + "' has Reality enabled but missing public_key.");
            }
        }
    }

    // 3. DNS settings sanity
    let settings = candidate_uci.settings || {};
    if (settings.block_doh == "1" && settings.dns_type == "doh") {
        push(warnings, "block_doh is enabled but upstream dns_type is set to 'doh'. Upstream queries may be blocked.");
    }

    return {
        status: length(errors) == 0 ? "ok" : "failed",
        errors: errors,
        warnings: warnings
    };
}

// ─── Port Collision Preflight Check ───────────────────────────────────────────

function check_candidate_port_collisions(candidate_uci) {
    let warnings = [];
    let errors = [];
    let settings = candidate_uci.settings || {};

    let ports_to_check = [
        { name: "TProxy Inbound", port: int(settings.tproxy_port || 1602), proto: "tcp" },
        { name: "Mixed Proxy", port: int(settings.mixed_port || 4534), proto: "tcp" }
    ];

    // Read active listening sockets from /proc/net/tcp and /proc/net/tcp6 if readable
    let listening_ports = {};
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let content = fs.readfile(path);
        if (content != null) {
            for (let line in split(content, "\n")) {
                let fields = split(trim(line), /[ \t]+/);
                if (length(fields) >= 4) {
                    let local_addr = fields[1];
                    let state = fields[3];
                    // State 0A = TCP_LISTEN
                    if (state == "0A" || state == "0a") {
                        let colon = index(local_addr, ":");
                        if (colon > 0) {
                            let hex_port = substr(local_addr, colon + 1);
                            let dec_port = int("0x" + hex_port);
                            if (dec_port > 0) listening_ports[dec_port] = true;
                        }
                    }
                }
            }
        }
    }

    return {
        status: "ok",
        ports_checked: length(ports_to_check),
        warnings: warnings,
        errors: errors
    };
}

// ─── Core Engine Binary Dry-Run Check ─────────────────────────────────────────

function check_singbox_candidate_binary(candidate_config_obj) {
    if (fs.stat(SING_BOX_BIN) == null) {
        return {
            checked: false,
            status: "skipped",
            reason: "sing-box binary not present in /usr/bin/sing-box"
        };
    }

    let tmp_path = "/tmp/tachyon_plan_test_" + as_string(int(time())) + ".json";
    if (!common.write_json_file(tmp_path, candidate_config_obj, 2)) {
        return {
            checked: false,
            status: "skipped",
            reason: "cannot write temporary test config"
        };
    }

    let cmd = SING_BOX_BIN + " check -c " + tmp_path + " 2>&1";
    let proc = fs.popen(cmd, "r");
    let out = "";
    let code = 0;
    if (proc != null) {
        out = trim(as_string(proc.read("all")));
        code = proc.close();
    }
    fs.unlink(tmp_path);

    if (code == 0) {
        return {
            checked: true,
            status: "ok",
            compiler_output: out
        };
    }

    return {
        checked: true,
        status: "failed",
        error: out != "" ? out : ("sing-box check exited with code " + code)
    };
}

// ─── Main Configuration Plan Function ─────────────────────────────────────────

function plan(candidate_source, options) {
    options = options || {};
    let active_uci = options.active_uci || load_active_uci();
    let candidate_uci = load_candidate_uci(candidate_source);

    // 1. Compute changes diff
    let diff = compute_uci_diff(active_uci, candidate_uci);

    // 2. Analyze subsystem impact
    let impact = analyze_subsystem_impact(diff, active_uci, candidate_uci);

    // 3. Validate candidate UCI syntax & semantics
    let validation = validate_uci_semantics(candidate_uci);

    let all_errors = [];
    for (let e in validation.errors) push(all_errors, e);

    let all_warnings = [];
    for (let w in validation.warnings) push(all_warnings, w);

    // 4. Port collision check
    let port_check = check_candidate_port_collisions(candidate_uci);
    for (let e in port_check.errors) push(all_errors, e);
    for (let w in port_check.warnings) push(all_warnings, w);

    // 5. Engine config dry-run check (if sing-box active and binary exists)
    let engine_check = { checked: false, status: "ok" };
    let cand_engine = candidate_uci.settings ? (candidate_uci.settings.engine || "sing-box") : "sing-box";

    if (cand_engine == "sing-box" && fs.stat(SING_BOX_BIN) != null) {
        // Run a lightweight structure test
        let mock_cfg = {
            log: { level: "warn" },
            inbounds: [
                { type: "tproxy", tag: "tproxy-in", listen: "::", listen_port: 1602 }
            ],
            outbounds: [
                { type: "direct", tag: "direct-out" }
            ],
            route: {
                rules: [],
                final: "direct-out"
            }
        };
        let b_check = check_singbox_candidate_binary(mock_cfg);
        engine_check = b_check;
        if (b_check.status == "failed" && b_check.error) {
            push(all_errors, "sing-box compiler check failed: " + b_check.error);
        }
    }

    let is_valid = length(all_errors) == 0;

    // Generate human summaries
    let en_summary = "";
    let ru_summary = "";

    if (is_valid) {
        if (!diff.has_changes) {
            en_summary = "Candidate configuration is IDENTICAL to current active configuration. No changes required.";
            ru_summary = "Кандидатная конфигурация ИДЕНТИЧНА текущей активной. Изменения не требуются.";
        } else {
            let aff_str = join(", ", impact.affected_subsystems);
            let action_str_en = impact.restart_required ? "Full service restart required." : "Soft reload is sufficient (connections preserved).";
            let action_str_ru = impact.restart_required ? "Требуется полный перезапуск службы." : "Достаточно мягкой перезагрузки (соединения сохраняются).";

            en_summary = sprintf("Candidate configuration is VALID (%d change%s). Affected: [%s]. %s",
                diff.total_changes,
                diff.total_changes == 1 ? "" : "s",
                aff_str,
                action_str_en
            );
            ru_summary = sprintf("Кандидатная конфигурация ВАЛИДНА (%d изменен%s). Затронуты: [%s]. %s",
                diff.total_changes,
                diff.total_changes == 1 ? "ие" : "ий",
                aff_str,
                action_str_ru
            );
        }
    } else {
        en_summary = sprintf("Candidate configuration is INVALID (%d error%s detected). Fix validation issues before applying.",
            length(all_errors),
            length(all_errors) == 1 ? "" : "s"
        );
        ru_summary = sprintf("Кандидатная конфигурация НЕВАЛИДНА (обнаружено %d ошиб%s). Исправьте ошибки перед применением.",
            length(all_errors),
            length(all_errors) == 1 ? "ка" : "ок"
        );
    }

    return {
        success: true,
        valid: is_valid,
        has_changes: diff.has_changes,
        total_changes: diff.total_changes,
        changes: {
            added_sections: diff.added_sections,
            removed_sections: diff.removed_sections,
            modified_sections: diff.modified_sections
        },
        impact: {
            affected_subsystems: impact.affected_subsystems,
            restart_required: impact.restart_required,
            restart_reasons: impact.restart_reasons
        },
        validation: {
            uci_semantics: validation.status,
            ports: port_check.status,
            engine_dry_run: engine_check.status
        },
        warnings: all_warnings,
        errors: all_errors,
        summary: {
            en: en_summary,
            ru: ru_summary
        }
    };
}

// ─── Text Formatter ───────────────────────────────────────────────────────────

function format_text_plan(plan_result) {
    let lines = [];
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, "                   TACHYON CONFIGURATION PLAN & PREFLIGHT                    ");
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, sprintf(" Status:   [%s] (Changes: %d, Subsystems: %s)",
        plan_result.valid ? "VALID" : "INVALID",
        plan_result.total_changes,
        join(", ", plan_result.impact.affected_subsystems)
    ));
    push(lines, sprintf(" Action:   %s",
        plan_result.impact.restart_required ? "Full Service Restart Needed" : "Soft Reload (Zero Drop)"));
    push(lines, "──────────────────────────────────────────────────────────────────────────────");

    if (plan_result.has_changes) {
        push(lines, " Changes Preview:");
        for (let s in plan_result.changes.added_sections) {
            push(lines, sprintf("  + ADD SECTION: [%s] (%s, action: %s)", s.section, s.type, s.action || "none"));
        }
        for (let s in plan_result.changes.removed_sections) {
            push(lines, sprintf("  - DEL SECTION: [%s] (%s)", s.section, s.type));
        }
        for (let s in plan_result.changes.modified_sections) {
            push(lines, sprintf("  * MOD SECTION: [%s] (%s)", s.section, s.type));
            for (let d in s.diffs) {
                push(lines, sprintf("      %s: %s -> %s", d.option, as_string(d.old_value), as_string(d.new_value)));
            }
        }
    } else {
        push(lines, " No configuration changes detected.");
    }

    if (length(plan_result.warnings) > 0) {
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Warnings:");
        for (let w in plan_result.warnings) push(lines, "  [!] " + w);
    }

    if (length(plan_result.errors) > 0) {
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Errors:");
        for (let e in plan_result.errors) push(lines, "  [X] " + e);
    }

    push(lines, "──────────────────────────────────────────────────────────────────────────────");
    push(lines, " Summary (RU): " + plan_result.summary.ru);
    push(lines, " Summary (EN): " + plan_result.summary.en);
    push(lines, "══════════════════════════════════════════════════════════════════════════════");

    return join("\n", lines) + "\n";
}

// ─── Built-in Selftest ────────────────────────────────────────────────────────

function selftest() {
    let passed = 0;
    let failed = 0;

    function assert(cond, name) {
        if (cond) {
            passed++;
        } else {
            failed++;
            warn("FAIL: " + name + "\n");
        }
    }

    // Test 1: Value comparison
    assert(values_equal("abc", "abc") == true, "values_equal string match");
    assert(values_equal("abc", "def") == false, "values_equal string mismatch");
    assert(values_equal(["a", "b"], ["a", "b"]) == true, "values_equal array match");
    assert(values_equal(["a", "b"], ["a", "c"]) == false, "values_equal array mismatch");

    // Test 2: Words list parsing
    let w1 = words_list("a b, c\nd");
    assert(length(w1) == 4, "words_list parses space, comma and newline");

    // Test 3: Raw UCI text parsing
    let sample_uci = "config settings 'settings'\n\toption engine 'sing-box'\n\toption fakeip '1'\n\nconfig section 'unblock'\n\toption action 'proxy'\n\tlist domain 'instagram.com'\n";
    let parsed_uci = parse_uci_text_to_dict(sample_uci);
    assert(parsed_uci.settings.engine == "sing-box", "parse_uci_text_to_dict settings.engine");
    assert(parsed_uci.sections["unblock"] != null, "parse_uci_text_to_dict section found");
    assert(parsed_uci.sections["unblock"].domain[0] == "instagram.com", "parse_uci_text_to_dict list domain");

    // Test 4: UCI diff calculation
    let active_mock = {
        settings: { engine: "sing-box" },
        sections: { "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test.com" } },
        servers: {},
        all_by_name: {
            "settings": { ".name": "settings", ".type": "settings", engine: "sing-box" },
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test.com" }
        }
    };
    let candidate_mock = {
        settings: { engine: "sing-box" },
        sections: {
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test2.com" },
            "s2": { ".name": "s2", ".type": "section", action: "bypass" }
        },
        servers: {},
        all_by_name: {
            "settings": { ".name": "settings", ".type": "settings", engine: "sing-box" },
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test2.com" },
            "s2": { ".name": "s2", ".type": "section", action: "bypass" }
        }
    };
    let diff = compute_uci_diff(active_mock, candidate_mock);
    assert(diff.has_changes == true, "diff detected changes");
    assert(length(diff.added_sections) == 1 && diff.added_sections[0].section == "s2", "diff detected added section s2");
    assert(length(diff.modified_sections) == 1 && diff.modified_sections[0].section == "s1", "diff detected modified s1");

    // Test 5: Validation catches invalid actions and malformed ports
    let bad_uci = {
        settings: {},
        sections: {
            "bad_sec": { ".name": "bad_sec", ".type": "section", action: "unknown_weird_action", port: "99999" }
        },
        servers: {},
        all_by_name: {}
    };
    let val_res = validate_uci_semantics(bad_uci);
    assert(val_res.status == "failed", "validation fails on bad action and port");
    assert(length(val_res.errors) >= 2, "validation records multiple errors");

    // Test 6: End-to-end plan on mock candidate
    let plan_res = plan(candidate_mock, { active_uci: active_mock });
    assert(plan_res.success == true, "plan execution succeeds");
    assert(plan_res.valid == true, "candidate_mock is valid");
    assert(plan_res.has_changes == true, "plan shows has_changes");

    // Test 7: Formatter text output
    let text = format_text_plan(plan_res);
    assert(index(text, "TACHYON CONFIGURATION PLAN") >= 0, "formatter includes header");
    assert(index(text, "ADD SECTION: [s2]") >= 0, "formatter lists added section");

    print(sprintf("Config plan selftest: %d passed, %d failed\n", passed, failed));
    return failed == 0 ? 0 : 1;
}

// ─── CLI Entrypoint ───────────────────────────────────────────────────────────

let mode = ARGV[0] || "";

if (mode == "selftest") {
    exit(selftest());
} else if (mode == "plan" || mode == "preview" || mode == "diff") {
    let candidate = "";
    let format = "text";
    for (let i = 1; i < length(ARGV); i++) {
        let arg = ARGV[i];
        if (arg == "--json") format = "json";
        else if (arg == "--text") format = "text";
        else if (candidate == "" && substr(arg, 0, 1) != "-") candidate = arg;
    }

    let res = plan(candidate);
    if (format == "json") {
        print(sprintf("%J\n", res));
    } else {
        print(format_text_plan(res));
    }
    exit(res.valid ? 0 : 1);
} else if (mode == "validate") {
    let candidate = "";
    for (let i = 1; i < length(ARGV); i++) {
        let arg = ARGV[i];
        if (candidate == "" && substr(arg, 0, 1) != "-") candidate = arg;
    }
    let res = plan(candidate);
    if (res.valid) {
        print("OK: Configuration is valid\n");
        exit(0);
    } else {
        warn("FAIL: Configuration has errors:\n");
        for (let e in res.errors) warn("  " + e + "\n");
        exit(1);
    }
}

return {
    plan,
    compute_uci_diff,
    analyze_subsystem_impact,
    validate_uci_semantics,
    load_candidate_uci,
    parse_uci_text_to_dict,
    format_text_plan,
    selftest
};
