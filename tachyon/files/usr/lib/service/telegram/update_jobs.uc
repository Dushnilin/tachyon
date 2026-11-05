#!/usr/bin/env ucode
//
// Telegram notifications for component update jobs.
//
// "/update_component <name>" only starts a background job: the chat is left with
// the "update started" message and the outcome (the new version, or the error
// that aborted the update) stays in the CLI and the job log. The callback
// registers the job here, the worker loop polls it and reports the result to the
// chat that started it.
//

let fs = require("fs");
let common = require("core.common");
let i18n = require("service.i18n");
let transport = require("service.telegram.transport");
let rendering = require("service.telegram.rendering");

const QUEUE_PATH = "/var/run/tachyon/telegram-component-jobs.json";
// A job still running after an hour is reported as stuck instead of keeping the
// queue entry (and the chat in the dark) indefinitely.
const JOB_TTL = 3600;
// Component action logs can be long; the failure message only needs the tail.
const LOG_TAIL = 900;

let as_string = common.as_string;
let command_output_from_args = common.command_output_from_args;
let escape_html = rendering.escape_html;

function read_queue() {
    let raw = fs.readfile(QUEUE_PATH);
    if (raw == null || raw == "")
        return {};
    try {
        let parsed = json(raw);
        return type(parsed) == "object" && parsed != null ? parsed : {};
    } catch (e) {
        return {};
    }
}

function write_queue(queue) {
    fs.writefile(QUEUE_PATH, sprintf("%J", queue));
}

function register(job_id, component, chat_id, msg_id) {
    job_id = trim(as_string(job_id));
    if (job_id == "")
        return false;
    let queue = read_queue();
    queue[job_id] = {
        component: as_string(component),
        chat_id: as_string(chat_id),
        msg_id: msg_id != null ? as_string(msg_id) : "",
        started_at: time()
    };
    write_queue(queue);
    return true;
}

function job_status(job_id) {
    let out = command_output_from_args([ "/usr/bin/tachyon", "component_action_status", job_id ]);
    if (out == null || out == "")
        return null;
    try {
        let parsed = json(out);
        return type(parsed) == "object" ? parsed : null;
    } catch (e) {
        return null;
    }
}

// Last lines of the job log, kept short: Telegram caps message length and the
// useful part of a failed update is at the end of the log.
function job_error_tail(job_id) {
    let out = command_output_from_args([ "/usr/bin/tachyon", "component_action_log", job_id ]);
    if (out == null || out == "")
        return "";
    let log = "";
    try {
        let parsed = json(out);
        log = as_string(parsed.log != null ? parsed.log : "");
    } catch (e) {
        return "";
    }
    log = trim(log);
    if (log == "")
        return "";
    if (length(log) > LOG_TAIL)
        log = "..." + substr(log, length(log) - LOG_TAIL);
    return log;
}

function component_title(component) {
    let title = "";
    try {
        title = rendering.component_display_title(component);
    } catch (e) {
        title = "";
    }
    return title != "" ? title : as_string(component);
}

function success_message(t, entry, status) {
    let title = component_title(entry.component);
    let from = trim(as_string(status.current_version != null ? status.current_version : ""));
    let to = trim(as_string(status.latest_version != null ? status.latest_version : ""));

    let msg = "✅ <b>" + t("update_job_done") + ": " + escape_html(title) + "</b>";
    if (to != "" && to != from)
        msg += "\n<code>" + escape_html(from != "" ? from : "?") + "</code> → <code>" + escape_html(to) + "</code>";
    else if (status.changed == 0)
        msg += "\n" + t("update_job_unchanged");
    return msg;
}

function failure_message(t, entry, status) {
    let title = component_title(entry.component);
    let msg = "❌ <b>" + t("update_job_failed") + ": " + escape_html(title) + "</b>";

    let details = [];
    if (status != null) {
        let status_text = trim(as_string(status.status != null ? status.status : ""));
        if (status_text != "")
            push(details, status_text);
        if (status.exit_code != null && as_string(status.exit_code) != "")
            push(details, "exit code " + as_string(status.exit_code));
    }
    if (length(details) > 0)
        msg += "\n" + escape_html(join(", ", details));

    let tail = job_error_tail(entry.job_id);
    if (tail != "")
        msg += "\n<pre>" + escape_html(tail) + "</pre>";
    return msg;
}

function timeout_message(t, entry) {
    let title = component_title(entry.component);
    return "⌛ <b>" + t("update_job_timeout") + ": " + escape_html(title) + "</b>";
}

// Called from the worker loop. Returns the number of notifications sent.
function poll(token, lang) {
    let queue = read_queue();
    let job_ids = [];
    for (let job_id in queue)
        push(job_ids, job_id);
    if (length(job_ids) == 0)
        return 0;

    let t = i18n.bind(lang || "en");
    let now = time();
    let sent = 0;
    let changed = false;

    for (let job_id in job_ids) {
        let entry = queue[job_id];
        if (type(entry) != "object" || entry == null) {
            delete queue[job_id];
            changed = true;
            continue;
        }
        entry.job_id = job_id;

        let status = job_status(job_id);
        let running = status != null && status.running === true;
        let expired = now - int(entry.started_at != null ? entry.started_at : 0) > JOB_TTL;

        if (running && !expired)
            continue;

        let msg;
        if (running && expired)
            msg = timeout_message(t, entry);
        else if (status != null && status.success === true &&
                 (status.exit_code == null || int(status.exit_code) == 0))
            msg = success_message(t, entry, status);
        else
            msg = failure_message(t, entry, status);

        let chat_id = trim(as_string(entry.chat_id));
        if (chat_id != "") {
            // A failed send must not keep the job in the queue forever (the
            // token may be revoked, the chat blocked, the bot offline).
            try {
                transport.send_message(token, chat_id, msg, "HTML", null);
                sent++;
            } catch (e) {
            }
        }

        delete queue[job_id];
        changed = true;
    }

    if (changed)
        write_queue(queue);
    return sent;
}

return {
    QUEUE_PATH,
    register,
    poll
};
