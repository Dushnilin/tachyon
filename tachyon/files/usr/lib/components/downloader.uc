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
        let args = [
            "curl", "--connect-timeout", "4", "-m", timeout,
            "-y", "6", "-Y", "32768",
            "-fsSL", "-H", "User-Agent: Tachyon-OpenWrt"
        ];
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

    // 1. Through configured proxy section first if available
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, t)) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
    }

    // 2. Direct fallback
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

    // 1. Through configured proxy section first if available
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "30"))
            return true;
        remove_file(output_path);
    }

    // 2. Direct fallback
    if (http_get_once(url, output_path, "", "30"))
        return true;
    remove_file(output_path);

    return false;
}

function download_with_retry(url, output_path, label) {
    let url_mod = core_url_module_or_null();
    let candidates = url_mod && type(url_mod.download_candidates) == "function" ? url_mod.download_candidates(url) : [ url ];
    let proxy_address = helpers.service_proxy_address();

    // 1. If proxy section is configured, try primary URL via proxy FIRST!
    if (proxy_address != "") {
        helpers.updates_log("Downloading " + as_string(label) + " via proxy section");
        if (http_get_once(url, output_path, proxy_address, "30") && file_nonempty(output_path))
            return true;
        remove_file(output_path);
        helpers.updates_log("Download via proxy section failed for " + as_string(url) + "; trying direct and mirrors", "warn");
    }

    // 2. Direct first, then mirrors
    for (let attempt = 0; attempt < length(candidates); attempt++) {
        let current_url = candidates[attempt];
        if (attempt == 0) {
            helpers.updates_log("Downloading " + as_string(label) + " (attempt 1/" + as_string(length(candidates)) + ")");
        } else {
            helpers.updates_log("Retrying " + as_string(label) + " via mirror (attempt " + as_string(attempt + 1) + "/" + as_string(length(candidates)) + ")", "warn");
        }

        // Direct
        if (http_get_once(current_url, output_path, "", "30") && file_nonempty(output_path))
            return true;
        remove_file(output_path);

        // Through proxy section for mirror if direct failed
        if (proxy_address != "" && attempt > 0) {
            if (http_get_once(current_url, output_path, proxy_address, "30") && file_nonempty(output_path)) {
                helpers.updates_log("Downloaded " + as_string(label) + " via proxy section (" + current_url + ")");
                return true;
            }
            remove_file(output_path);
        }
    }
    return false;
}

// ============================================================================
// GitHub API
// ============================================================================

// The same GET, but without curl -f, so an HTTP error keeps its body and
// status instead of collapsing into a bare failure. That body is the only way
// to tell "GitHub refused us because the budget ran out" from "GitHub is
// unreachable", and the two call for completely different follow-ups.
function http_get_with_body(url, timeout, proxy_address) {
    helpers.init_tmp_dir();
    let output_path = helpers.make_tmp_file("http");
    if (output_path == "")
        return { body: "", status: "000" };

    let t = as_string(timeout || "12");
    let args = [
        "curl", "--connect-timeout", "4", "-m", t, "-sSL",
        "-y", "6", "-Y", "32768",
        "-H", "User-Agent: Tachyon-OpenWrt"
    ];
    if (as_string(proxy_address) != "") {
        push(args, "-x", "http://" + as_string(proxy_address));
    }
    push(args, "-o", output_path, "-w", "%{http_code}", as_string(url));

    let status = trim(command_output_from_args(args));
    let body = file_nonempty(output_path) ? read_file(output_path) : "";
    remove_file(output_path);
    return { body: as_string(body), status: as_string(status || "000") };
}

// Fetch a URL that is expected to return valid JSON checked by github-response-ok.
// Priority: direct → proxy section → mirrors from url.uc (gh-proxy etc.)
//
// GitHub's unauthenticated API budget is 60 requests per hour per IP, and a
// component sweep spends many of them. Once the budget is gone the API answers
// 403 with a rate-limit body instead of JSON, and the mirror walk would fire
// anyway: a dozen more requests that cannot succeed on networks where those
// mirrors are unreachable, which is most of them. So the direct attempt keeps
// its body, and a rate-limit answer ends the sweep right there.
function github_response_is_rate_limited(body) {
    return match(as_string(body), /API rate limit exceeded/) != null ||
           match(as_string(body), /rate limit exceeded/i) != null ||
           match(as_string(body), /exceeded a secondary rate limit/) != null;
}

function github_rate_limit_reset_hint(body) {
    let at = match(as_string(body), /"reset": *([0-9]+)/);
    if (at == null)
        return "";
    let wait = int(at[1] || "0") - time();
    return wait > 0 ? sprintf(" (resets in %ds)", wait) : " (window already reset)";
}

let release_notes_by_key = {};
let last_release_notes = "";

function normalize_release_notes(raw_body) {
    return trim(replace(as_string(raw_body || ""), /\r/g, ""));
}

