#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");
let core_ip = require("core.ip");
let core_url = require("core.url");

let common = require("core.common");
let as_string = common.as_string;
let shell_quote = common.shell_quote;
let remove_file = common.remove_file;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const HOSTS_CACHE_DIR = getenv("TACHYON_HOSTS_CACHE_DIR") || "/etc/tachyon/hosts-lists";
const HOSTS_CACHE_FILE = HOSTS_CACHE_DIR + "/combined.txt";
const HOSTS_TMP_DIR = getenv("TACHYON_HOSTS_TMP_DIR") || "/tmp/tachyon/hosts-lists";
const CONNECT_TIMEOUT = "30";

function run(command) {
    return system(command) == 0;
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("tachyon-hosts") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function mkdir_p(path) {
    run("mkdir -p " + shell_quote(path));
}

function file_nonempty(path) {
    let st = fs.stat(path);
    return st != null && int(st.size) > 0;
}

function opt(section, key, default_value) {
    let v = section[key];
    if (v == null) return default_value;
    return v;
}

function bool_opt(section, key, default_value) {
    let v = section[key];
    if (v == null) return default_value;
    return v == "1" || v == "true";
}

function enabled_hosts_sections() {
    let result = [];
    let cursor = uci.cursor();
    if (!cursor) return result;
    try {
        cursor.foreach(CONFIG_NAME, "section", function(section) {
            if (opt(section, ".type", "") != "section") return;
            if (opt(section, "action", "") != "hosts") return;
            if (!bool_opt(section, "enabled", true)) return;
            push(result, section);
        });
    }
    catch (e) {
        // A UCI parse error leaves `result` holding whatever sections were
        // pushed before the throw. Returning the partial list is the same
        // behaviour as an empty config and keeps the caller on its no-hosts
        // path; the parse error itself is reported by uci to the system log.
    }
    return result;
}

function http_get_to_file(url, output_path) {
    run("mkdir -p " + shell_quote(HOSTS_TMP_DIR));
    let cmd = "wget -q -O " + shell_quote(output_path) + " --timeout=" + CONNECT_TIMEOUT + " " + shell_quote(url) + " 2>&1";
    log("Running: " + cmd);
    let result = run(cmd);
    log("wget exit: " + as_string(result) + " file_exists: " + as_string(fs.stat(output_path) != null));
    return result;
}

function download_with_retry(url, output_path, label) {
    let candidates = core_url.download_candidates(url);

    for (let attempt = 0; attempt < length(candidates); attempt++) {
        let current_url = candidates[attempt];
        if (attempt == 0) {
            log("Downloading " + as_string(label) + " (attempt 1/" + as_string(length(candidates)) + ")");
        } else {
            log("Retrying " + as_string(label) + " via mirror (attempt " + as_string(attempt + 1) + "/" + as_string(length(candidates)) + ")", "warn");
        }

        if (http_get_to_file(current_url, output_path) && file_nonempty(output_path))
            return output_path;
        remove_file(output_path);
    }
    return null;
}

function parse_hosts_file(path) {
    let entries = [];
    let fh = null;
    try {
        fh = fs.open(path, "r");
        if (fh == null)
            return entries;

        let line;
        while ((line = fh.read("line")) != null) {
            line = trim(line);
            if (line == "" || substr(line, 0, 1) == "#")
                continue;

            let parts = split(line, /[ \t]+/);
            if (length(parts) < 2)
                continue;

            let p1 = parts[0];
            let p2 = parts[1];

            if (core_ip.valid_ip(p1)) {
                let ip = p1;
                for (let i = 1; i < length(parts); i++) {
                    let domain = parts[i];
                    if (domain != "" && substr(domain, 0, 1) != "#" && index(domain, ":") == -1)
                        push(entries, { ip: ip, domain: domain });
                }
            } else if (core_ip.valid_ip(p2)) {
                let domain = p1;
                let ip = p2;
                if (index(domain, ":") == -1)
                    push(entries, { ip: ip, domain: domain });
            }
        }
    } catch(e) {
        log("Error parsing hosts file " + path + ": " + as_string(e), "error");
    }
    if (fh) fh.close();
    return entries;
}

function write_hosts_cache(entries, source_urls) {
    mkdir_p(HOSTS_CACHE_DIR);

    let tmp_path = HOSTS_CACHE_FILE + ".tmp." + as_string(getpid());
    let fh = fs.open(tmp_path, "w");
    if (fh == null) {
        log("Failed to open " + tmp_path + " for writing", "error");
        return false;
    }

    fh.write("# Tachyon hosts lists — combined cache\n");
    if (source_urls != null) {
        for (let url in source_urls)
            fh.write("# Source: " + url + "\n");
    }
    fh.write("# Entries: " + length(entries) + "\n");
    fh.write("#\n");

    for (let entry in entries)
        fh.write(entry.ip + " " + entry.domain + "\n");

    fh.close();
    run("mv " + shell_quote(tmp_path) + " " + shell_quote(HOSTS_CACHE_FILE));
    log("Wrote " + length(entries) + " hosts entries to " + HOSTS_CACHE_FILE);
    return true;
}

function get_hosts_urls() {
    let urls = [];
    let disabled = [];
    for (let section in enabled_hosts_sections()) {
        let section_urls = opt(section, "hosts_list_urls", "");
        if (type(section_urls) == "array") {
            for (let url in section_urls) {
                let s = trim(url);
                if (s != "") push(urls, s);
            }
        } else if (section_urls != null && section_urls != "") {
            push(urls, trim(section_urls));
        }

        let section_disabled = opt(section, "hosts_list_disabled", "");
        if (type(section_disabled) == "array") {
            for (let d in section_disabled) {
                let s = trim(d);
                if (s != "") push(disabled, s);
            }
        } else if (section_disabled != null && section_disabled != "") {
            push(disabled, trim(section_disabled));
        }
    }

    let is_disabled = function(url) {
        for (let d in disabled)
            if (d == url) return true;
        return false;
    };

    let result = [];
    for (let url in urls) {
        if (!is_disabled(url))
            push(result, url);
    }
    return result;
}

function hosts_list_update(target_url) {
    let urls = target_url != null && target_url != "" ? [target_url] : get_hosts_urls();
    if (length(urls) == 0) {
        log("No hosts list URLs configured", "warn");
        print('{"success":false,"error":"no_urls","entries":0}');
        return false;
    }

    mkdir_p(HOSTS_TMP_DIR);

    let all_entries = [];
    let updated_urls = [];

    for (let url in urls) {
        let label = "hosts list from " + url;
        let safe_name = replace(replace(url, /:/g, "_"), /[^a-zA-Z0-9_]/g, "_");
        let tmp_file = HOSTS_TMP_DIR + "/list-" + safe_name + ".txt";

        if (download_with_retry(url, tmp_file, label) != null) {
            let entries = parse_hosts_file(tmp_file);
            log("Parsed " + length(entries) + " entries from " + url);
            for (let entry in entries)
                push(all_entries, entry);
            push(updated_urls, url);
        } else {
            log("Failed to download hosts list from " + url, "error");
        }
        remove_file(tmp_file);
    }

    if (length(all_entries) == 0) {
        log("No valid hosts entries found in any list", "error");
        print('{"success":false,"error":"empty","entries":0}');
        return false;
    }

    if (!write_hosts_cache(all_entries, updated_urls)) {
        print('{"success":false,"error":"write_failed","entries":0}');
        return false;
    }

    log("Hosts lists updated: " + length(all_entries) + " entries from " + length(updated_urls) + " sources");

    print('{"success":true,"entries":' + length(all_entries) + ',"sources":' + length(updated_urls) + '}');
    return true;
}

function hosts_list_status() {
    let active_urls = get_hosts_urls();
    let all_urls = [];
    for (let section in enabled_hosts_sections()) {
        let section_urls = opt(section, "hosts_list_urls", "");
        if (type(section_urls) == "array") {
            for (let url in section_urls) {
                let s = trim(url);
                if (s != "") push(all_urls, s);
            }
        } else if (section_urls != null && section_urls != "") {
            push(all_urls, trim(section_urls));
        }
    }
    let disabled_count = length(all_urls) - length(active_urls);
    let st = fs.stat(HOSTS_CACHE_FILE);
    let cache_exists = st != null;
    let entry_count = 0;

    if (cache_exists) {
        entry_count = int(st.size);
    }

    print('{"urls":' + length(active_urls) + ',"total":' + length(all_urls) + ',"disabled":' + disabled_count + ',"cache_exists":' + (cache_exists ? 'true' : 'false') + ',"cache_size":' + entry_count + '}');
}

let command = ARGV[0] || "";

if (command == "list-update") {
    let target_url = ARGV[1] || "";
    exit(hosts_list_update(target_url) ? 0 : 1);
} else if (command == "list-status") {
    hosts_list_status();
    exit(0);
}

warn("Usage: components/hosts.uc <list-update [url]|list-status>\n");
exit(1);
