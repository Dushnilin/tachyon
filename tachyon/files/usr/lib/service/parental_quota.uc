#!/usr/bin/env ucode

// Parental daily time quotas: schedules with `daily_quota_minutes` limit how
// long a listed device may use the network per day. A cron tick (every
// minute) counts active devices, blocks exhausted ones via the nftables set
// tachyon_quota_block, and resets everything after midnight.
//
// NOTE: ucode does not hoist function declarations - keep callees above
// their first caller.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let write_json = common.write_json;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_output_from_args = common.command_output_from_args;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "TachyonTable";
const STATE_FILE = getenv("PARENTAL_QUOTA_STATE_FILE") || "/var/run/tachyon/parental_quotas.json";
const CRON_MARKER = getenv("PARENTAL_QUOTA_CRON_MARKER") || "# tachyon-parental-quota";
const TACHYON_BIN = getenv("TACHYON_BIN") || "/usr/bin/tachyon";
const SET_ETHER = "tachyon_quota_block";
const SET_IP = "tachyon_quota_block_ip";

const MAC_RE = /^([0-9a-fA-F]{2}[:-]){5}[0-9A-Fa-f]{2}$/;

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[parental-quota] [" + level + "] " + as_string(message) ]);
}

function today_str() {
    return trim(command_output_from_args([ "date", "+%Y-%m-%d" ]));
}

function int_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    if (value == null || value == "")
        return int(fallback);
    let parsed = int(value);
    return parsed > 0 ? parsed : 0;
}

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return !!fallback;
    let s = lc(as_string(value));
    return s == "1" || s == "true" || s == "yes" || s == "on";
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) != "array") {
        let result = [];
        for (let item in split(replace(as_string(value), /[[:space:],]+/g, " "), " ")) {
            item = trim(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }
    let result = [];
    for (let item in value) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function quota_schedules() {
    let result = [];
    let profiles_by_name = {};
    for (let p in uci_core.section_objects(CONFIG_NAME, "profile")) {
        let p_name = as_string(object_or_empty(p)[".name"]);
        profiles_by_name[p_name] = p;
        if (!bool_option(p, "enabled", true))
            continue;
        let p_minutes = int_option(p, "daily_quota_minutes", 0);
        if (p_minutes <= 0)
            continue;
        let p_devices = [];
        for (let dev in list_option(p, "device_ip")) {
            let is_mac = match(dev, MAC_RE) != null;
            if (!is_mac && match(dev, /:/) != null)
                continue;
            push(p_devices, { ident: lc(dev), is_mac });
        }
        if (length(p_devices) == 0)
            continue;
        push(result, {
            label: as_string(object_or_empty(p).label || p_name),
            minutes: p_minutes,
            devices: p_devices
        });
    }

    for (let section in uci_core.section_objects(CONFIG_NAME, "schedule")) {
        if (!bool_option(section, "enabled", true))
            continue;
        let minutes = int_option(section, "daily_quota_minutes", 0);
        if (minutes <= 0)
            continue;
        let devices = [];
        let idents_seen = {};
        for (let dev in list_option(section, "device_ip")) {
            let is_mac = match(dev, MAC_RE) != null;
            if (!is_mac && match(dev, /:/) != null)
                continue;
            let ident = lc(dev);
            if (!idents_seen[ident]) {
                idents_seen[ident] = true;
                push(devices, { ident, is_mac });
            }
        }
        for (let prof_ref in list_option(section, "profile")) {
            let p = profiles_by_name[prof_ref];
            if (p && bool_option(p, "enabled", true)) {
                for (let dev in list_option(p, "device_ip")) {
                    let is_mac = match(dev, MAC_RE) != null;
                    if (!is_mac && match(dev, /:/) != null)
                        continue;
                    let ident = lc(dev);
                    if (!idents_seen[ident]) {
                        idents_seen[ident] = true;
                        push(devices, { ident, is_mac });
                    }
                }
            }
        }
        if (length(devices) == 0)
            continue;
        push(result, {
            label: as_string(object_or_empty(section).label || object_or_empty(section)[".name"]),
            minutes,
            devices
        });
    }
    return result;
}

function str_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    if (value == null || value == "")
        return fallback;
    return as_string(value);
}

function guest_mode_config() {
    let sections = uci_core.section_objects(CONFIG_NAME, "guest_mode");
    if (length(sections) == 0)
        return null;
    let s = object_or_empty(sections[0]);
    if (!bool_option(s, "enabled", false))
        return null;
    let time_limit = int_option(s, "daily_time_limit", 0);
    let traffic_limit = int_option(s, "daily_traffic_limit", 0);
    if (time_limit <= 0 && traffic_limit <= 0)
        return null;
    return {
        mode: str_option(s, "mode", "selected"),
        time_limit,
        traffic_limit,
        guest_devices: list_option(s, "guest_devices"),
        trusted_devices: list_option(s, "trusted_devices"),
        notify: bool_option(s, "notify", true)
    };
}

function guest_quota_active() {
    return guest_mode_config() != null;
}

function all_active_neighbors() {
    let result = [];
    for (let line in split(command_output_from_args([ "ip", "neigh", "show" ]), "\n")) {
        line = trim(as_string(line));
        if (line == "") continue;
        if (match(line, /(REACHABLE|STALE|DELAY|PROBE|PERMANENT)/) != null) {
            let parts = split(line, " ");
            let ip = parts[0];
            let mac = null;
            for (let i = 0; i < length(parts) - 1; i++) {
                if (parts[i] == "lladdr") {
                    mac = lc(parts[i + 1]);
                    break;
                }
            }
            push(result, { ip, mac });
        }
    }
    return result;
}

function read_guest_traffic_bytes() {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "guest_forward" ]) || "";
    let result = {};
    for (let line in split(output, "\n")) {
        let m = match(line, /bytes\s+([0-9]+)\s+comment\s+"tachyon-guest-byte:([^"]+)"/);
        if (m) {
            let bytes = int(m[1]);
            let ident = lc(m[2]);
            result[ident] = bytes;
        }
    }
    return result;
}

