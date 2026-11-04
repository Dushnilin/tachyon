// Persistent, at-least-once delivery for automatic notifications. Interactive
// replies continue to use transport.send_message() synchronously.
let fs = require("fs");
let common = require("core.common");
const DIR = getenv("TACHYON_TELEGRAM_OUTBOX") || "/etc/tachyon/telegram-outbox";
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
    if (fs.writefile(stage, sprintf("%J", item)) == null ||
        !fs.chmod(stage, 0600) ||
        !common.command_success_from_args([ "mv", "-f", stage, path ])) {
        fs.unlink(stage);
        return false;
    }
    return true;
}

function submit(token, chat_id, text, parse_mode, keyboard, smart_entries) {
    let owner = bot_id(token);
    if (owner == "" || !match("" + chat_id, /^-?[0-9]+$/)) return false;
    common.ensure_dir(DIR);
    if (!fs.chmod(DIR, 0700) || length(entries()) >= MAX_ITEMS) {
        log("[err] Notification outbox unavailable or full");
        return false;
    }
    let path = trim(common.command_output_from_args([ "mktemp", DIR + "/notice.XXXXXX" ]));
    if (path == "") return false;
    // Only the public numeric bot ID is persisted, never its API credential.
    let item = { bot_id: owner, chat_id: "" + chat_id, text, parse_mode,
        keyboard, smart_entries, attempts: 0, next_try: time() };
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
        let delay = min(900, 60 * (1 << min(item.attempts - 1, 4)));
        let retry_after = int(result?.parameters?.retry_after || 0);
        item.next_try = time() + max(delay, retry_after);
        if (!save(path, item)) log("[err] Failed to save notification retry state");
        if (retry_after > 0) break;
    }
}

return { submit, drain };