function remember_release_json(raw_json) {
    if (as_string(raw_json) == "")
        return;
    try {
        let parsed = json(raw_json);
        if (type(parsed) == "object") {
            let notes = normalize_release_notes(parsed.body);
            if (notes != "") {
                last_release_notes = notes;
                let html_url = trim(as_string(parsed.html_url || ""));
                let tag = trim(as_string(parsed.tag_name || ""));
                if (html_url != "")
                    release_notes_by_key[html_url] = notes;
                if (tag != "") {
                    release_notes_by_key[tag] = notes;
                    if (substr(tag, 0, 1) == "v")
                        release_notes_by_key[substr(tag, 1)] = notes;
                    else
                        release_notes_by_key["v" + tag] = notes;
                }
            }
        } else if (type(parsed) == "array") {
            for (let r in parsed) {
                if (type(r) != "object")
                    continue;
                let notes = normalize_release_notes(r.body);
                if (notes == "")
                    continue;
                if (last_release_notes == "")
                    last_release_notes = notes;
                let html_url = trim(as_string(r.html_url || ""));
                let tag = trim(as_string(r.tag_name || ""));
                if (html_url != "" && !release_notes_by_key[html_url])
                    release_notes_by_key[html_url] = notes;
                if (tag != "" && !release_notes_by_key[tag]) {
                    release_notes_by_key[tag] = notes;
                    if (substr(tag, 0, 1) == "v")
                        release_notes_by_key[substr(tag, 1)] = notes;
                    else
                        release_notes_by_key["v" + tag] = notes;
                }
            }
        }
    } catch (e) {}
}

function get_release_notes(release_url, tag) {
    release_url = trim(as_string(release_url || ""));
    tag = trim(as_string(tag || ""));
    if (release_url != "" && release_notes_by_key[release_url])
        return release_notes_by_key[release_url];
    if (tag != "" && release_notes_by_key[tag])
        return release_notes_by_key[tag];
    return last_release_notes;
}

function fetch_github_json(url, timeout) {
    let url_mod = core_url_module_or_null();
    let candidates = url_mod && type(url_mod.download_candidates) == "function"
        ? url_mod.download_candidates(url) : [ url ];
    let proxy_address = helpers.service_proxy_address();

    // 1. Through proxy section first if available
    if (proxy_address != "") {
        let proxy_resp = http_get_with_body(url, timeout, proxy_address);
        if (proxy_resp.status == "200" && proxy_resp.body != "" &&
            helpers.helper_success_input(proxy_resp.body, "github-response-ok", [])) {
            helpers.updates_log("Fetched GitHub JSON via proxy section: " + url);
            remember_release_json(proxy_resp.body);
            return proxy_resp.body;
        }
    }

    for (let i = 0; i < length(candidates); i++) {
        let candidate = candidates[i];
        let response;

        if (i == 0) {
            // GitHub itself: keep the error body so a rate-limit answer is
            // recognisable. Only a mirror follows the same order after this.
            let direct = http_get_with_body(candidate, timeout, "");
            if (github_response_is_rate_limited(direct.body)) {
                helpers.updates_log("GitHub API rate limit exhausted" + github_rate_limit_reset_hint(direct.body) +
                    "; skipping mirrors, they cannot lift it", "warn");
                return "";
            }
            if (direct.status != "200" || direct.body == "") {
                // Genuinely unreachable or refused. The proxy section is still
                // worth one attempt, then the mirrors take over as before.
                response = http_get(candidate, timeout);
            }
            else
                response = direct.body;
        }
        else
            response = http_get(candidate, timeout);

        if (response != "" && helpers.helper_success_input(response, "github-response-ok", [])) {
            if (i > 0)
                helpers.updates_log("Fetched GitHub JSON via mirror: " + candidate);
            remember_release_json(response);
            return response;
        }
    }
    return "";
}

function fetch_github_release_json(owner, repo) {
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest";
    return fetch_github_json(url, null);
}

function fetch_github_release_by_tag_json(owner, repo, tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return "";
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/tags/" + tag;
    return fetch_github_json(url, null);
}

function fetch_github_tag_commit_sha(owner, repo, tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return "";
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/commits/" + tag;
    let response = fetch_github_json(url, null);
    return response != "" ? trim(helpers.helper_output_input(response, "commit-object-sha", [])) : "";
}

function fetch_github_releases_json(owner, repo, per_page, page) {
    let url = "https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "10");
    if (page != null && int(page) > 1)
        url += "&page=" + as_string(page);
    return fetch_github_json(url, "8");
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
        fetch_github_json,
        fetch_github_release_json,
        fetch_github_release_by_tag_json,
        fetch_github_tag_commit_sha,
        fetch_github_releases_json,
        fetch_github_release_tag_fallback,
        get_release_notes,
        url_exists
    };
}

return module_exports();