function read_state() {
    let raw = fs.readfile(STATE_FILE);
    if (raw == null || trim(as_string(raw)) == "")
        return { day: "", devices: {}, guest_devices: {} };
    let parsed = object_or_empty(json(raw));
    return {
        day: as_string(parsed["day"] || ""),
        devices: object_or_empty(parsed["devices"]),
        guest_devices: object_or_empty(parsed["guest_devices"])
    };
}

function write_state(state) {
    let tmp = STATE_FILE + ".tmp." + int(time());
    if (!fs.writefile(tmp, sprintf("%J", state))) {
        log_message("failed to write state file", "warn");
        return;
    }
    command_status(command_from_args([ "mv", "-f", tmp, STATE_FILE ]));
}

function device_active(ident) {
    for (let line in split(command_output_from_args([ "ip", "neigh", "show" ]), "\n")) {
        line = as_string(line);
        if (index(lc(line), ident) < 0)
            continue;
        if (match(line, /(REACHABLE|STALE|DELAY|PROBE|PERMANENT)/) != null)
            return true;
    }
    return false;
}

function send_notification(message) {
    let tcfg = object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (as_string(tcfg.enabled || "0") != "1" || !tcfg.bot_token || !tcfg.admin_ids)
        return;
    system(common.background_command(TACHYON_BIN + " telegram send " + shell_quote(message)));
}

function nft_chain_has_quota(chain, match_type) {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, chain ]) || "";
    return index(output, "tachyon-quota-" + match_type) >= 0;
}

function nft_table_exists() {
    let rc = command_status(command_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]) + " >/dev/null 2>&1");
    return rc == 0;
}

function nft_set_exists(set_name) {
    let rc = command_status(command_from_args([ "nft", "list", "set", "inet", NFT_TABLE_NAME, set_name ]) + " >/dev/null 2>&1");
    return rc == 0;
}

function nft_create_set(set_name, set_type) {
    let cmd = "nft add set inet " + NFT_TABLE_NAME + " " + set_name + " { type " + set_type + "; flags interval; }";
    let rc = command_status(cmd + " 2>/dev/null");
    if (rc != 0)
        log_message("failed to create nft set " + set_name + ": " + as_string(rc), "warn");
    return rc == 0;
}

function nft_insert_quota_rule(chain, match_type) {
    let set_name = match_type == "ether" ? SET_ETHER : SET_IP;
    let addr_type = match_type == "ether" ? "ether" : "ip";
    let cmd = "nft add rule inet " + NFT_TABLE_NAME + " " + chain + " " + addr_type + " saddr @" + set_name + " counter drop comment \"tachyon-quota-" + match_type + "\"";
    let rc = command_status(cmd + " 2>/dev/null");
    if (rc != 0)
        log_message("failed to insert quota rule in " + chain + " for " + match_type + ": " + as_string(rc), "warn");
    return rc == 0;
}

function ensure_nft_rules() {
    // The whole table disappears on every Tachyon nft rebuild; recreate our
    // pieces on demand so ticks self-heal without touching apply.uc ordering.
    if (!nft_table_exists())
        return false;

    // Create quota sets if missing
    if (!nft_set_exists(SET_ETHER))
        nft_create_set(SET_ETHER, "ether_addr");
    if (!nft_set_exists(SET_IP))
        nft_create_set(SET_IP, "ipv4_addr");

    // Insert drop rules into parental chains (idempotent via comment check)
    if (!nft_chain_has_quota("parental_control", "ether"))
        nft_insert_quota_rule("parental_control", "ether");
    if (!nft_chain_has_quota("parental_control", "ip"))
        nft_insert_quota_rule("parental_control", "ip");
    if (!nft_chain_has_quota("parental_forward", "ether"))
        nft_insert_quota_rule("parental_forward", "ether");
    if (!nft_chain_has_quota("parental_forward", "ip"))
        nft_insert_quota_rule("parental_forward", "ip");
    return true;
}

