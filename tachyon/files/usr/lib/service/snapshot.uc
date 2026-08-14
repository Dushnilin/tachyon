#!/usr/bin/env ucode

// Config snapshots: save / list / restore / delete working configs so the user
// can roll back from LuCI's advanced settings. A snapshot is a tar.gz of
// config/<name> + <name>/ under the config root — the same member layout as
// the Telegram backup, so snapshot archives can be restored there too.

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_status(command) {
    return normalize_status(system(command + " >/dev/null 2>&1"));
}

function command_success_from_args(args) {
    return command_status(command_from_args(args)) == 0;
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

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
    return match(as_string(file), /^[A-Za-z0-9_\-]+-[0-9]{14}\.tar\.gz$/) != null;
}

function backup_archive_safe(members) {
    for (let m in members) {
        if (substr(m, 0, 1) == "/") return { ok: false, reason: "absolute path: " + m };
        if (match(m, /\.\./)) return { ok: false, reason: "path traversal: " + m };
        if (m != "config/" + CONFIG_NAME && !match(m, "^" + CONFIG_NAME + "/"))
            return { ok: false, reason: "unexpected member: " + m };
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

function snapshot_save(name) {
    let safe = snapshot_name_safe(name);
    if (safe == null)
        return fail("invalid snapshot name");
    if (!command_success_from_args([ "mkdir", "-p", SNAPSHOTS_DIR ]))
        return fail("unable to create snapshots directory");
    if (fs.stat(CONFIG_PATH) == null)
        return fail("config file not found");

    let file = SNAPSHOTS_DIR + "/" + safe + "-" + snapshot_stamp() + ".tar.gz";
    if (!command_success_from_args([ "tar", "-czf", file, "-C", CONFIG_ROOT, "config/" + CONFIG_NAME, CONFIG_NAME ])) {
        command_success_from_args([ "rm", "-f", file ]);
        return fail("unable to create snapshot archive");
    }
    command_success_from_args([ "chmod", "600", file ]);
    prune_snapshots();

    log_message("Config snapshot saved: " + safe);
    print(sprintf("%J\n", { success: true, file: basename(file) }));
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
        if (fs.stat(full) == null)
            continue;
        let size = int(command_output_from_args([ "stat", "-c", "%s", full ]));
        let base = substr(line, 0, length(line) - length(".tar.gz"));
        let dash = index(base, "-");
        let name = dash >= 0 ? substr(base, 0, dash) : base;
        let stamp = dash >= 0 ? substr(base, dash + 1) : "";
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

    let stamp = as_string(time()) + "-" + sprintf("%04x", clock()[1] & 0xFFFF);
    let cfg_backup = SNAPSHOTS_DIR + "/restore_cfg_backup." + stamp;
    let data_backup = SNAPSHOTS_DIR + "/restore_data_backup." + stamp;
    if (fs.stat(CONFIG_PATH) &&
        !command_success_from_args([ "cp", "-a", CONFIG_PATH, cfg_backup ])) {
        command_status(command_from_args([ "rm", "-rf", stage ]));
        return fail("unable to back up current config");
    }
    if (fs.stat(PERSISTENT_DIR) &&
        !command_success_from_args([ "cp", "-a", PERSISTENT_DIR, data_backup ])) {
        command_status(command_from_args([ "rm", "-f", cfg_backup ]));
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
            command_status(command_from_args([ "rm", "-rf", stage, data_backup ]));
            command_status(command_from_args([ "rm", "-f", cfg_backup ]));
            return fail("restored config failed validation; rolled back");
        }
    }

    if (had_data) {
        command_status(command_from_args([ "rm", "-rf", PERSISTENT_DIR ]));
        if (!command_success_from_args([ "cp", "-a", staged_data, PERSISTENT_DIR ])) {
            command_status(command_from_args([ "rm", "-rf", PERSISTENT_DIR ]));
            if (fs.stat(data_backup))
                command_status(command_from_args([ "mv", data_backup, PERSISTENT_DIR ]));
            restore_config_from_backup(cfg_backup);
            command_status(command_from_args([ "rm", "-rf", stage ]));
            return fail("unable to write restored data; rolled back");
        }
    }

    command_status(command_from_args([ "rm", "-rf", stage ]));
    command_status(command_from_args([ "rm", "-f", cfg_backup ]));
    command_status(command_from_args([ "rm", "-rf", data_backup ]));

    log_message("Config snapshot restored: " + file);
    print(sprintf("%J\n", { success: true }));
    command_success_from_args([ BIN_PATH, "restart" ]);
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

warn("Usage: service/snapshot.uc snapshot-list|snapshot-save <name>|snapshot-restore <file>|snapshot-delete <file>\n");
exit(1);
