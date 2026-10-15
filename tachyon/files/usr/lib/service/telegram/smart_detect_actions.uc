// Short-lived, message-bound receipts for automatic Smart Detect additions.
// No bot credentials are stored here. Each recipient gets an independent receipt.
let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let smart = require("service.smart_detect_plus");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const STATE_DIR = getenv("TACHYON_SMART_ACTIONS_DIR") || "/var/run/tachyon-smart-actions";
const TTL = 86400;
const MAX_RECEIPTS = 128;

function receipt_path(id) {
    return match(id || "", /^[a-f0-9]{32}$/) ? STATE_DIR + "/" + id + ".json" : null;
}

function read_receipt(id) {
    let path = receipt_path(id);
    if (!path) return null;
    let record = common.read_json_file(path, null);
    return type(record) == "object" && record.created > time() - TTL &&
        record.created <= time() && type(record.entries) == "array" ? record : null;
}

function save_receipt(id, record) {
    let path = receipt_path(id);
    return path != null && common.write_json_file(path, record);
}

function snapshot(section) {
    return sprintf("%J", [section?.user_domains, section?.user_domains_text]);
}

function list_values(value) {
    return type(value) == "array" ? [...value] : value == null ? [] : [value];
}

function create(entries, chat_id) {
    if (type(entries) != "array" || !length(entries) || length(entries) > 32) return null;
    if (!fs.stat(STATE_DIR) && !fs.mkdir(STATE_DIR, 0700)) return null;
    // Bound RAM use and expire old buttons without retaining notification history.
    let files = fs.glob(STATE_DIR + "/*.json") || [];
    files = sort(files, (a, b) => (fs.stat(a)?.mtime || 0) - (fs.stat(b)?.mtime || 0));
    for (let i = 0; i < length(files); i++)
        if (i <= length(files) - MAX_RECEIPTS || (fs.stat(files[i])?.mtime || 0) < time() - TTL)
            fs.unlink(files[i]);
    let id = replace(trim(fs.readfile("/proc/sys/kernel/random/uuid") || ""), /-/g, "");
    if (!receipt_path(id)) return null;
    let c = uci_core.cursor();
    if (!c) return null;
    c.load(CONFIG_NAME);
    if (length(c.changes(CONFIG_NAME) || {})) return null;
    let record = { created: time(), chat: "" + chat_id, entries: [], snapshots: {} };
    for (let entry in entries) {
        let domain = smart.normalize_domain(entry.domain);
        let source = smart.normalize_domain(entry.source_domain || entry.domain);
        let section = c.get_all(CONFIG_NAME, entry.section);
        if (!domain || !source || !section || index(list_values(section.user_domains), domain) < 0 ||
            entry.snapshot != snapshot(section))
            continue;
        push(record.entries, { section: entry.section, domain, source });
        record.snapshots[entry.section] = snapshot(section);
    }
    return length(record.entries) && save_receipt(id, record) ? id : null;
}

function bind_message(id, chat_id, message_id) {
    let record = read_receipt(id);
    if (!record || record.chat != "" + chat_id || record.message != null) return false;
    record.message = int(message_id);
    return save_receipt(id, record);
}

function keyboard(id, t) {
    let record = read_receipt(id);
    let rows = [];
    for (let i = 0; i < length(record?.entries || []); i++) {
        let entry = record.entries[i];
        if (entry.done) continue;
        let suffix = length(record.entries) > 1 ? " · " + entry.domain : "";
        push(rows, [
            { text: t("sd_exclude") + suffix, callback_data: "/sd exclude " + id + " " + i },
            { text: t("sd_undo") + suffix, callback_data: "/sd undo " + id + " " + i }
        ]);
    }
    return rows;
}

function apply(cmd, chat_id, message_id) {
    let parsed = match(cmd || "", /^\/sd (exclude|undo) ([a-f0-9]{32}) ([0-9]{1,2})$/);
    if (!parsed) return { key: "sd_obsolete" };
    let id = parsed[2];
    let record = read_receipt(id);
    if (!record || record.message == null || record.chat != "" + chat_id || record.message != int(message_id))
        return { key: "sd_obsolete" };
    let entry = record.entries[int(parsed[3])];
    if (!entry || entry.done)
        return { key: "sd_obsolete" };
    let c = uci_core.cursor();
    if (!c) return { key: "sd_failed" };
    c.unload(CONFIG_NAME);
    c.load(CONFIG_NAME);
    if (length(c.changes(CONFIG_NAME) || {})) return { key: "sd_pending" };
    let section = c.get_all(CONFIG_NAME, entry.section);
    // An edited rule list no longer proves ownership of this automatic addition.
    if (!section || snapshot(section) != record.snapshots[entry.section]) return { key: "sd_obsolete" };
    let values = list_values(section.user_domains);
    if (index(values, entry.domain) < 0) return { key: "sd_obsolete" };
    values = filter(values, domain => domain != entry.domain);
    let cfg = c.get_all(CONFIG_NAME, "settings") || {};
    let excluded = cfg.smart_detect_expand_to_root == "0" ? entry.source : smart.main_domain(entry.source);
    if (!excluded) return { key: "sd_failed" };
    let ok = length(values) ? c.set(CONFIG_NAME, entry.section, "user_domains", values) :
        c.delete(CONFIG_NAME, entry.section, "user_domains");
    if (ok && parsed[1] == "exclude") {
        let exclusions = list_values(cfg.smart_detect_exclude);
        if (index(map(exclusions, domain => smart.normalize_domain(domain)), excluded) < 0) push(exclusions, excluded);
        ok = c.set(CONFIG_NAME, "settings", "smart_detect_exclude", exclusions);
    }
    if (!ok || !c.commit(CONFIG_NAME)) {
        c.unload(CONFIG_NAME);
        return { key: "sd_failed" };
    }
    entry.done = true;
    record.snapshots[entry.section] = snapshot(c.get_all(CONFIG_NAME, entry.section));
    save_receipt(id, record);
    return { key: parsed[1] == "exclude" ? "sd_excluded" : "sd_undone",
        domain: parsed[1] == "exclude" ? excluded : entry.domain, changed: true, id };
}

return { create, bind_message, keyboard, apply };
