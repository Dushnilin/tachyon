#!/usr/bin/env ucode
//
// HTTP downloads and GitHub release fetching for component updates.
//

let common = require("core.common");

let helpers = require("components.helpers");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_env = helpers.command_env;
let command_exists = helpers.command_exists;
let remove_file = helpers.remove_file;
let read_file = helpers.read_file;
let file_nonempty = helpers.file_nonempty;

// The url module is optional at runtime; treat absence as "no mirror list".
function core_url_module_or_null() {
    try {
        return require("core.url");
    } catch (e) {
        return null;
    }
}

// ============================================================================
// Plain HTTP
// ============================================================================

function http_get_once(url, output_path, proxy_address, timeout) {
    url = as_string(url);
    output_path = as_string(output_path);
    proxy_address = as_string(proxy_address);
    timeout = as_string(timeout || "30");

    if (command_exists("curl")) {
        let args = [ "curl", "--connect-timeout", "4", "-m", timeout, "-fsSL", "-H", "User-Agent: Tachyon-OpenWrt" ];
        if (proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + proxy_address);
        }
        push(args, url);
        push(args, "-o");
        push(args, output_path);
        return command_success_from_args(args);
    }

    if (command_exists("wget")) {
        let command = command_from_args([ "wget", "-T", timeout, "-q", "-O", output_path, "-U", "Tachyon-OpenWrt", url ]);
        if (proxy_address != "")
            command = command_env({ http_proxy: "http://" + proxy_address, https_proxy: "http://" + proxy_address }) + " " + command;
        return command_success(command);
    }

    return false;
}

function http_get(url, timeout) {
    helpers.init_tmp_dir();
    let output_path = helpers.make_tmp_file("http");
    if (output_path == "")
        return "";

    let t = as_string(timeout || "12");
    let proxy_address = helpers.service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, t)) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
        helpers.updates_log("HTTP request via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }

    if (http_get_once(url, output_path, "", t)) {
        let data = read_file(output_path);
        remove_file(output_path);
        return data;
    }

    remove_file(output_path);
    return "";
}

function download_file_once(url, output_path) {
    let proxy_address = helpers.service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "120"))
            return true;
        remove_file(output_path);
        helpers.updates_log("Download via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }
    return http_get_once(url, output_path, "", "120");
}

function download_with_retry(url, output_path, label) {
    let url_mod = core_url_module_or_null();
    let candidates = url_mod && type(url_mod.download_candidates) == "function" ? url_mod.download_candidates(url) : [ url ];

    for (let attempt = 0; attempt < length(candidates); attempt++) {
        let current_url = candidates[attempt];
        if (attempt == 0) {
            helpers.updates_log("Downloading " + as_string(label) + " (attempt 1/" + as_string(length(candidates)) + ")");
        } else {
            helpers.updates_log("Retrying " + as_string(label) + " via mirror (attempt " + as_string(attempt + 1) + "/" + as_string(length(candidates)) + ")", "warn");
        }

        if (download_file_once(current_url, output_path) && file_nonempty(output_path))
            return true;
        remove_file(output_path);
    }
    return false;
}

// ============================================================================
// GitHub API
// ============================================================================

function fetch_github_release_json(owner, repo) {
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest";
    let response = http_get(url);
    if (response == "" || !helpers.helper_success_input(response, "github-response-ok", [])) {
        response = http_get("https://gh-proxy.com/" + url);
        if (response == "" || !helpers.helper_success_input(response, "github-response-ok", []))
            return "";
    }
    return response;
}

function fetch_github_release_by_tag_json(owner, repo, tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return "";
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/tags/" + tag;
    let response = http_get(url);
    if (response == "" || !helpers.helper_success_input(response, "github-response-ok", [])) {
        response = http_get("https://gh-proxy.com/" + url);
        if (response == "" || !helpers.helper_success_input(response, "github-response-ok", []))
            return "";
    }
    return response;
}

