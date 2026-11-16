// Persistent, at-least-once delivery for automatic notifications. Interactive
// replies continue to use transport.send_message() synchronously.
let fs = require("fs");
let common = require("core.common");
const DIR = getenv("TACHYON_TELEGRAM_OUTBOX") || "/var/run/tachyon/telegram-outbox";
const MAX_ITEMS = 100;

function entries() {
    return sort(fs.glob(DIR + "/notice.*.json") || []);
}

function bot_id(token) {
    let m = match(token || "", /^([0-9]+):/);
    return m ? m[1] : "";
}

function log(message) {
    common.command_success_from_args([ "logger", "-t", "tachyon-telegram", message ]);
}

function save(path, item) {
    let stage = trim(common.command_output_from_args([ "mktemp", DIR + "/.notice.XXXXXX" ]));
    if (stage == "") return false;
    if (!common.write_file(stage, sprintf("%J", item)) ||
        !fs.chmod(stage, 0600) ||
        !fs.rename(stage, path)) {
        fs.unlink(stage);
        return false;
    }
    return true;
}

function submit(token, chat_id, text, parse_mode, keyboard, smart_entries, dedup_key) {
    let owner = bot_id(token);
    if (owner == "" || !match("" + chat_id, /^-?[0-9]+$/)) return false;
    common.ensure_dir(DIR);
    if (!fs.chmod(DIR, 0700)) {
        log("[err] Notification outbox unavailable");
        return false;
    }

    let current_entries = entries();
    let key = (dedup_key != null && ("" + dedup_key) != "") ? ("" + dedup_key) : null;
    if (key != null) {
        for (let existing_path in current_entries) {
            let raw = fs.readfile(existing_path);
            if (raw == null) continue;
            let existing = null;
            try { existing = json(raw); } catch (e) { continue; }
            if (type(existing) != "object") continue;
            if (existing.bot_id == owner && existing.chat_id == ("" + chat_id) && existing.dedup_key == key) {
                let updated = {
                    bot_id: owner,
                    chat_id: "" + chat_id,
                    text,
                    parse_mode,
                    keyboard,
                    smart_entries,
                    dedup_key: key,
                    attempts: int(existing.attempts || 0),
                    next_try: existing.next_try || time()
                };
                return save(existing_path, updated);
            }
        }
    }

    if (length(current_entries) >= MAX_ITEMS) {
        log("[err] Notification outbox unavailable or full");
        return false;
    }
    let path = trim(common.command_output_from_args([ "mktemp", DIR + "/notice.XXXXXX" ]));
    if (path == "") return false;
    // Only the public numeric bot ID is persisted, never its API credential.
    let item = { bot_id: owner, chat_id: "" + chat_id, text, parse_mode,
        keyboard, smart_entries, attempts: 0, next_try: time() };
    if (key != null)
        item.dedup_key = key;
    let ok = save(path + ".json", item);
    fs.unlink(path);
    return ok;
}

// Called only by the single Telegram worker, before its blocking long-poll.
function drain(token) {
    let owner = bot_id(token);
    if (owner == "") return;
    let transport = null;
    let attempted = 0;
    for (let path in entries()) {
        let item = null;
        try { item = json(fs.readfile(path) || "null"); } catch (e) {}
        if (type(item) != "object" || item.bot_id != owner || item.next_try > time())
            continue;
        if (attempted++ >= 4) break;
        if (transport == null) transport = require("service.telegram.transport");
        let actions = item.smart_entries ? require("service.telegram.smart_detect_actions") : null;
        let id = actions ? actions.create(item.smart_entries, item.chat_id) : null;
        let keyboard = id ? actions.keyboard(id, transport.get_t()) : item.keyboard;
        let result = transport.send_message(token, item.chat_id, item.text, item.parse_mode, keyboard);
        if (result && result.ok === true) {
            if (id && result.result?.message_id)
                actions.bind_message(id, item.chat_id, result.result.message_id);
            fs.unlink(path);
            continue;
        }
        item.attempts = int(item.attempts || 0) + 1;
        let err_code = int(result?.error_code || 0);
        if (item.attempts >= 12 || err_code == 400 || err_code == 403 || err_code == 404) {
            fs.unlink(path);
            continue;
        }
        let delay = min(900, 60 * (1 << min(item.attempts - 1, 4)));
        let retry_after = int(result?.parameters?.retry_after || 0);
        item.next_try = time() + max(delay, retry_after);
        if (!save(path, item)) log("[err] Failed to save notification retry state");
        if (retry_after > 0) break;
    }
}

return { submit, drain };
