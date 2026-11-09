#!/usr/bin/env ucode

// Config snapshots: save / list / restore / delete working configs so the user
// can roll back from LuCI's advanced settings. A snapshot is a tar.gz of
// config/<name> + <name>/ under the config root — the same member layout as
// the Telegram backup, so snapshot archives can be restored there too.

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

let shell_quote = common.shell_quote;

let command_from_args = common.command_from_args;

let normalize_status = common.normalize_status;

let command_status = common.command_status;

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

let command_output = common.command_output;

let command_output_from_args = common.command_output_from_args;

function log_message(message) {
    system(command_from_args([ "logger", "-t", CONFIG_NAME, "[info] " + message ]) + " >/dev/null 2>&1");
}

function fail(message) {
    print(sprintf("%J\n", { success: false, message: message }));
    return 1;
}

const CONFIG_NAME = env("TACHYON_CONFIG_NAME", "tachyon");
const BIN_PATH = env("TACHYON_BIN", "/usr/bin/tachyon");
const CONFIG_PATH = env("TACHYON_CONFIG_PATH", "/etc/config/" + CONFIG_NAME);
const PERSISTENT_DIR = env("TACHYON_PERSISTENT_DIR", "/etc/" + CONFIG_NAME);
const CONFIG_ROOT = env("TACHYON_CONFIG_ROOT", "/etc");
const SNAPSHOTS_DIR = env("TACHYON_SNAPSHOTS_DIR", "/etc/.tachyon/snapshots");
const SNAPSHOT_LIMIT = int(env("TACHYON_SNAPSHOT_LIMIT", "10"));
const VALIDATE_BIN = env("TACHYON_SNAPSHOT_VALIDATE_BIN", "/sbin/uci");
const EXPORT_TMP_FILE = env("TACHYON_SNAPSHOT_EXPORT_FILE", "/tmp/tachyon-snapshot-export.json");

const SNAPSHOT_EXCLUDED_DIRS = [
    "rulesets",
    "installer-backups",
    "subscription-cache",
    "component-backups",
    "hosts-lists",
    "state",
    "tailscale",
    "smart-detect-exclusions"
];

const SNAPSHOT_EXCLUDED_FILES = [
    "fuzzer_history.json",
    "fuzzer_patterns.json",
    "rag_index.json",
    "smart_detect_seen.json",
    "smart_detect_plus_seen.json",
    "emergency_state.json"
];

function is_excluded_data_entry(entry_name) {
    entry_name = as_string(entry_name);
    for (let d in SNAPSHOT_EXCLUDED_DIRS)
        if (entry_name == d)
            return true;
    for (let f in SNAPSHOT_EXCLUDED_FILES)
        if (entry_name == f)
            return true;
    return false;
}

function strip_excluded_dirs(data_dir) {
    if (fs.stat(data_dir) == null)
        return;
    for (let dir in SNAPSHOT_EXCLUDED_DIRS) {
        let p = data_dir + "/" + dir;
        if (fs.stat(p) != null)
            command_status(command_from_args([ "rm", "-rf", p ]));
    }
    for (let f in SNAPSHOT_EXCLUDED_FILES) {
        let p = data_dir + "/" + f;
        if (fs.stat(p) != null)
            command_status(command_from_args([ "rm", "-f", p ]));
    }
}

function preserve_excluded_dirs(src_data_dir, dst_data_dir) {
    if (fs.stat(src_data_dir) == null || fs.stat(dst_data_dir) == null)
        return;
    for (let dir in SNAPSHOT_EXCLUDED_DIRS) {
        let src = src_data_dir + "/" + dir;
        let dst = dst_data_dir + "/" + dir;
        if (fs.stat(src) != null && fs.stat(dst) == null)
            command_status(command_from_args([ "cp", "-a", src, dst ]));
    }
    for (let f in SNAPSHOT_EXCLUDED_FILES) {
        let src = src_data_dir + "/" + f;
        let dst = dst_data_dir + "/" + f;
        if (fs.stat(src) != null && fs.stat(dst) == null)
            command_status(command_from_args([ "cp", "-a", src, dst ]));
    }
}

function stage_filtered_data_dir(src_dir, dst_dir) {
    if (!command_success_from_args([ "mkdir", "-p", dst_dir ]))
        return false;
    if (fs.stat(src_dir) == null)
        return true;
    let items = fs.lsdir(src_dir);
    if (type(items) != "array")
        return true;
    for (let item in items) {
        item = as_string(item);
        if (item == "" || item == "." || item == ".." || is_excluded_data_entry(item))
            continue;
        if (!command_success_from_args([ "cp", "-a", src_dir + "/" + item, dst_dir + "/" + item ]))
            return false;
    }
    return true;
}

function snapshot_stamp() {
    return trim(command_output_from_args([ "date", "+%Y%m%d-%H%M%S" ]));
}

function snapshot_name_safe(name) {
    name = as_string(name);
    let cleaned = "";
    for (let i = 0; i < length(name); i++) {
        let ch = substr(name, i, 1);
        if (match(ch, /[A-Za-z0-9_\-]/))
            cleaned += ch;
    }
    if (cleaned == "" || length(cleaned) > 64)
        return null;
    return cleaned;
}

function snapshot_file_valid(file) {
    return match(as_string(file), /^[A-Za-z0-9_\-]+-[0-9]{8}-[0-9]{6}\.tar\.gz$/) != null;
}