function fetch_github_tag_commit_sha(owner, repo, tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return "";
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/commits/" + tag;
    let response = http_get(url);
    if (response == "" || !helpers.helper_success_input(response, "github-response-ok", [])) {
        response = http_get("https://gh-proxy.com/" + url);
        if (response == "" || !helpers.helper_success_input(response, "github-response-ok", []))
            return "";
    }
    return trim(helpers.helper_output_input(response, "commit-object-sha", []));
}

function fetch_github_releases_json(owner, repo, per_page) {
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "10");
    let response = http_get(url, "8");
    if (response == "" || !helpers.helper_success_input(response, "github-response-ok", [])) {
        response = http_get("https://gh-proxy.com/" + url, "8");
        if (response == "" || !helpers.helper_success_input(response, "github-response-ok", []))
            return "";
    }
    return response;
}

function fetch_github_release_tag_fallback(owner, repo) {
    let url = "https://github.com/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest";
    let url_mod = core_url_module_or_null();
    let candidates = url_mod && type(url_mod.download_candidates) == "function" ? url_mod.download_candidates(url) : [ url ];
    let proxy_addr = helpers.service_proxy_address();

    for (let target_url in candidates) {
        if (command_exists("curl")) {
            let args = [ "curl", "-sI", "--connect-timeout", "6", "-m", "12" ];
            if (proxy_addr != "") {
                push(args, "-x");
                push(args, "http://" + proxy_addr);
            }
            push(args, target_url);
            let output = command_output_from_args(args);
            if (output != "") {
                let loc_idx = index(lc(output), "location:");
                if (loc_idx >= 0) {
                    let line = substr(output, loc_idx);
                    let end_line = index(line, "\r");
                    if (end_line < 0) end_line = index(line, "\n");
                    if (end_line >= 0) line = substr(line, 0, end_line);
                    let tag_idx = rindex(line, "/");
                    if (tag_idx >= 0) {
                        let tag = trim(substr(line, tag_idx + 1));
                        if (tag != "")
                            return tag;
                    }
                }
            }
        } else if (command_exists("wget")) {
            let cmd = command_from_args([ "wget", "-s", "-T", "6", target_url ]);
            if (proxy_addr != "")
                cmd = command_env({ http_proxy: "http://" + proxy_addr, https_proxy: "http://" + proxy_addr }) + " " + cmd;
            let output = command_output("(" + cmd + ") 2>&1");
            let m = match(output, /Redirected to [^ \t\r\n]*\/releases\/tag\/([^ \t\r\n]+)/);
            if (m && m[1])
                return trim(m[1]);
        }
    }
    return "";
}

function url_exists(url) {
    let url_mod = core_url_module_or_null();
    let candidates = url_mod && type(url_mod.download_candidates) == "function" ? url_mod.download_candidates(url) : [ url ];
    let proxy_addr = helpers.service_proxy_address();

    for (let target_url in candidates) {
        if (command_exists("curl")) {
            let args = [ "curl", "-sI", "--connect-timeout", "6", "-m", "12" ];
            if (proxy_addr != "") {
                push(args, "-x");
                push(args, "http://" + proxy_addr);
            }
            push(args, as_string(target_url));
            let output = command_output_from_args(args);
            if (output != "") {
                let first_line = split(output, "\n")[0] || "";
                if (index(first_line, " 200 ") > 0 || index(first_line, " 301 ") > 0 || index(first_line, " 302 ") > 0) {
                    return true;
                }
            }
        } else if (command_exists("wget")) {
            let cmd = command_from_args([ "wget", "-s", "-T", "6", "-q", as_string(target_url) ]);
            if (proxy_addr != "")
                cmd = command_env({ http_proxy: "http://" + proxy_addr, https_proxy: "http://" + proxy_addr }) + " " + cmd;
            if (command_success(cmd))
                return true;
        }
    }
    return false;
}

// Forward-referenced helpers

function module_exports() {
    return {
        http_get_once,
        http_get,
        download_file_once,
        download_with_retry,
        fetch_github_release_json,
        fetch_github_release_by_tag_json,
        fetch_github_tag_commit_sha,
        fetch_github_releases_json,
        fetch_github_release_tag_fallback,
        url_exists
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/downloader.uc (library module, no CLI)\n");
exit(1);