function sync_block_set(set_name, idents) {
    command_status("nft flush set inet " + NFT_TABLE_NAME + " " + set_name + " >/dev/null 2>&1");
    if (length(idents) > 0) {
        let cmd = "nft add element inet " + NFT_TABLE_NAME + " " + set_name + " { " + join(", ", idents) + " }";
        let rc = command_status(cmd + " 2>/dev/null");
        if (rc != 0)
            log_message("failed to sync nft set " + set_name + " with " + as_string(length(idents)) + " elements: " + as_string(rc), "warn");
    }
}

function sync_enforcement(blocked_macs, blocked_ips) {
    if (!ensure_nft_rules()) {
        log_message("nft table not available, quota enforcement deferred to next tick", "debug");
        return;
    }
    sync_block_set(SET_ETHER, blocked_macs);
    sync_block_set(SET_IP, blocked_ips);
}

function crontab_lines() {
    return split(command_output_from_args([ "crontab", "-l" ]), "\n");
}

function cron_line() {
    return "* * * * * " + TACHYON_BIN + " parental_quota_tick " + CRON_MARKER;
}

function write_crontab(lines) {
    let text = "";
    for (let i = 0; i < length(lines); i++) {
        if (as_string(lines[i]) == "" && i == length(lines) - 1)
            continue;
        text += as_string(lines[i]) + "\n";
    }
    let tmp = "/tmp/tachyon-parental-cron." + as_string(int(time()));
    if (!fs.writefile(tmp, text))
        return false;
    let ok = command_status(command_from_args([ "crontab", tmp ])) == 0;
    fs.unlink(tmp);
    return ok;
}

function remove_cron() {
    let line = cron_line();
    let changed = false;
    let lines = [];
    for (let existing in crontab_lines()) {
        if (trim(as_string(existing)) == line) {
            changed = true;
            continue;
        }
        push(lines, existing);
    }
    if (!changed)
        return 0;
    return write_crontab(lines) ? 0 : 1;
}

function install_cron() {
    // Only install the cron tick if there is at least one schedule or guest mode
    // with daily limits. Without quotas the job produces nft stderr which crond logs as cron.err.
    if (length(quota_schedules()) == 0 && !guest_quota_active())
        return remove_cron();

    let line = cron_line();
    let lines = crontab_lines();
    for (let existing in lines)
        if (trim(as_string(existing)) == line)
            return 0;
    push(lines, line);
    log_message("cron job installed", "debug");
    return write_crontab(lines) ? 0 : 1;
}

function blocked_lists(state) {
    // MAC/IP idents currently over quota (parental + guest). On day rollover nothing stays
    // blocked because counters start fresh.
    let macs = [];
    let ips = [];
    for (let ident, entry in state.devices) {
        entry = object_or_empty(entry);
        if (entry.blocked != true)
            continue;
        if (match(ident, MAC_RE) != null)
            push(macs, ident);
        else
            push(ips, ident);
    }
    for (let ident, entry in state.guest_devices) {
        entry = object_or_empty(entry);
        if (entry.blocked != true)
            continue;
        if (match(ident, MAC_RE) != null)
            push(macs, ident);
        else
            push(ips, ident);
    }
    return { macs, ips };
}