function backup_archive_safe(members) {
    let config_member = "config/" + CONFIG_NAME;
    let data_prefix = CONFIG_NAME + "/";
    for (let raw_m in members) {
        let m = replace(as_string(raw_m), /^\.\//, "");
        if (m == "" || m == ".") continue;
        if (substr(m, 0, 1) == "/") return { ok: false, reason: "absolute path: " + raw_m };
        if (match(m, /(^|\/)\.\.(\/|$)/)) return { ok: false, reason: "path traversal: " + raw_m };
        if (m != "config" && m != "config/" && m != config_member && m != CONFIG_NAME && substr(m, 0, length(data_prefix)) != data_prefix)
            return { ok: false, reason: "unexpected member: " + raw_m };
    }
    return { ok: true };
}

function config_sane_preview(path) {
    let data = fs.readfile(path);
    if (data == null) return false;
    return match(data, /(^|\n)[ \t]*config[ \t]+[A-Za-z0-9_-]+/) != null;
}

function restore_config_from_backup(backup_path) {
    if (backup_path && fs.stat(backup_path)) {
        let tmp = CONFIG_PATH + ".restore-tmp";
        command_status(command_from_args([ "cp", "-a", backup_path, tmp ]));
        command_status(command_from_args([ "mv", "-f", tmp, CONFIG_PATH ]));
    }
}

function prune_snapshots() {
    let out = command_output_from_args([ "ls", "-t", SNAPSHOTS_DIR ]);
    let kept = 0;
    for (let line in split(out, "\n")) {
        line = trim(line);
        if (line == "" || !snapshot_file_valid(line))
            continue;
        kept++;
        if (kept > SNAPSHOT_LIMIT)
            command_success_from_args([ "rm", "-f", SNAPSHOTS_DIR + "/" + line ]);
    }
}

function compact_bloated_snapshot_if_needed(archive_path) {
    let st = fs.stat(archive_path);
    if (st == null || int(st.size || 0) <= 524288)
        return;
    let members_out = command_output_from_args([ "tar", "-tzf", archive_path ]);
    let has_excluded = false;
    let members = [];
    let data_prefix = CONFIG_NAME + "/";
    for (let line in split(members_out, "\n")) {
        line = trim(line);
        if (line == "")
            continue;
        push(members, line);
        let clean_m = replace(line, /^\.\//, "");
        if (substr(clean_m, 0, length(data_prefix)) == data_prefix) {
            let rest = substr(clean_m, length(data_prefix));
            let slash_idx = index(rest, "/");
            let top_entry = slash_idx >= 0 ? substr(rest, 0, slash_idx) : rest;
            if (is_excluded_data_entry(top_entry))
                has_excluded = true;
        }
    }
    if (!has_excluded || !backup_archive_safe(members).ok)
        return;
    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-compact.XXXXXX" ]));
    if (stage == "")
        return;
    if (command_success_from_args([ "tar", "-xzf", archive_path, "-C", stage ])) {
        strip_excluded_dirs(stage + "/" + CONFIG_NAME);
        let tmp_archive = archive_path + ".compact";
        let tar_args = [ "tar", "-czf", tmp_archive, "-C", stage ];
        if (fs.stat(stage + "/config/" + CONFIG_NAME) != null)
            push(tar_args, "config/" + CONFIG_NAME);
        if (fs.stat(stage + "/" + CONFIG_NAME) != null)
            push(tar_args, CONFIG_NAME);
        if (length(tar_args) > 5 && command_success_from_args(tar_args)) {
            command_success_from_args([ "chmod", "600", tmp_archive ]);
            command_status(command_from_args([ "mv", "-f", tmp_archive, archive_path ]));
        } else {
            command_success_from_args([ "rm", "-f", tmp_archive ]);
        }
    }
    command_status(command_from_args([ "rm", "-rf", stage ]));
}

function snapshot_save(name) {
    let safe = snapshot_name_safe(name);
    if (safe == null)
        return fail("invalid snapshot name");
    if (!command_success_from_args([ "mkdir", "-p", SNAPSHOTS_DIR ]))
        return fail("unable to create snapshots directory");
    if (fs.stat(CONFIG_PATH) == null)
        return fail("config file not found");

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-save.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");

    let staged_cfg_dir = stage + "/config";
    let staged_data_dir = stage + "/" + CONFIG_NAME;
    if (!command_success_from_args([ "mkdir", "-p", staged_cfg_dir ]) ||
        !command_success_from_args([ "cp", "-a", CONFIG_PATH, staged_cfg_dir + "/" + CONFIG_NAME ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to stage snapshot config");
    }

    if (!stage_filtered_data_dir(PERSISTENT_DIR, staged_data_dir)) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to stage snapshot data");
    }

    let file = SNAPSHOTS_DIR + "/" + safe + "-" + snapshot_stamp() + ".tar.gz";
    let packed = command_success_from_args([ "tar", "-czf", file, "-C", stage, "config/" + CONFIG_NAME, CONFIG_NAME ]);
    command_status(command_from_args([ "rm", "-rf", stage ]));
    if (!packed) {
        command_success_from_args([ "rm", "-f", file ]);
        return fail("unable to create snapshot archive");
    }
    command_success_from_args([ "chmod", "600", file ]);
    prune_snapshots();

    log_message("Config snapshot saved: " + safe);
    print(sprintf("%J\n", { success: true, file: common.path_basename(file) }));
    return 0;
}

function snapshot_list() {
    let entries = [];
    if (fs.stat(SNAPSHOTS_DIR) == null)
        return entries;
    let out = command_output_from_args([ "ls", "-t", SNAPSHOTS_DIR ]);
    for (let line in split(out, "\n")) {
        line = trim(line);
        if (line == "" || !snapshot_file_valid(line))
            continue;
        let full = SNAPSHOTS_DIR + "/" + line;
        compact_bloated_snapshot_if_needed(full);
        let st = fs.stat(full);
        if (st == null)
            continue;
        let size = int(st.size || 0);
        let base = substr(line, 0, length(line) - length(".tar.gz"));
        let last_dash = rindex(base, "-");
        let mid_dash = last_dash >= 0 ? rindex(substr(base, 0, last_dash), "-") : -1;
        let name = mid_dash >= 0 ? substr(base, 0, mid_dash) : base;
        let stamp = mid_dash >= 0 ? substr(base, mid_dash + 1) : "";
        push(entries, { file: line, name: name, stamp: stamp, size: size });
    }
    return entries;
}

function snapshot_delete(file) {
    if (!snapshot_file_valid(file))
        return fail("invalid snapshot name");
    let path = SNAPSHOTS_DIR + "/" + file;
    if (fs.stat(path) == null)
        return fail("snapshot not found");
    if (!command_success_from_args([ "rm", "-f", path ]))
        return fail("unable to remove snapshot");
    log_message("Config snapshot deleted: " + file);
    print(sprintf("%J\n", { success: true }));
    return 0;
}

function snapshot_restore(file) {
    if (!snapshot_file_valid(file))
        return fail("invalid snapshot name");
    let archive = SNAPSHOTS_DIR + "/" + file;
    if (fs.stat(archive) == null)
        return fail("snapshot not found");

    let members_out = command_output_from_args([ "tar", "-tzf", archive ]);
    let members = [];
    for (let line in split(members_out, "\n")) {
        line = trim(line);
        if (line != "")
            push(members, line);
    }
    let safety = backup_archive_safe(members);
    if (!safety.ok)
        return fail("unsafe archive: " + safety.reason);

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-restore.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");
    if (!command_success_from_args([ "tar", "-xzf", archive, "-C", stage ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to extract snapshot archive");
    }

    let staged_config = stage + "/config/" + CONFIG_NAME;
    let had_config = fs.stat(staged_config) != null;
    if (had_config && !config_sane_preview(staged_config)) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("snapshot config does not look like a valid UCI file");
    }
    let staged_data = stage + "/" + CONFIG_NAME;
    let had_data = fs.stat(staged_data) != null;
    if (!had_config && !had_data) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("snapshot contains neither config nor data");
    }

    let cfg_backup = stage + "/restore_cfg_backup";
    let data_backup = stage + "/restore_data_backup";
    if (fs.stat(CONFIG_PATH) &&
        !command_success_from_args([ "cp", "-a", CONFIG_PATH, cfg_backup ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to back up current config");
    }
    if (fs.stat(PERSISTENT_DIR) &&
        !command_success_from_args([ "cp", "-a", PERSISTENT_DIR, data_backup ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to back up current data");
    }

    if (had_config) {
        let tmp = CONFIG_PATH + ".restored";
        if (!command_success_from_args([ "cp", "-a", staged_config, tmp ]) ||
            !command_success_from_args([ "mv", "-f", tmp, CONFIG_PATH ])) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to write restored config");
        }
        command_success_from_args([ "chmod", "600", CONFIG_PATH ]);
        if (!command_success_from_args([ VALIDATE_BIN, "show", CONFIG_NAME ])) {
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("restored config failed validation; rolled back");
        }
    }

    if (had_data) {
        strip_excluded_dirs(staged_data);
        command_status(command_from_args([ "rm", "-rf", PERSISTENT_DIR ]));
        if (!command_success_from_args([ "cp", "-a", staged_data, PERSISTENT_DIR ])) {
            command_status(command_from_args([ "rm", "-rf", PERSISTENT_DIR ]));
            if (fs.stat(data_backup))
                command_status(command_from_args([ "mv", data_backup, PERSISTENT_DIR ]));
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to write restored data; rolled back");
        }
        if (fs.stat(data_backup) != null)
            preserve_excluded_dirs(data_backup, PERSISTENT_DIR);
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));

    log_message("Config snapshot restored: " + file);
    print(sprintf("%J\n", { success: true }));
    system(common.background_command(command_from_args([ BIN_PATH, "restart" ])));
    return 0;
}

const SENSITIVE_UCI_OPTIONS = {
    bot_token: true,
    yacd_secret_key: true,
    ai_doctor_api_key: true,
    agent_api_token: true,
    access_token: true,
    crypto_key: true,
    private_key: true,
    preshared_key: true,
    server_password: true,
    server_uuid: true,
    mixed_proxy_password: true,
    reality_private_key: true,
    password: true,
    secret: true,
    token: true,
    uuid: true,
    selector_proxy_links: true,
    selector_proxy_links_text: true,
    outbound_json: true,
    outbound_jsons: true,
    warp_flow_uri: true
};

function is_sensitive_uci_key(key) {
    key = lc(as_string(key));
    if (SENSITIVE_UCI_OPTIONS[key])
        return true;
    return index(key, "password") >= 0 ||
        index(key, "secret") >= 0 ||
        index(key, "token") >= 0 ||
        index(key, "private_key") >= 0 ||
        index(key, "crypto_key") >= 0;
}

function mask_uci_secrets(text) {
    let lines = split(as_string(text || ""), "\n");
    let out = [];
    for (let line in lines) {
        let m = match(line, /^([ \t]*(option|list)[ \t]+)([A-Za-z0-9_]+)([ \t]+)(.+)$/);
        if (m != null && is_sensitive_uci_key(m[3])) {
            push(out, m[1] + m[3] + m[4] + "'***'");
        } else {
            push(out, line);
        }
    }
    return join("\n", out);
}

function parse_snapshot_meta(file) {
    let base = substr(file, 0, length(file) - length(".tar.gz"));
    let last_dash = rindex(base, "-");
    let mid_dash = last_dash >= 0 ? rindex(substr(base, 0, last_dash), "-") : -1;
    let name = mid_dash >= 0 ? substr(base, 0, mid_dash) : base;
    let stamp = mid_dash >= 0 ? substr(base, mid_dash + 1) : "";
    return { name: name, stamp: stamp };
}

function snapshot_diff(file) {
    if (!snapshot_file_valid(file))
        return fail("invalid snapshot name");
    let archive = SNAPSHOTS_DIR + "/" + file;
    if (fs.stat(archive) == null)
        return fail("snapshot not found");

    let members_out = command_output_from_args([ "tar", "-tzf", archive ]);
    let members = [];
    for (let line in split(members_out, "\n")) {
        line = trim(line);
        if (line != "")
            push(members, line);
    }
    let safety = backup_archive_safe(members);
    if (!safety.ok)
        return fail("unsafe archive: " + safety.reason);

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-diff.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");
    if (!command_success_from_args([ "tar", "-xzf", archive, "-C", stage ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to extract snapshot archive");
    }

    let staged_config = stage + "/config/" + CONFIG_NAME;
    let snap_raw = fs.readfile(staged_config) || "";
    let curr_raw = fs.readfile(CONFIG_PATH) || "";
    command_status(command_from_args([ "rm", "-rf", stage ]));

    let snap_masked = mask_uci_secrets(snap_raw);
    let curr_masked = mask_uci_secrets(curr_raw);

    let curr_lines = split(curr_masked, "\n");
    let snap_lines = split(snap_masked, "\n");

    let curr_counts = {};
    for (let l in curr_lines) {
        let trimmed = trim(l);
        if (trimmed == "")
            continue;
        curr_counts[l] = int(curr_counts[l] || 0) + 1;
    }

    let snap_counts = {};
    for (let l in snap_lines) {
        let trimmed = trim(l);
        if (trimmed == "")
            continue;
        snap_counts[l] = int(snap_counts[l] || 0) + 1;
    }

    let diff_lines = [];
    let removed_count = 0;
    let added_count = 0;

    let rem_tracker = {};
    for (let l in curr_lines) {
        if (trim(l) == "")
            continue;
        let seen = int(rem_tracker[l] || 0) + 1;
        rem_tracker[l] = seen;
        if (seen > int(snap_counts[l] || 0)) {
            push(diff_lines, "- " + l);
            removed_count++;
        }
    }

    let add_tracker = {};
    for (let l in snap_lines) {
        if (trim(l) == "")
            continue;
        let seen = int(add_tracker[l] || 0) + 1;
        add_tracker[l] = seen;
        if (seen > int(curr_counts[l] || 0)) {
            push(diff_lines, "+ " + l);
            added_count++;
        }
    }

    let meta = parse_snapshot_meta(file);
    print(sprintf("%J\n", {
        success: true,
        file: file,
        name: meta.name,
        stamp: meta.stamp,
        has_changes: (added_count > 0 || removed_count > 0),
        added_count: added_count,
        removed_count: removed_count,
        diff: join("\n", diff_lines)
    }));
    return 0;
}

const ROUTE_BLOCK_TYPES = {
    section: true,
    condition: true,
    balancer: true,
    outbound_source: true,
    outbound_group: true,
    urltest: true,
    priority_group: true,
    priority_level: true
};

function is_route_block_type(stype) {
    return ROUTE_BLOCK_TYPES[as_string(stype)] == true;
}

function parse_uci_blocks(text) {
    let lines = split(as_string(text || ""), "\n");
    let blocks = [];
    let current = null;
    for (let raw_line in lines) {
        let line = replace(as_string(raw_line), /\r$/, "");
        let m = match(line, /^[ \t]*config[ \t]+([A-Za-z0-9_-]+)([ \t]+['"]?([^'" \t\r\n]+)['"]?)?/);
        if (m != null) {
            if (current != null) {
                current.raw = trim(join("\n", current.lines)) + "\n";
                delete current.lines;
                push(blocks, current);
            }
            current = {
                stype: as_string(m[1]),
                sname: as_string(m[3] || ""),
                label: "",
                proxy_links_count: 0,
                lines: [ line ]
            };
        } else if (current != null) {
            push(current.lines, line);
            let opt_m = match(line, /^[ \t]*option[ \t]+(label|name)[ \t]+['"]?([^'"\r\n]+)['"]?/);
            if (opt_m != null && current.label == "")
                current.label = trim(as_string(opt_m[2]));
            if (match(line, /^[ \t]*list[ \t]+proxy_links[ \t]+/) != null)
                current.proxy_links_count++;
        }
    }
    if (current != null) {
        current.raw = trim(join("\n", current.lines)) + "\n";
        delete current.lines;
        push(blocks, current);
    }
    return blocks;
}

function summarize_uci_blocks(blocks, files_map) {
    let counts = {
        sections: 0,
        servers: 0,
        sources: 0,
        balancers: 0,
        conditions: 0,
        groups: 0,
        files: type(files_map) == "object" ? length(keys(files_map)) : 0
    };
    let section_names = [];
    for (let b in blocks) {
        if (b.stype == "section") {
            counts.sections++;
            let disp = b.label != "" ? b.label : b.sname;
            if (disp != "")
                push(section_names, disp);
        } else if (b.stype == "server") {
            counts.servers++;
        } else if (b.stype == "outbound_source") {
            counts.sources++;
            counts.servers += int(b.proxy_links_count || 0);
        } else if (b.stype == "balancer" || b.stype == "urltest" || b.stype == "priority_group") {
            counts.balancers++;
        } else if (b.stype == "condition") {
            counts.conditions++;
        } else if (b.stype == "outbound_group") {
            counts.groups++;
        }
    }
    return { counts: counts, section_names: section_names };
}

const TRANSFER_EXCLUDED_ENTRIES = [
    "keys",
    "tachyon-core-version",
    "tachyon-core-variant",
    "sing-box-version",
    "sing-box-variant",
    "mem_scale",
    "selector_state.json"
];

function is_excluded_transfer_entry(entry_name, scope) {
    entry_name = as_string(entry_name);
    if (is_excluded_data_entry(entry_name))
        return true;
    for (let e in TRANSFER_EXCLUDED_ENTRIES)
        if (entry_name == e)
            return true;
    if (scope == "routes" && (entry_name == "server-certs" || entry_name == "ui-prefs.json"))
        return true;
    return false;
}

function collect_transfer_files(base_dir, rel_prefix, out_map, budget, scope) {
    if (fs.stat(base_dir) == null)
        return;
    let items = fs.lsdir(base_dir);
    if (type(items) != "array")
        return;
    for (let item in items) {
        item = as_string(item);
        if (item == "" || item == "." || item == "..")
            continue;
        if (rel_prefix == "" && is_excluded_transfer_entry(item, scope))
            continue;
        let full = base_dir + "/" + item;
        let rel = rel_prefix == "" ? item : (rel_prefix + "/" + item);
        let st = fs.stat(full);
        if (st == null)
            continue;
        if (st.type == "directory") {
            collect_transfer_files(full, rel, out_map, budget, scope);
        } else if (st.type == "file") {
            let sz = int(st.size || 0);
            if (sz > 0 && sz <= 32768 && (budget.used + sz) <= 65536) {
                let data = fs.readfile(full);
                if (data != null) {
                    out_map[rel] = b64enc(data);
                    budget.used += sz;
                }
            }
        }
    }
}

function base64_to_base64url(b64) {
    let s = replace(as_string(b64 || ""), /\+/g, "-");
    s = replace(s, /\//g, "_");
    s = replace(s, /=+$/, "");
    s = replace(s, /[\r\n \t]/g, "");
    return s;
}

function base64url_to_base64(b64u) {
    let s = replace(as_string(b64u || ""), /[\r\n \t]/g, "");
    s = replace(s, /-/g, "+");
    s = replace(s, /_/g, "/");
    let rem = length(s) % 4;
    if (rem == 2)
        s += "==";
    else if (rem == 3)
        s += "=";
    return s;
}

function rc4_crypt(key, data) {
    key = as_string(key || "");
    data = as_string(data || "");
    let klen = length(key);
    if (klen == 0)
        return data;
    let s = [];
    for (let i = 0; i < 256; i++)
        s[i] = i;
    let j = 0;
    for (let i = 0; i < 256; i++) {
        j = (j + s[i] + ord(key, i % klen)) & 255;
        let tmp = s[i];
        s[i] = s[j];
        s[j] = tmp;
    }
    let i = 0;
    j = 0;
    for (let n = 0; n < 1024; n++) {
        i = (i + 1) & 255;
        j = (j + s[i]) & 255;
        let tmp = s[i];
        s[i] = s[j];
        s[j] = tmp;
    }
    let dlen = length(data);
    let out = [];
    for (let pos = 0; pos < dlen; pos++) {
        i = (i + 1) & 255;
        j = (j + s[i]) & 255;
        let tmp = s[i];
        s[i] = s[j];
        s[j] = tmp;
        let k = s[(s[i] + s[j]) & 255];
        push(out, chr(ord(data, pos) ^ k));
    }
    return join("", out);
}

function generate_transfer_key() {
    let fp = fs.open("/dev/urandom", "r");
    if (fp != null) {
        let rand_bytes = fp.read(16);
        fp.close();
        if (rand_bytes != null && length(rand_bytes) >= 16)
            return base64_to_base64url(b64enc(rand_bytes));
    }
    return base64_to_base64url(b64enc(sprintf("%d-%d-tachyon", time(), clock()[1] || 0)));
}

function upload_encrypted_transfer_blob(cipher_b64u, key_b64u, stage) {
    if (getenv("TACHYON_TRANSFER_OFFLINE_ONLY") == "1")
        return null;
    let relay_dir = trim(as_string(getenv("TACHYON_TRANSFER_RELAY_DIR") || ""));
    if (relay_dir != "") {
        common.ensure_dir(relay_dir);
        let id = substr(key_b64u, 0, 8);
        common.write_file(relay_dir + "/" + id, cipher_b64u);
        return "tachyon://t1/l/" + id + "/" + key_b64u;
    }
    if (getenv("TACHYON_TRANSFER_ONLINE_SHORT") != "1")
        return null;
    let blob_file = stage + "/cipher.txt";
    common.write_file(blob_file, cipher_b64u);

    let dp_out = trim(command_output_from_args([
        "curl", "-k", "-m", "4", "-sS",
        "-A", "Mozilla/5.0",
        "--data-urlencode", "content@" + blob_file,
        "-d", "expiry_days=7",
        "https://dpaste.com/api/v2/"
    ]));
    let dp_m = match(dp_out, /^https:\/\/dpaste\.com\/([A-Za-z0-9]+)/);
    if (dp_m != null)
        return "tachyon://t1/d/" + as_string(dp_m[1]) + "/" + key_b64u;

    let cn_out = trim(command_output_from_args([
        "curl", "-k", "-m", "4", "-sS",
        "-A", "Mozilla/5.0",
        "--upload-file", blob_file,
        "https://paste.c-net.org/"
    ]));
    let cn_m = match(cn_out, /^https:\/\/paste\.c-net\.org\/([A-Za-z0-9]+)/);
    if (cn_m != null)
        return "tachyon://t1/c/" + as_string(cn_m[1]) + "/" + key_b64u;

    return null;
}

function fetch_encrypted_transfer_blob(provider, blob_id) {
    let cache_path = "/tmp/tachyon-transfer-token-cache.json";
    let cache_key = provider + ":" + blob_id;
    if (fs.stat(cache_path) != null) {
        try {
            let cached = json(as_string(fs.readfile(cache_path) || ""));
            if (type(cached) == "object" && as_string(cached.key) == cache_key && type(cached.blob) == "string" && cached.blob != "")
                return trim(cached.blob);
        } catch (e) {}
    }

    let fetched = "";
    if (provider == "l") {
        let relay_dir = trim(as_string(getenv("TACHYON_TRANSFER_RELAY_DIR") || ""));
        if (relay_dir != "" && fs.stat(relay_dir + "/" + blob_id) != null)
            fetched = trim(as_string(fs.readfile(relay_dir + "/" + blob_id) || ""));
    } else if (provider == "d" || provider == "c") {
        let target_url = (provider == "d")
            ? ("https://dpaste.com/" + blob_id + ".txt")
            : ("https://paste.c-net.org/" + blob_id);
        fetched = trim(command_output_from_args([
            "curl", "-k", "-m", "8", "-A", "Mozilla/5.0", "-fsSL",
            target_url
        ]));
        if (fetched == "") {
            fetched = trim(command_output_from_args([
                "curl", "-k", "-m", "8", "-A", "Mozilla/5.0", "-x", "http://127.0.0.1:4534", "-fsSL",
                target_url
            ]));
        }
    }

    if (fetched != "") {
        common.write_json_file(cache_path, { key: cache_key, blob: fetched }, 0);
    }
    return fetched;
}

function encode_transfer_code(payload_obj) {
    let json_text = sprintf("%J", payload_obj);
    let offline_code = "";
    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-code-exp.XXXXXX" ]));
    if (stage != "") {
        let in_file = stage + "/payload.json";
        let gz_file = stage + "/payload.json.gz";
        common.write_file(in_file, json_text);
        if (command_success_from_args([ "gzip", "-f", "-9", in_file ]) && fs.stat(gz_file) != null) {
            let gz_bytes = fs.readfile(gz_file);
            if (gz_bytes != null && gz_bytes != "")
                offline_code = "tachyon://cfg1/" + base64_to_base64url(b64enc(gz_bytes));
        }
        if (offline_code == "")
            offline_code = "tachyon://cfg1u/" + base64_to_base64url(b64enc(json_text));

        let key_b64u = generate_transfer_key();
        let encrypted_bytes = rc4_crypt(key_b64u, "TACH1:" + offline_code);
        let cipher_b64u = base64_to_base64url(b64enc(encrypted_bytes));
        let short_token = upload_encrypted_transfer_blob(cipher_b64u, key_b64u, stage);
        command_status(command_from_args([ "rm", "-rf", stage ]));
        if (short_token != null && short_token != "")
            return short_token;
        return offline_code;
    }
    return "tachyon://cfg1u/" + base64_to_base64url(b64enc(json_text));
}

function decode_transfer_code(raw_code) {
    let s = trim(as_string(raw_code || ""));
    if (substr(s, 0, 1) == "{") {
        try {
            let wrapper = json(s);
            if (type(wrapper) == "object") {
                if (type(wrapper.code) == "string")
                    s = trim(wrapper.code);
                else if (type(wrapper.transfer_code) == "string")
                    s = trim(wrapper.transfer_code);
            }
        } catch (e) {}
    }
    s = replace(s, /^['"]+|['"]+$/g, "");
    s = trim(s);

    if (substr(s, 0, 13) == "tachyon://t1/") {
        let tok_m = match(substr(s, 13), /^([dcl])\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/);
        if (tok_m == null)
            return { ok: false, error: "invalid short transfer token format" };
        let provider = as_string(tok_m[1]);
        let blob_id = as_string(tok_m[2]);
        let key_b64u = as_string(tok_m[3]);
        let cipher_b64u = fetch_encrypted_transfer_blob(provider, blob_id);
        if (cipher_b64u == "")
            return { ok: false, error: "unable to fetch transfer token payload (expired or unreachable)" };
        let cipher_bytes = null;
        try {
            cipher_bytes = b64dec(base64url_to_base64(cipher_b64u));
        } catch (e) {
            cipher_bytes = null;
        }
        if (cipher_bytes == null || cipher_bytes == "")
            return { ok: false, error: "corrupted encrypted payload for transfer token" };
        let plain = rc4_crypt(key_b64u, cipher_bytes);
        if (substr(plain, 0, 6) != "TACH1:")
            return { ok: false, error: "invalid transfer token key or corrupted payload" };
        s = substr(plain, 6);
    }

    let compressed = false;
    let b64u = "";
    if (substr(s, 0, 15) == "tachyon://cfg1/") {
        compressed = true;
        b64u = substr(s, 15);
    } else if (substr(s, 0, 16) == "tachyon://cfg1u/") {
        compressed = false;
        b64u = substr(s, 16);
    } else {
        return { ok: false, error: "invalid transfer code prefix (expected tachyon://cfg1/...)" };
    }

    if (b64u == "")
        return { ok: false, error: "empty transfer code payload" };

    let raw_bytes = null;
    try {
        raw_bytes = b64dec(base64url_to_base64(b64u));
    } catch (e) {
        raw_bytes = null;
    }
    if (raw_bytes == null || raw_bytes == "")
        return { ok: false, error: "corrupted base64 in transfer code" };

    let json_text = "";
    if (compressed) {
        let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-code-dec.XXXXXX" ]));
        if (stage == "")
            return { ok: false, error: "unable to create temporary directory" };
        let gz_file = stage + "/payload.json.gz";
        let out_file = stage + "/payload.json";
        common.write_file(gz_file, raw_bytes);
        if (!command_success_from_args([ "gzip", "-d", "-f", gz_file ]) || fs.stat(out_file) == null) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return { ok: false, error: "unable to decompress transfer code" };
        }
        json_text = as_string(fs.readfile(out_file) || "");
        command_status(command_from_args([ "rm", "-rf", stage ]));
    } else {
        json_text = as_string(raw_bytes);
    }

    let parsed = null;
    try {
        parsed = json(json_text);
    } catch (e) {
        parsed = null;
    }
    if (type(parsed) != "object" || as_string(parsed.format || "") != "tachyon-transfer-v1")
        return { ok: false, error: "unsupported transfer code format" };

    let uci_text = as_string(parsed.uci_text || "");
    let blocks = parse_uci_blocks(uci_text);
    if (length(blocks) == 0)
        return { ok: false, error: "transfer code contains no UCI sections" };

    let scope = as_string(parsed.scope || "routes");
    if (scope != "full" && scope != "routes")
        scope = "routes";

    let files_map = type(parsed.files) == "object" ? parsed.files : {};
    for (let rel_path, _val in files_map) {
        let rel = as_string(rel_path);
        if (rel == "" || substr(rel, 0, 1) == "/" || match(rel, /(^|\/)\.\.(\/|$)/) != null)
            return { ok: false, error: "unsafe file path in transfer code: " + rel };
    }

    return {
        ok: true,
        scope: scope,
        created_at: int(parsed.created_at || 0),
        uci_text: uci_text,
        blocks: blocks,
        files: files_map,
        summary: summarize_uci_blocks(blocks, files_map)
    };
}

function snapshot_code_export(scope) {
    scope = lc(trim(as_string(scope || "routes")));
    if (scope != "full")
        scope = "routes";

    if (fs.stat(CONFIG_PATH) == null)
        return fail("config file not found");
    let raw_cfg = as_string(fs.readfile(CONFIG_PATH) || "");
    let all_blocks = parse_uci_blocks(raw_cfg);
    let selected_blocks = [];
    let selected_raw_parts = [];
    for (let b in all_blocks) {
        if (scope == "full" || is_route_block_type(b.stype)) {
            push(selected_blocks, b);
            push(selected_raw_parts, b.raw);
        }
    }
    if (length(selected_blocks) == 0)
        return fail("no configuration sections found for export");

    let uci_text = join("\n", selected_raw_parts);
    let files_map = {};
    collect_transfer_files(PERSISTENT_DIR, "", files_map, { used: 0 }, scope);
    let summary = summarize_uci_blocks(selected_blocks, files_map);
    let now_ts = time();

    let payload = {
        format: "tachyon-transfer-v1",
        scope: scope,
        created_at: now_ts,
        uci_text: uci_text,
        files: files_map
    };

    let code = encode_transfer_code(payload);
    let code_len = length(code);
    let export_record = {
        format: "tachyon-profile-v1",
        transfer_code: code,
        code: code,
        scope: scope,
        created_at: now_ts,
        length: code_len,
        counts: summary.counts,
        section_names: summary.section_names
    };

    if (EXPORT_TMP_FILE != "") {
        common.write_json_file(EXPORT_TMP_FILE, export_record, 2);
        command_success_from_args([ "chmod", "600", EXPORT_TMP_FILE ]);
    }
    let ui_state_dir = (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/ui-state";
    if (getenv("TACHYON_SNAPSHOT_EXPORT_FILE") == null) {
        common.ensure_dir(ui_state_dir);
        common.write_json_file(ui_state_dir + "/snapshot-export.json", export_record, 2);
    }

    let chunked_only = code_len > 38000;
    print(sprintf("%J\n", {
        success: true,
        scope: scope,
        created_at: now_ts,
        chunked_export: chunked_only,
        code: chunked_only ? "" : code,
        length: code_len,
        counts: summary.counts,
        section_names: summary.section_names
    }));
    return 0;
}

function read_transfer_code_arg(arg, keep_file) {
    arg = trim(as_string(arg || ""));
    if (arg == "")
        return "";
    if (substr(arg, 0, 10) == "tachyon://")
        return arg;
    if (fs.stat(arg) != null) {
        let content = trim(as_string(fs.readfile(arg) || ""));
        if (!keep_file && arg == "/tmp/tachyon-snapshot-import.json") {
            try { fs.unlink(arg); } catch (e) {}
        }
        return content;
    }
    return arg;
}

function snapshot_code_inspect(arg) {
    let raw_code = read_transfer_code_arg(arg, true);
    if (raw_code == "")
        return fail("transfer code is empty");
    let decoded = decode_transfer_code(raw_code);
    if (!decoded.ok)
        return fail(decoded.error);
    print(sprintf("%J\n", {
        success: true,
        scope: decoded.scope,
        created_at: decoded.created_at,
        counts: decoded.summary.counts,
        section_names: decoded.summary.section_names
    }));
    return 0;
}

function snapshot_code_apply(apply_mode, arg) {
    apply_mode = lc(trim(as_string(apply_mode || "replace")));
    if (apply_mode != "merge")
        apply_mode = "replace";

    let raw_code = read_transfer_code_arg(arg, false);
    if (raw_code == "")
        return fail("transfer code is empty");
    let decoded = decode_transfer_code(raw_code);
    if (!decoded.ok)
        return fail(decoded.error);

    let curr_raw = fs.stat(CONFIG_PATH) != null ? as_string(fs.readfile(CONFIG_PATH) || "") : "";
    let curr_blocks = parse_uci_blocks(curr_raw);
    let final_blocks = [];

    if (apply_mode == "replace") {
        if (decoded.scope == "full") {
            final_blocks = decoded.blocks;
        } else {
            let had_settings = false;
            for (let b in curr_blocks) {
                if (b.stype == "settings")
                    had_settings = true;
                if (!is_route_block_type(b.stype))
                    push(final_blocks, b);
            }
            if (!had_settings) {
                push(final_blocks, {
                    stype: "settings",
                    sname: "settings",
                    label: "",
                    raw: "config settings 'settings'\n\toption enabled '1'\n"
                });
            }
            for (let b in decoded.blocks) {
                if (is_route_block_type(b.stype))
                    push(final_blocks, b);
            }
        }
    } else {
        // merge mode: keep existing blocks, update matching (stype, sname) in-place, append new ones
        let incoming_by_key = {};
        for (let b in decoded.blocks) {
            if (b.stype == "settings" && decoded.scope != "full" && length(curr_blocks) > 0)
                continue;
            if (b.sname != "")
                incoming_by_key[b.stype + ":" + b.sname] = b;
        }
        let replaced_keys = {};
        for (let b in curr_blocks) {
            let key = b.sname != "" ? (b.stype + ":" + b.sname) : "";
            if (key != "" && incoming_by_key[key] != null) {
                push(final_blocks, incoming_by_key[key]);
                replaced_keys[key] = true;
            } else {
                push(final_blocks, b);
            }
        }
        for (let b in decoded.blocks) {
            if (b.stype == "settings" && decoded.scope != "full" && length(curr_blocks) > 0)
                continue;
            let key = b.sname != "" ? (b.stype + ":" + b.sname) : "";
            if (key == "" || !replaced_keys[key])
                push(final_blocks, b);
        }
    }

    let raw_parts = [];
    for (let b in final_blocks)
        push(raw_parts, b.raw);
    let merged_uci_text = join("\n", raw_parts);

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-code-apply.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");

    let staged_cfg = stage + "/tachyon.cfg";
    common.write_file(staged_cfg, merged_uci_text);
    if (!config_sane_preview(staged_cfg)) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("merged config does not look like a valid UCI file");
    }

    let cfg_backup = stage + "/cfg_backup";
    if (fs.stat(CONFIG_PATH) != null && !command_success_from_args([ "cp", "-a", CONFIG_PATH, cfg_backup ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to back up current config");
    }

    let tmp_cfg = CONFIG_PATH + ".transfer-tmp";
    if (!command_success_from_args([ "cp", "-a", staged_cfg, tmp_cfg ]) ||
        !command_success_from_args([ "mv", "-f", tmp_cfg, CONFIG_PATH ])) {
        restore_config_from_backup(cfg_backup);
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to write transferred config");
    }
    command_success_from_args([ "chmod", "600", CONFIG_PATH ]);
    if (!command_success_from_args([ VALIDATE_BIN, "show", CONFIG_NAME ])) {
        restore_config_from_backup(cfg_backup);
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("transferred config failed UCI validation; rolled back");
    }

    if (type(decoded.files) == "object" && length(keys(decoded.files)) > 0) {
        common.ensure_dir(PERSISTENT_DIR);
        for (let rel_path, b64_content in decoded.files) {
            let rel = as_string(rel_path);
            if (rel == "" || substr(rel, 0, 1) == "/" || match(rel, /(^|\/)\.\.(\/|$)/) != null)
                continue;
            let file_bytes = null;
            try {
                file_bytes = b64dec(as_string(b64_content));
            } catch (e) {
                file_bytes = null;
            }
            if (file_bytes != null) {
                let dst_path = PERSISTENT_DIR + "/" + rel;
                common.ensure_dir(common.parent_dir(dst_path));
                common.write_file(dst_path, file_bytes);
            }
        }
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));
    let final_summary = summarize_uci_blocks(final_blocks, decoded.files);
    log_message("Config transfer code applied (" + apply_mode + ", scope=" + decoded.scope + ")");
    print(sprintf("%J\n", {
        success: true,
        mode: apply_mode,
        scope: decoded.scope,
        counts: decoded.summary.counts,
        total_counts: final_summary.counts,
        section_names: decoded.summary.section_names
    }));
    command_status(common.background_command(command_from_args([ BIN_PATH, "restart" ])));
    return 0;
}

function snapshot_export(file) {
    let raw_arg = as_string(file || "");
    if (substr(raw_arg, 0, 2) == "--")
        raw_arg = substr(raw_arg, 2);
    if (raw_arg == "code:routes" || raw_arg == "code:full")
        return snapshot_code_export(substr(raw_arg, 5));
    if (substr(raw_arg, 0, 11) == "read-chunk:") {
        let rest = substr(raw_arg, 11);
        let parts = split(rest, ":");
        let offset = int(parts[0] || 0);
        let len = int(parts[1] || 32768);
        if (offset < 0)
            offset = 0;
        if (len <= 0 || len > 45000)
            len = 32768;
        let full_text = as_string(fs.readfile(EXPORT_TMP_FILE) || "");
        if (full_text == "")
            return fail("export file not found");
        let total_len = length(full_text);
        let chunk = offset < total_len ? substr(full_text, offset, len) : "";
        print(sprintf("%J\n", {
            success: true,
            chunk: chunk,
            offset: offset,
            total: total_len,
            eof: (offset + length(chunk) >= total_len)
        }));
        return 0;
    }

    if (!snapshot_file_valid(file))
        return fail("invalid snapshot name");
    let archive = SNAPSHOTS_DIR + "/" + file;
    if (fs.stat(archive) == null)
        return fail("snapshot not found");

    compact_bloated_snapshot_if_needed(archive);

    let members_out = command_output_from_args([ "tar", "-tzf", archive ]);
    let members = [];
    for (let line in split(members_out, "\n")) {
        line = trim(line);
        if (line != "")
            push(members, line);
    }
    let safety = backup_archive_safe(members);
    if (!safety.ok)
        return fail("unsafe archive: " + safety.reason);

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-export.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");
    if (!command_success_from_args([ "tar", "-xzf", archive, "-C", stage ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to extract snapshot archive");
    }

    let staged_config = stage + "/config/" + CONFIG_NAME;
    let config_text = as_string(fs.readfile(staged_config) || "");

    let staged_data = stage + "/" + CONFIG_NAME;
    strip_excluded_dirs(staged_data);

    let clean_tar = stage + "/clean-export.tar.gz";
    let tar_args = [ "tar", "-czf", clean_tar, "-C", stage ];
    if (fs.stat(staged_config) != null)
        push(tar_args, "config/" + CONFIG_NAME);
    if (fs.stat(staged_data) != null)
        push(tar_args, CONFIG_NAME);

    let raw_archive = null;
    if (length(tar_args) > 5 && command_success_from_args(tar_args))
        raw_archive = fs.readfile(clean_tar);
    if (raw_archive == null)
        raw_archive = fs.readfile(archive);

    command_status(command_from_args([ "rm", "-rf", stage ]));

    let archive_b64 = raw_archive != null ? b64enc(raw_archive) : "";
    let meta = parse_snapshot_meta(file);

    let profile = {
        format: "tachyon-profile-v1",
        name: meta.name,
        stamp: meta.stamp,
        file: file,
        created_at: time(),
        config_text: config_text,
        archive_base64: archive_b64
    };

    if (EXPORT_TMP_FILE != "") {
        common.write_json_file(EXPORT_TMP_FILE, profile, 2);
        command_success_from_args([ "chmod", "600", EXPORT_TMP_FILE ]);
    }
    let ui_state_dir = (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/ui-state";
    if (getenv("TACHYON_SNAPSHOT_EXPORT_FILE") == null) {
        common.ensure_dir(ui_state_dir);
        common.write_json_file(ui_state_dir + "/snapshot-export.json", profile, 2);
    }

    let stdout_profile = profile;
    let chunked_only = false;
    if (archive_b64 != "" && (length(archive_b64) + length(config_text)) > 42000) {
        if (length(archive_b64) <= 50000) {
            stdout_profile = {
                format: "tachyon-profile-v1",
                name: meta.name,
                stamp: meta.stamp,
                file: file,
                created_at: profile.created_at,
                config_text: "",
                archive_base64: archive_b64
            };
        } else {
            chunked_only = true;
            stdout_profile = {
                format: "tachyon-profile-v1",
                name: meta.name,
                stamp: meta.stamp,
                file: file,
                created_at: profile.created_at,
                chunked_export: true
            };
        }
    }

    print(sprintf("%J\n", {
        success: true,
        export_file: EXPORT_TMP_FILE,
        chunked_export: chunked_only,
        profile: stdout_profile
    }));
    return 0;
}

function snapshot_import(source_arg) {
    source_arg = as_string(source_arg || "");
    if (source_arg == "")
        return fail("snapshot import payload or file path required");

    let chunk_tmp_path = "/tmp/tachyon-snapshot-import.json";
    let norm_arg = substr(source_arg, 0, 2) == "--" ? substr(source_arg, 2) : source_arg;
    if (norm_arg == "chunk-init") {
        try { fs.unlink(chunk_tmp_path); } catch (e) {}
        fs.writefile(chunk_tmp_path, "");
        command_success_from_args([ "chmod", "600", chunk_tmp_path ]);
        print(sprintf("%J\n", { success: true }));
        return 0;
    }
    if (substr(norm_arg, 0, 13) == "chunk-append:") {
        let b64_part = substr(norm_arg, 13);
        let decoded_part = null;
        try {
            decoded_part = b64dec(b64_part);
        } catch (e) {
            decoded_part = null;
        }
        if (decoded_part == null)
            return fail("invalid base64 chunk");
        let fp = fs.open(chunk_tmp_path, "a");
        if (fp == null)
            return fail("unable to open chunk buffer");
        fp.write(decoded_part);
        fp.close();
        print(sprintf("%J\n", { success: true }));
        return 0;
    }
    if (substr(norm_arg, 0, 13) == "code-inspect:")
        return snapshot_code_inspect(substr(norm_arg, 13));
    if (substr(norm_arg, 0, 19) == "code-apply:replace:")
        return snapshot_code_apply("replace", substr(norm_arg, 19));
    if (substr(norm_arg, 0, 17) == "code-apply:merge:")
        return snapshot_code_apply("merge", substr(norm_arg, 17));
    if (substr(trim(norm_arg), 0, 10) == "tachyon://")
        return snapshot_code_apply("replace", trim(norm_arg));

    let raw = "";
    if (source_arg == "-") {
        raw = as_string(fs.stdin.read("all") || "");
    } else if (substr( trim(source_arg), 0, 1) == "{") {
        raw = source_arg;
    } else {
        if (fs.stat(source_arg) == null)
            return fail("import file not found");
        raw = as_string(fs.readfile(source_arg) || "");
        if (source_arg == "/tmp/tachyon-snapshot-import.json") {
            try { fs.unlink(source_arg); } catch (e) {}
        }
    }

    if (substr(trim(raw), 0, 10) == "tachyon://")
        return snapshot_code_apply("replace", trim(raw));

    let parsed = null;
    try {
        parsed = json(raw);
    } catch (e) {
        parsed = null;
    }
    if (type(parsed) != "object")
        return fail("invalid snapshot profile JSON");

    let profile = type(parsed.profile) == "object" ? parsed.profile : parsed;
    if (as_string(profile.format || "") != "tachyon-profile-v1")
        return fail("unsupported snapshot profile format");

    let safe_name = snapshot_name_safe(profile.name || "imported");
    if (safe_name == null)
        safe_name = "imported";

    if (!command_success_from_args([ "mkdir", "-p", SNAPSHOTS_DIR ]))
        return fail("unable to create snapshots directory");

    let stamp = snapshot_stamp();
    if (!match(stamp, /^[0-9]{8}-[0-9]{6}$/))
        stamp = "20260101-000000";
    let target_file = SNAPSHOTS_DIR + "/" + safe_name + "-" + stamp + ".tar.gz";

    let stage = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-snapshot-import.XXXXXX" ]));
    if (stage == "")
        return fail("unable to create staging directory");

    let archive_b64 = trim(as_string(profile.archive_base64 || ""));
    let config_text = as_string(profile.config_text || "");

    if (archive_b64 != "") {
        let decoded = null;
        try {
            decoded = b64dec(archive_b64);
        } catch (e) {
            decoded = null;
        }
        if (decoded == null || decoded == "") {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("invalid archive_base64 in profile");
        }
        let tmp_tar = stage + "/imported.tar.gz";
        fs.writefile(tmp_tar, decoded);
        let members_out = command_output_from_args([ "tar", "-tzf", tmp_tar ]);
        let members = [];
        for (let line in split(members_out, "\n")) {
            line = trim(line);
            if (line != "")
                push(members, line);
        }
        if (length(members) == 0) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("imported archive is empty or corrupt");
        }
        let safety = backup_archive_safe(members);
        if (!safety.ok) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unsafe archive: " + safety.reason);
        }
        let extract_dir = stage + "/extract";
        command_success_from_args([ "mkdir", "-p", extract_dir ]);
        if (!command_success_from_args([ "tar", "-xzf", tmp_tar, "-C", extract_dir ])) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to extract imported archive");
        }
        let extracted_cfg = extract_dir + "/config/" + CONFIG_NAME;
        if (fs.stat(extracted_cfg) != null && !config_sane_preview(extracted_cfg)) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("imported config does not look like a valid UCI file");
        }
        let extracted_data = extract_dir + "/" + CONFIG_NAME;
        strip_excluded_dirs(extracted_data);
        let repack_args = [ "tar", "-czf", tmp_tar, "-C", extract_dir ];
        if (fs.stat(extracted_cfg) != null)
            push(repack_args, "config/" + CONFIG_NAME);
        if (fs.stat(extracted_data) != null)
            push(repack_args, CONFIG_NAME);
        if (length(repack_args) > 5)
            command_success_from_args(repack_args);
        if (!command_success_from_args([ "mv", "-f", tmp_tar, target_file ])) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to save imported snapshot");
        }
    } else if (config_text != "") {
        let cfg_dir = stage + "/config";
        let data_dir = stage + "/" + CONFIG_NAME;
        command_success_from_args([ "mkdir", "-p", cfg_dir, data_dir ]);
        let staged_cfg = cfg_dir + "/" + CONFIG_NAME;
        fs.writefile(staged_cfg, config_text);
        if (!config_sane_preview(staged_cfg)) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("imported config does not look like a valid UCI file");
        }
        if (!command_success_from_args([ "tar", "-czf", target_file, "-C", stage, "config/" + CONFIG_NAME, CONFIG_NAME ])) {
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to package imported snapshot");
        }
    } else {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("snapshot profile contains neither archive_base64 nor config_text");
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));
    command_success_from_args([ "chmod", "600", target_file ]);
    prune_snapshots();

    log_message("Config snapshot imported: " + safe_name);
    print(sprintf("%J\n", {
        success: true,
        file: common.path_basename(target_file),
        name: safe_name
    }));
    return 0;
}

let mode = as_string(ARGV[0]);

if (mode == "snapshot-save") {
    let name = as_string(ARGV[1]);
    if (name == "")
        exit(fail("snapshot name required"));
    exit(snapshot_save(name));
}

if (mode == "snapshot-list") {
    print(sprintf("%J\n", { success: true, snapshots: snapshot_list() }));
    exit(0);
}

if (mode == "snapshot-restore") {
    let file = as_string(ARGV[1]);
    if (file == "")
        exit(fail("snapshot file required"));
    exit(snapshot_restore(file));
}

if (mode == "snapshot-delete") {
    let file = as_string(ARGV[1]);
    if (file == "")
        exit(fail("snapshot file required"));
    exit(snapshot_delete(file));
}

if (mode == "snapshot-diff") {
    let file = as_string(ARGV[1]);
    if (file == "")
        exit(fail("snapshot file required"));
    exit(snapshot_diff(file));
}

if (mode == "snapshot-export") {
    let file = as_string(ARGV[1]);
    if (file == "")
        exit(fail("snapshot file required"));
    exit(snapshot_export(file));
}

if (mode == "snapshot-import") {
    let source_arg = as_string(ARGV[1]);
    if (source_arg == "")
        exit(fail("snapshot import payload or file path required"));
    exit(snapshot_import(source_arg));
}

warn("Usage: service/snapshot.uc snapshot-list|snapshot-save <name>|snapshot-restore <file>|snapshot-delete <file>|snapshot-diff <file>|snapshot-export <file>|snapshot-import <file|json>\n");
exit(1);