function tick() {
    let schedules = quota_schedules();
    let gm_cfg = guest_mode_config();

    if (length(schedules) == 0 && gm_cfg == null) {
        // No quota schedules configured and no guest quotas active
        return 0;
    }

    let today = today_str();
    let state = read_state();
    if (as_string(state.day) != today)
        state = { day: today, devices: {}, guest_devices: {} };
    let devices = object_or_empty(state.devices);
    let guest_devices = object_or_empty(state.guest_devices);

    // 1. Parental Control schedules
    for (let schedule in schedules) {
        for (let device in schedule.devices) {
            let ident = device.ident;
            let entry = object_or_empty(devices[ident]);
            let minutes = int(entry.minutes || 0);
            let was_blocked = entry.blocked == true;

            if (!was_blocked && device_active(ident)) {
                minutes++;
                devices[ident] = { minutes, blocked: minutes >= schedule.minutes };
                if (minutes >= schedule.minutes) {
                    log_message("device " + ident + " hit daily quota (" + as_string(schedule.minutes) + " min); blocking until midnight", "info");
                    send_notification("⏳ *Parental control*: устройство `" + ident + "` (" + schedule.label + ") исчерпало дневную квоту (" + as_string(schedule.minutes) + " мин), доступ заблокирован до полуночи.");
                }
            } else {
                devices[ident] = { minutes, blocked: was_blocked };
            }
        }
    }

    // 2. Guest Mode quotas
    if (gm_cfg != null) {
        let target_guests = [];
        if (gm_cfg.mode == "inverted") {
            let trusted_set = {};
            for (let dev in gm_cfg.trusted_devices)
                trusted_set[lc(trim(as_string(dev)))] = true;

            let neighbors = all_active_neighbors();
            for (let neigh in neighbors) {
                let is_trusted = trusted_set[neigh.ip] || (neigh.mac != null && trusted_set[neigh.mac]);
                if (!is_trusted) {
                    let ident = neigh.mac || neigh.ip;
                    push(target_guests, { ident, is_mac: neigh.mac != null, active: true });
                }
            }
        } else {
            for (let dev in gm_cfg.guest_devices) {
                dev = trim(as_string(dev));
                if (dev == "") continue;
                let ident = lc(dev);
                let is_mac = match(ident, MAC_RE) != null;
                push(target_guests, { ident, is_mac, active: device_active(ident) });
            }
        }

        let traffic_bytes_map = read_guest_traffic_bytes();

        for (let guest in target_guests) {
            let ident = guest.ident;
            let entry = object_or_empty(guest_devices[ident]);
            let minutes = int(entry.minutes || 0);
            let bytes = int(traffic_bytes_map[ident] || entry.bytes || 0);
            let was_blocked = entry.blocked == true;

            if (!was_blocked) {
                if (guest.active)
                    minutes++;

                let time_exceeded = gm_cfg.time_limit > 0 && minutes >= gm_cfg.time_limit;
                let traffic_mb = int(bytes / (1024 * 1024));
                let traffic_exceeded = gm_cfg.traffic_limit > 0 && traffic_mb >= gm_cfg.traffic_limit;

                if (time_exceeded || traffic_exceeded) {
                    let reason = time_exceeded ? (as_string(gm_cfg.time_limit) + " мин") : (as_string(gm_cfg.traffic_limit) + " МБ");
                    guest_devices[ident] = { minutes, bytes, blocked: true, reason };
                    log_message("guest device " + ident + " hit quota (" + reason + "); blocking until midnight", "info");
                    if (gm_cfg.notify)
                        send_notification("🚫 *Guest Mode*: устройство `" + ident + "` исчерпало дневную квоту (" + reason + "), доступ заблокирован до полуночи.");
                } else {
                    guest_devices[ident] = { minutes, bytes, blocked: false };
                }
            } else {
                guest_devices[ident] = { minutes, bytes, blocked: true, reason: entry.reason };
            }
        }
    }

    state.devices = devices;
    state.guest_devices = guest_devices;
    write_state(state);

    let lists = blocked_lists(state);
    sync_enforcement(lists.macs, lists.ips);
    return 0;
}

function status_json() {
    let schedules = quota_schedules();
    let gm_cfg = guest_mode_config();
    let state = read_state();
    let tracked = {};
    for (let ident, entry in object_or_empty(state.devices)) {
        entry = object_or_empty(entry);
        tracked[ident] = { minutes: int(entry.minutes || 0), blocked: entry.blocked == true };
    }
    let guest_tracked = {};
    for (let ident, entry in object_or_empty(state.guest_devices)) {
        entry = object_or_empty(entry);
        guest_tracked[ident] = {
            minutes: int(entry.minutes || 0),
            bytes: int(entry.bytes || 0),
            blocked: entry.blocked == true,
            reason: as_string(entry.reason || "")
        };
    }
    write_json({
        configured: length(schedules) > 0 || gm_cfg != null,
        schedules: length(schedules),
        guest_mode: gm_cfg != null ? {
            enabled: true,
            mode: gm_cfg.mode,
            time_limit: gm_cfg.time_limit,
            traffic_limit: gm_cfg.traffic_limit,
            devices: guest_tracked
        } : { enabled: false },
        day: as_string(state.day || ""),
        devices: tracked
    });
}

function reset_quotas() {
    let today = today_str();
    write_state({ day: today, devices: {}, guest_devices: {} });
    sync_enforcement([], []);
    log_message("quotas have been manually reset", "info");
    return 0;
}

let mode = ARGV[0] || "";

if (mode == "tick")
    exit(tick());
else if (mode == "status")
    status_json();
else if (mode == "reset")
    exit(reset_quotas());
else if (mode == "install-cron")
    exit(install_cron());
else if (mode == "remove-cron")
    exit(remove_cron());
else {
    warn("Usage: service/parental_quota.uc <tick|status|reset|install-cron|remove-cron>\n");
    exit(1);
}
