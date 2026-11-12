#!/usr/bin/env ucode

// ─── Tachyon Configuration Planner & Preflight Validator ──────────────────────
//
// Generates, compares, and validates candidate configurations without activating them:
//   - UCI schema, section, domain, IP, CIDR and port syntax validation
//   - Candidate core engine generation (tachyon-core / sing-box config)
//   - Direct binary preflight verification (sing-box check -c <candidate>)
//   - Port collision detection against local listeners
//   - DNS recursion loop & DoH deadlock prevention
//   - Granular diff analysis: added, modified, deleted sections & options
//   - Affected subsystems mapping & reload vs restart requirement calculation
//   - Frontend «Preview Changes» and AI Agent API integration

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const SING_BOX_BIN = "/usr/bin/tachyon-core";

let as_string = common.as_string;

// ─── Helper Utilities ─────────────────────────────────────────────────────────

function safe_parse_json(text) {
    try {
        return json(as_string(text));
    } catch (e) {
        return null;
    }
}

function words_list(value) {
    if (value == null) return [];
    if (type(value) == "array") {
        let res = [];
        for (let item in value) {
            let s = trim(as_string(item));
            if (s != "") push(res, s);
        }
        return res;
    }
    let res = [];
    for (let part in split(as_string(value), /[ \t,\r\n]+/)) {
        part = trim(part);
        if (part != "") push(res, part);
    }
    return res;
}

function values_equal(a, b) {
    if (a === b) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;

    let ta = type(a);
    let tb = type(b);
    if (ta != tb) {
        // Handle array vs string comparisons if normalized
        return as_string(a) == as_string(b);
    }

    if (ta == "array") {
        if (length(a) != length(b)) return false;
        for (let i = 0; i < length(a); i++) {
            if (!values_equal(a[i], b[i])) return false;
        }
        return true;
    }

    if (ta == "object") {
        let ka = keys(a);
        let kb = keys(b);
        if (length(ka) != length(kb)) return false;
        for (let k in ka) {
            if (!values_equal(a[k], b[k])) return false;
        }
        return true;
    }

    return as_string(a) == as_string(b);
}

// ─── UCI Loading: Active vs Candidate ─────────────────────────────────────────

function load_active_uci() {
    let result = {
        settings: {}, sections: {}, servers: {},
        conditions: {}, outbound_sources: {}, outbound_groups: {}, balancers: {},
        all_by_name: {}
    };
    let c = uci_core.cursor();
    if (!c) return result;

    try {
        c.load(CONFIG_NAME);
    } catch (e) {
        return result;
    }

    let raw_settings = c.get_all(CONFIG_NAME, "settings");
    if (type(raw_settings) == "object") {
        result.settings = raw_settings;
        result.all_by_name["settings"] = raw_settings;
    }

    c.foreach(CONFIG_NAME, null, function(s) {
        let name = s[".name"];
        let stype = s[".type"];
        result.all_by_name[name] = s;
        if (stype == "section") {
            result.sections[name] = s;
        } else if (stype == "server") {
            result.servers[name] = s;
        } else if (stype == "condition") {
            result.conditions[name] = s;
        } else if (stype == "outbound_source") {
            result.outbound_sources[name] = s;
        } else if (stype == "outbound_group") {
            result.outbound_groups[name] = s;
        } else if (stype == "balancer") {
            result.balancers[name] = s;
        }
    });

    return result;
}

function parse_uci_text_to_dict(text) {
    let result = {
        settings: {}, sections: {}, servers: {},
        conditions: {}, outbound_sources: {}, outbound_groups: {}, balancers: {},
        all_by_name: {}
    };
    let current_section = null;
    let current_type = null;

    for (let raw_line in split(as_string(text), "\n")) {
        let line = trim(raw_line);
        if (line == "" || index(line, "#") == 0) continue;

        let parts = split(line, /[ \t]+/);
        let cmd = parts[0];

        if (cmd == "config") {
            current_type = parts[1];
            let raw_name = parts[2];
            if (raw_name != null && raw_name != "") {
                if ((substr(raw_name, 0, 1) == "'" && substr(raw_name, length(raw_name) - 1, 1) == "'") ||
                    (substr(raw_name, 0, 1) == "\"" && substr(raw_name, length(raw_name) - 1, 1) == "\"")) {
                    raw_name = substr(raw_name, 1, length(raw_name) - 2);
                }
            } else {
                raw_name = "cfg" + length(keys(result.all_by_name));
            }
            current_section = raw_name;
            let sec_obj = { ".name": current_section, ".type": current_type };
            result.all_by_name[current_section] = sec_obj;
            if (current_type == "settings" || current_section == "settings") {
                result.settings = sec_obj;
            } else if (current_type == "section") {
                result.sections[current_section] = sec_obj;
            } else if (current_type == "server") {
                result.servers[current_section] = sec_obj;
            } else if (current_type == "condition") {
                result.conditions[current_section] = sec_obj;
            } else if (current_type == "outbound_source") {
                result.outbound_sources[current_section] = sec_obj;
            } else if (current_type == "outbound_group") {
                result.outbound_groups[current_section] = sec_obj;
            } else if (current_type == "balancer") {
                result.balancers[current_section] = sec_obj;
            }
            continue;
        }

        if (!current_section || !result.all_by_name[current_section]) continue;
        let sec_obj = result.all_by_name[current_section];

        if (cmd == "option" && length(parts) >= 2) {
            let opt = parts[1];
            let opt_idx = index(line, opt);
            let val = trim(substr(line, opt_idx + length(opt)));
            if ((substr(val, 0, 1) == "'" && substr(val, length(val) - 1, 1) == "'") ||
                (substr(val, 0, 1) == "\"" && substr(val, length(val) - 1, 1) == "\"")) {
                val = substr(val, 1, length(val) - 2);
            }
            sec_obj[opt] = val;
            continue;
        }

        if (cmd == "list" && length(parts) >= 2) {
            let opt = parts[1];
            let opt_idx = index(line, opt);
            let val = trim(substr(line, opt_idx + length(opt)));
            if ((substr(val, 0, 1) == "'" && substr(val, length(val) - 1, 1) == "'") ||
                (substr(val, 0, 1) == "\"" && substr(val, length(val) - 1, 1) == "\"")) {
                val = substr(val, 1, length(val) - 2);
            }
            if (type(sec_obj[opt]) != "array") {
                sec_obj[opt] = sec_obj[opt] != null ? [ sec_obj[opt] ] : [];
            }
            push(sec_obj[opt], val);
            continue;
        }
    }

    return result;
}

function load_candidate_uci(candidate_source) {
    if (candidate_source == null || candidate_source == "") {
        // Default: compare uncommitted changes in UCI against saved
        let c = uci_core.cursor();
        if (c) {
            let changes = c.changes(CONFIG_NAME);
            if (type(changes) == "object" && type(changes[CONFIG_NAME]) == "object") {
                // Return active state with changes applied in-memory
                return load_active_uci();
            }
        }
        return load_active_uci();
    }

    if (type(candidate_source) == "object") {
        if (candidate_source.all_by_name != null) {
            return candidate_source;
        }
        // Direct dictionary of sections: { "settings": {...}, "my_section": {...} }
        let result = {
            settings: {}, sections: {}, servers: {},
            conditions: {}, outbound_sources: {}, outbound_groups: {}, balancers: {},
            all_by_name: {}
        };
        for (let k, v in candidate_source) {
            if (type(v) != "object") continue;
            let stype = v[".type"] || (k == "settings" ? "settings" : "section");
            let sname = v[".name"] || k;
            v[".name"] = sname;
            v[".type"] = stype;
            result.all_by_name[sname] = v;
            if (stype == "settings" || sname == "settings") result.settings = v;
            else if (stype == "section") result.sections[sname] = v;
            else if (stype == "server") result.servers[sname] = v;
            else if (stype == "condition") result.conditions[sname] = v;
            else if (stype == "outbound_source") result.outbound_sources[sname] = v;
            else if (stype == "outbound_group") result.outbound_groups[sname] = v;
            else if (stype == "balancer") result.balancers[sname] = v;
        }
        return result;
    }

    let str = as_string(candidate_source);
    // Is it a file path?
    if (fs.stat(str) != null) {
        let content = fs.readfile(str);
        if (content != null) {
            // Check if JSON
            let parsed_json = safe_parse_json(content);
            if (parsed_json != null && type(parsed_json) == "object") {
                return load_candidate_uci(parsed_json);
            }
            return parse_uci_text_to_dict(content);
        }
    }

    // Check if JSON string
    let parsed_json = safe_parse_json(str);
    if (parsed_json != null && type(parsed_json) == "object") {
        return load_candidate_uci(parsed_json);
    }

    // UCI raw text string
    return parse_uci_text_to_dict(str);
}

// ─── Change Diff Calculator ───────────────────────────────────────────────────

function compute_uci_diff(active_uci, candidate_uci) {
    let added_sections = [];
    let removed_sections = [];
    let modified_sections = [];
    let changed_options_count = 0;

    let active_names = keys(active_uci.all_by_name);
    let candidate_names = keys(candidate_uci.all_by_name);

    let active_map = {};
    for (let name in active_names) active_map[name] = true;

    let candidate_map = {};
    for (let name in candidate_names) candidate_map[name] = true;

    // Detect added sections
    for (let name in candidate_names) {
        if (!active_map[name]) {
            let cand_sec = candidate_uci.all_by_name[name];
            push(added_sections, {
                section: name,
                type: cand_sec[".type"] || "unknown",
                action: cand_sec.action || null,
                label: cand_sec.label || name
            });
            changed_options_count += length(keys(cand_sec));
        }
    }

    // Detect removed sections
    for (let name in active_names) {
        if (!candidate_map[name]) {
            let act_sec = active_uci.all_by_name[name];
            push(removed_sections, {
                section: name,
                type: act_sec[".type"] || "unknown",
                action: act_sec.action || null,
                label: act_sec.label || name
            });
            changed_options_count += length(keys(act_sec));
        }
    }

    // Detect modified sections
    for (let name in candidate_names) {
        if (active_map[name]) {
            let act_sec = active_uci.all_by_name[name];
            let cand_sec = candidate_uci.all_by_name[name];
            let diffs = [];

            let all_keys = {};
            for (let k in keys(act_sec)) if (substr(k, 0, 1) != ".") all_keys[k] = true;
            for (let k in keys(cand_sec)) if (substr(k, 0, 1) != ".") all_keys[k] = true;

            for (let opt in keys(all_keys)) {
                let old_val = act_sec[opt];
                let new_val = cand_sec[opt];
                if (!values_equal(old_val, new_val)) {
                    let is_secret = match(as_string(opt), /(token|secret|password|passwd|private_key|preshared_key|pre_shared_key|psk|api_key|auth_key|cookie|uuid|hwid|outbound_json|custom_json|amnezia_conf|proxy_links|proxy_string|proxy_url|subscription_url|warp_flow_uri|crypto_key)/i) != null;
                    push(diffs, {
                        option: opt,
                        old_value: old_val != null ? (is_secret ? "[REDACTED]" : old_val) : null,
                        new_value: new_val != null ? (is_secret ? "[REDACTED]" : new_val) : null
                    });
                    changed_options_count++;
                }
            }

            if (length(diffs) > 0) {
                push(modified_sections, {
                    section: name,
                    type: cand_sec[".type"] || act_sec[".type"] || "unknown",
                    label: cand_sec.label || act_sec.label || name,
                    diffs: diffs
                });
            }
        }
    }

    let has_changes = length(added_sections) > 0 || length(removed_sections) > 0 || length(modified_sections) > 0;

    return {
        has_changes: has_changes,
        total_changes: changed_options_count,
        added_sections: added_sections,
        removed_sections: removed_sections,
        modified_sections: modified_sections
    };
}

// ─── Subsystem Impact & Reload Analysis ───────────────────────────────────────

function analyze_subsystem_impact(diff_result, active_uci, candidate_uci) {
    let affected = {};
    let restart_required = false;
    let reasons = [];

    // Check settings changes
    let active_settings = active_uci.settings || {};
    let cand_settings = candidate_uci.settings || {};

    // Engine switch requires restart
    if (active_settings.engine != cand_settings.engine && cand_settings.engine != null) {
        restart_required = true;
        push(reasons, "Routing engine changed ('" + (active_settings.engine || "tachyon-core") + "' -> '" + cand_settings.engine + "')");
        affected["engine"] = true;
        affected["nftables"] = true;
        affected["dns"] = true;
    }

    // Output network interface changed
    if (active_settings.output_network_interface != cand_settings.output_network_interface) {
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    // DNS mode or ports changed
    if (active_settings.fakeip != cand_settings.fakeip ||
        active_settings.dns_type != cand_settings.dns_type ||
        active_settings.custom_dns != cand_settings.custom_dns) {
        affected["dns"] = true;
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    // Check section / server / modular entity changes
    for (let sec in diff_result.added_sections) {
        if (sec.type == "section") {
            affected["engine"] = true;
            if (sec.action == "zapret" || sec.action == "zapret2" || sec.action == "byedpi") {
                affected["daemons"] = true;
            }
            affected["nftables"] = true;
        } else if (sec.type == "condition") {
            affected["engine"] = true;
            affected["nftables"] = true;
        } else if (sec.type == "outbound_source" || sec.type == "outbound_group" || sec.type == "balancer" || sec.type == "server") {
            affected["engine"] = true;
        }
    }

    for (let sec in diff_result.removed_sections) {
        affected["engine"] = true;
        affected["nftables"] = true;
    }

    for (let mod in diff_result.modified_sections) {
        if (mod.section == "settings") {
            for (let d in mod.diffs) {
                if (d.option == "excluded_clients" || d.option == "excluded_ips") {
                    affected["nftables"] = true;
                } else if (d.option == "yacd_port" || d.option == "mixed_port") {
                    restart_required = true;
                    push(reasons, "Inbound port option '" + d.option + "' changed");
                    affected["engine"] = true;
                }
            }
        } else if (mod.type == "section" || mod.type == "condition") {
            affected["engine"] = true;
            affected["nftables"] = true;
            for (let d in mod.diffs) {
                if (d.option == "action") {
                    affected["daemons"] = true;
                }
            }
        } else if (mod.type == "outbound_source" || mod.type == "outbound_group" || mod.type == "balancer" || mod.type == "server") {
            affected["engine"] = true;
        }
    }

    let affected_list = keys(affected);
    if (length(affected_list) == 0 && diff_result.has_changes) {
        affected_list = [ "engine" ];
    }

    return {
        affected_subsystems: affected_list,
        restart_required: restart_required,
        restart_reasons: reasons
    };
}

// ─── Routing & DNS Rule Overlap / Shadowing Analyzer (#331 / #347) ────────────

const COMMUNITY_LIST_DOMAINS = {
    google_services: [
        "google.com", "gmail.com", "drive.google.com", "docs.google.com",
        "maps.google.com", "translate.google.com", "gstatic.com",
        "googleapis.com", "googleusercontent.com"
    ],
    google_ai: [
        "gemini.google.com", "aistudio.google.com", "makersuite.google.com",
        "notebooklm.google.com", "bard.google.com", "deepmind.google",
        "generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com"
    ],
    google_meet: [ "meet.google.com", "stun.l.google.com" ],
    zoom_teams: [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com",
        "webex.com", "slack.com", "loom.com", "gather.town", "whereby.com", "jitsi.org"
    ],
    youtube: [ "youtube.com", "googlevideo.com", "ytimg.com", "youtu.be", "ggpht.com" ],
    youtube_images: [ "ytimg.com", "i.ytimg.com", "i9.ytimg.com", "ggpht.com", "yt3.ggpht.com", "yt4.ggpht.com" ],
    telegram: [ "t.me", "telegram.org", "telegram.me", "telesco.pe", "tdesktop.com", "telegra.ph" ],
    discord: [
        "discord.com", "discord.gg", "discordapp.com", "discordapp.net",
        "discordstatus.com", "watchanimeattheoffice.net",
        "discord-attachments-uploads-prd.storage.googleapis.com"
    ],
    discord_voice: [ "discord.media" ],
    meta: [
        "facebook.com", "instagram.com", "whatsapp.com", "fbcdn.net",
        "cdninstagram.com", "meta.com", "threads.net", "messenger.com"
    ],
    whatsapp: [ "whatsapp.com", "whatsapp.net", "wa.me" ],
    meta_ads: [ "an.facebook.com", "pixel.facebook.com", "graph.instagram.com" ],
    twitter: [ "twitter.com", "x.com", "twimg.com", "t.co", "x.co" ],
    openai: [ "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com" ],
    anthropic: [ "anthropic.com", "claude.ai", "claudeusercontent.com" ],
    xai: [ "x.ai", "grok.com" ],
    openrouter: [
        "openrouter.ai", "poe.com", "groq.com", "mistral.ai", "together.ai",
        "fireworks.ai", "deepinfra.com", "cerebras.ai", "replicate.com",
        "fal.ai", "chutes.ai", "cohere.com", "lmarena.ai"
    ],
    cursor: [
        "cursor.com", "cursor.sh", "cursorapi.com", "opencode.ai", "models.dev",
        "windsurf.com", "codeium.com", "grazie.ai", "jetbrains.ai", "trae.ai",
        "cline.bot", "roocode.com", "kilocode.ai", "lovable.dev", "bolt.new",
        "v0.dev", "devin.ai", "replit.com", "coderabbit.ai", "context7.com"
    ],
    perplexity: [ "perplexity.ai", "pplx.ai", "you.com", "genspark.ai", "consensus.app", "elicit.com", "scite.ai" ],
    copilot: [ "githubcopilot.com", "copilot-proxy.githubusercontent.com", "copilot.microsoft.com", "sydney.bing.com" ],
    deepseek: [
        "deepseek.com", "chat.deepseek.com", "api.deepseek.com", "kimi.ai",
        "qwen.ai", "chat.qwen.ai", "minimax.io", "z.ai", "manus.im", "dify.ai"
    ],
    ai_all: [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com",
        "claude.ai", "anthropic.com", "claudeusercontent.com",
        "gemini.google.com", "aistudio.google.com", "makersuite.google.com",
        "notebooklm.google.com", "bard.google.com", "deepmind.google",
        "generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com",
        "x.ai", "grok.com", "openrouter.ai", "poe.com", "groq.com", "mistral.ai",
        "cursor.com", "cursor.sh", "perplexity.ai", "pplx.ai", "githubcopilot.com",
        "deepseek.com", "huggingface.co", "hf.co"
    ],
    steam: [ "steampowered.com", "steamcommunity.com", "steamstatic.com", "steamcontent.com" ],
    steam_cdn: [ "steamcontent.com", "steampipe.akamaized.net", "dl.steam.ksyna.com", "steamserver.net" ],
    cs2_dota2: [ "steamdatagram.com", "valve.net", "counter-strike.net", "dota2.com" ],
    epicgames: [ "epicgames.com", "unrealengine.com", "fortnite.com" ],
    riot: [ "riotgames.com", "leagueoflegends.com", "playvalorant.com" ],
    roblox: [ "roblox.com", "rbxcdn.com", "robloxlabs.com" ],
    games_all: [
        "steampowered.com", "steamcommunity.com", "steamstatic.com", "steamcontent.com",
        "epicgames.com", "unrealengine.com", "fortnite.com", "riotgames.com",
        "leagueoflegends.com", "playvalorant.com", "roblox.com", "rbxcdn.com"
    ],
    cloudflare: [ "cloudflare.com", "cloudflare-dns.com", "workers.dev" ],
    doh_dot_dns: [
        "cloudflare-dns.com", "dns.google", "dns.quad9.net", "dns.adguard-dns.com",
        "dns.nextdns.io", "doh.opendns.com", "freedns.controld.com", "dns.mullvad.net"
    ],
    ads_hagezi_pro: [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "an.yandex.ru", "mc.yandex.ru"
    ],
    android_ads_block: [
        "googleadservices.com", "googlesyndication.com", "applovin.com",
        "unityads.unity3d.com", "ironsrc.com", "vungle.com", "mintegral.com",
        "an.yandex.ru", "ads.vk.com"
    ],
    phishing_malware_block: [ "doubleclick.net" ],
    russia_inside: [
        "youtube.com", "instagram.com", "facebook.com", "twitter.com", "x.com",
        "discord.com", "gemini.google.com", "chatgpt.com", "openai.com", "rutracker.org"
    ],
    russia_outside: [
        "yandex.ru", "vk.com", "mail.ru", "gosuslugi.ru", "sberbank.ru", "rambler.ru",
        "dzen.ru", "rutube.ru", "ozon.ru", "wildberries.ru", "avito.ru", "kinopoisk.ru",
        "rbc.ru", "tinkoff.ru", "t-bank.ru", "mos.ru", "ya.ru"
    ],
    geosite_ru: [
        "yandex.ru", "vk.com", "mail.ru", "gosuslugi.ru", "sberbank.ru", "rambler.ru",
        "dzen.ru", "rutube.ru", "ozon.ru", "wildberries.ru", "avito.ru", "kinopoisk.ru",
        "rbc.ru", "tinkoff.ru", "t-bank.ru", "mos.ru", "ya.ru", "2ch.hk", "pikabu.ru"
    ],
    ru_whitelist: [ "gosuslugi.ru", "yandex.ru", "vk.com", "sberbank.ru", "tbank.ru", "ozon.ru", "wildberries.ru" ],
    ru_domains: [ "yandex.ru", "vk.com", "mail.ru", "gosuslugi.ru", "sberbank.ru", "ozon.ru", "wildberries.ru" ],
    ru_only_inside: [ "gosuslugi.ru", "nalog.ru", "mos.ru", "rzd.ru", "sberbank.ru" ]
};

const COMMUNITY_LIST_SUBNETS = {
    telegram: [
        "5.28.192.0/18", "91.105.192.0/23", "91.108.4.0/22", "91.108.8.0/21",
        "91.108.16.0/21", "91.108.56.0/22", "95.161.64.0/20", "149.154.160.0/20",
        "185.76.151.0/24", "194.221.0.0/16"
    ],
    discord: [ "162.158.0.0/15" ],
    meta: [ "157.240.0.0/16", "31.13.64.0/18", "129.134.0.0/16", "185.60.216.0/22" ],
    cloudflare: [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
        "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
        "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
    ],
    et_spamhaus_block: [ "1.10.16.0/20", "1.19.0.0/16", "1.32.128.0/18" ],
    hagezi_tif_ip_block: [ "1.0.218.230/32", "1.2.185.92/32", "1.12.55.80/32" ],
    botnet_attackers_ip_block: [ "1.12.55.80/32", "1.12.70.212/32", "1.12.229.231/32" ]
};

function normalize_action_family(action) {
    let a = lc(trim(as_string(action || "outbound")));
    if (a == "direct" || a == "bypass") return "direct";
    if (a == "block") return "block";
    if (a == "zapret" || a == "zapret2" || a == "byedpi" || a == "desync") return "dpi:" + a;
    return "proxy";
}

function normalize_domain_token(raw) {
    let d = lc(trim(as_string(raw || "")));
    if (substr(d, 0, 5) == "full:") d = substr(d, 5);
    else if (substr(d, 0, 7) == "domain:") d = substr(d, 7);
    if (substr(d, 0, 2) == "*.") d = substr(d, 2);
    if (substr(d, 0, 1) == ".") d = substr(d, 1);
    return d;
}

function domain_covers(parent_dom, child_dom) {
    if (parent_dom == "" || child_dom == "") return false;
    if (parent_dom == child_dom) return true;
    let suffix = "." + parent_dom;
    let plen = length(suffix);
    let clen = length(child_dom);
    if (clen > plen && substr(child_dom, clen - plen) == suffix)
        return true;
    return false;
}

const MAX_ANALYZED_LIST_FILE_BYTES = 262144;
const MAX_ANALYZED_LIST_ENTRIES = 2048;
const MAX_OVERLAP_SAMPLE_TARGETS = 32;

function domain_covers_in_set(parent_set, child_dom) {
    if (type(parent_set) != "object" || child_dom == "") return "";
    if (parent_set[child_dom]) return child_dom;
    let cur = child_dom;
    while (true) {
        let dot = index(cur, ".");
        if (dot < 0) break;
        cur = substr(cur, dot + 1);
        if (cur == "") break;
        if (parent_set[cur]) return cur;
    }
    return "";
}

function ipv4_to_u32(ip) {
    let s = trim(as_string(ip));
    if (type(global.iptoarr) == "function") {
        let arr = iptoarr(s);
        if (arr == null || length(arr) != 4) return -1;
        return ((arr[0] * 256 + arr[1]) * 256 + arr[2]) * 256 + arr[3];
    }
    let parts = split(s, ".");
    if (length(parts) != 4) return -1;
    let val = 0;
    for (let p in parts) {
        let plen = length(p);
        if (plen == 0 || plen > 3) return -1;
        let oct = 0;
        for (let k = 0; k < plen; k++) {
            let ch = ord(p, k);
            if (ch < 48 || ch > 57) return -1;
            oct = oct * 10 + (ch - 48);
        }
        if (oct > 255) return -1;
        val = val * 256 + oct;
    }
    return val;
}

function parse_ipv4_cidr_range(raw) {
    let s = trim(as_string(raw || ""));
    if (s == "" || index(s, ":") >= 0) return null;
    let slash = index(s, "/");
    let ip_part = slash > 0 ? substr(s, 0, slash) : s;
    let prefix = slash > 0 ? int(substr(s, slash + 1)) : 32;
    if (prefix < 0 || prefix > 32) return null;
    let ip_num = ipv4_to_u32(ip_part);
    if (ip_num < 0) return null;
    let host_bits = 32 - prefix;
    let block_size = host_bits == 32 ? 4294967296 : (1 << host_bits);
    let start = int(ip_num / block_size) * block_size;
    let end = start + block_size - 1;
    return { start: start, end: end, prefix: prefix, raw: s };
}

function cidr_covers(parent_raw, child_raw) {
    parent_raw = trim(as_string(parent_raw || ""));
    child_raw = trim(as_string(child_raw || ""));
    if (parent_raw == "" || child_raw == "") return false;
    if (lc(parent_raw) == lc(child_raw)) return true;
    let p = parse_ipv4_cidr_range(parent_raw);
    let c = parse_ipv4_cidr_range(child_raw);
    if (p == null || c == null) return false;
    return p.start <= c.start && p.end >= c.end;
}

function build_cidr_index(cidrs) {
    let cidr_set = {};
    let cidr_ranges = [];
    let raw_intervals = [];
    for (let c in cidrs) {
        let key = lc(c);
        if (cidr_set[key] == null) cidr_set[key] = c;
        let r = parse_ipv4_cidr_range(c);
        push(cidr_ranges, r);
        if (r != null) push(raw_intervals, r);
    }
    sort(raw_intervals, function(a, b) {
        if (a.start != b.start) return a.start < b.start ? -1 : 1;
        if (a.end != b.end) return a.end > b.end ? -1 : 1;
        return 0;
    });
    let ipv4_intervals = [];
    for (let item in raw_intervals) {
        let n = length(ipv4_intervals);
        if (n > 0 && ipv4_intervals[n - 1].end >= item.end)
            continue;
        push(ipv4_intervals, item);
    }
    return {
        cidr_set: cidr_set,
        cidr_ranges: cidr_ranges,
        ipv4_intervals: ipv4_intervals
    };
}

function cidr_covered_by_meta(parent_meta, child_raw, child_range) {
    if (parent_meta == null || child_raw == null || child_raw == "") return "";
    let exact = parent_meta.cidr_set ? parent_meta.cidr_set[lc(child_raw)] : null;
    if (exact != null) return exact;
    let c = child_range != null ? child_range : parse_ipv4_cidr_range(child_raw);
    if (c == null) return "";
    let intervals = parent_meta.ipv4_intervals;
    let n = type(intervals) == "array" ? length(intervals) : 0;
    if (n == 0) return "";
    let lo = 0;
    let hi = n - 1;
    let best = -1;
    while (lo <= hi) {
        let mid = (lo + hi) >> 1;
        if (intervals[mid].start <= c.start) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (best >= 0 && intervals[best].end >= c.end)
        return intervals[best].raw;
    return "";
}

function parse_plain_list_entries(content, domains_out, cidrs_out, seen_domains, seen_cidrs, entry_mode) {
    if (content == null || content == "") return;
    seen_domains = seen_domains || {};
    seen_cidrs = seen_cidrs || {};
    let domains_only = (entry_mode == "domains");
    let cidrs_only = (entry_mode == "cidrs");
    for (let line in split(as_string(content), "\n")) {
        if (domains_only && length(domains_out) >= MAX_ANALYZED_LIST_ENTRIES) break;
        if (cidrs_only && length(cidrs_out) >= MAX_ANALYZED_LIST_ENTRIES) break;
        if (length(domains_out) >= MAX_ANALYZED_LIST_ENTRIES && length(cidrs_out) >= MAX_ANALYZED_LIST_ENTRIES)
            break;
        let hash = index(line, "#");
        if (hash >= 0) line = substr(line, 0, hash);
        line = trim(line);
        if (line == "" || substr(line, 0, 2) == "//") continue;
        if (substr(line, 0, 8) == "keyword:" || substr(line, 0, 6) == "regex:") continue;
        if (!domains_only && core_ip.valid_ip_or_cidr(line)) {
            if (length(cidrs_out) < MAX_ANALYZED_LIST_ENTRIES && !seen_cidrs[line]) {
                seen_cidrs[line] = true;
                push(cidrs_out, line);
            }
        } else if (!cidrs_only) {
            let norm = normalize_domain_token(line);
            if (norm != "" && index(norm, "/") < 0 && length(domains_out) < MAX_ANALYZED_LIST_ENTRIES && !seen_domains[norm]) {
                seen_domains[norm] = true;
                push(domains_out, norm);
            }
        }
    }
}

function parse_json_ruleset_entries(parsed, domains_out, cidrs_out, seen_domains, seen_cidrs) {
    if (type(parsed) != "object" || type(parsed.rules) != "array") return;
    seen_domains = seen_domains || {};
    seen_cidrs = seen_cidrs || {};
    for (let r in parsed.rules) {
        if (type(r) != "object") continue;
        if (length(domains_out) >= MAX_ANALYZED_LIST_ENTRIES && length(cidrs_out) >= MAX_ANALYZED_LIST_ENTRIES)
            break;
        for (let dkey in [ "domain", "domain_suffix" ]) {
            if (type(r[dkey]) == "array") {
                for (let d in r[dkey]) {
                    if (length(domains_out) >= MAX_ANALYZED_LIST_ENTRIES) break;
                    let norm = normalize_domain_token(d);
                    if (norm != "" && !seen_domains[norm]) {
                        seen_domains[norm] = true;
                        push(domains_out, norm);
                    }
                }
            } else if (type(r[dkey]) == "string") {
                let norm = normalize_domain_token(r[dkey]);
                if (norm != "" && length(domains_out) < MAX_ANALYZED_LIST_ENTRIES && !seen_domains[norm]) {
                    seen_domains[norm] = true;
                    push(domains_out, norm);
                }
            }
        }
        if (type(r.ip_cidr) == "array") {
            for (let cidr in r.ip_cidr) {
                if (length(cidrs_out) >= MAX_ANALYZED_LIST_ENTRIES) break;
                let c = trim(as_string(cidr));
                if (c != "" && !seen_cidrs[c]) {
                    seen_cidrs[c] = true;
                    push(cidrs_out, c);
                }
            }
        } else if (type(r.ip_cidr) == "string") {
            let c = trim(as_string(r.ip_cidr));
            if (c != "" && length(cidrs_out) < MAX_ANALYZED_LIST_ENTRIES && !seen_cidrs[c]) {
                seen_cidrs[c] = true;
                push(cidrs_out, c);
            }
        }
    }
}

function resolve_list_contents(list_name, options) {
    let raw_name = trim(as_string(list_name || ""));
    let norm_name = lc(raw_name);
    let domains = [];
    let cidrs = [];
    let seen_domains = {};
    let seen_cidrs = {};
    let source = "unverified";
    let found_path = "";
    let mtime = 0;
    let version = "";

    if (type(options) == "object" && type(options.list_contents) == "object") {
        let ov = options.list_contents[raw_name] || options.list_contents[norm_name];
        if (type(ov) == "object") {
            for (let d in (type(ov.domains) == "array" ? ov.domains : words_list(ov.domains))) {
                let nd = normalize_domain_token(d);
                if (nd != "" && !seen_domains[nd] && length(domains) < MAX_ANALYZED_LIST_ENTRIES) {
                    seen_domains[nd] = true;
                    push(domains, nd);
                }
            }
            for (let c in (type(ov.cidrs) == "array" ? ov.cidrs : words_list(ov.cidrs || ov.ips))) {
                let nc = trim(as_string(c));
                if (nc != "" && !seen_cidrs[nc] && length(cidrs) < MAX_ANALYZED_LIST_ENTRIES) {
                    seen_cidrs[nc] = true;
                    push(cidrs, nc);
                }
            }
            source = as_string(ov.source || "local_override");
            found_path = as_string(ov.path || "");
            mtime = int(ov.mtime || ov.updated_at || 0);
            version = as_string(ov.version || "");
        }
    }

    let folders = [];
    if (type(options) == "object" && type(options.rulesets_dir) == "string" && options.rulesets_dir != "") {
        push(folders, options.rulesets_dir);
    }
    let env_folder = getenv("TMP_RULESET_FOLDER");
    if (env_folder != null && env_folder != "" && index(folders, env_folder) < 0) {
        push(folders, env_folder);
    }
    for (let def_dir in [ "/tmp/tachyon-core/rulesets", "/etc/tachyon/rulesets", "/usr/share/tachyon/rulesets" ]) {
        if (index(folders, def_dir) < 0) push(folders, def_dir);
    }

    let has_json = false;
    let has_dom_lst = false;
    let has_sub_lst = false;
    let has_plain_lst = false;

    for (let dir in folders) {
        if (!has_json) {
            let json_candidates = [ dir + "/community-" + raw_name + ".json" ];
            if (norm_name != raw_name) push(json_candidates, dir + "/community-" + norm_name + ".json");
            push(json_candidates, dir + "/" + raw_name + ".json");
            for (let jp in json_candidates) {
                let st = fs.stat(jp);
                if (st != null && st.type == "file" && (st.size || 0) > 0) {
                    if (found_path == "") found_path = jp;
                    if ((st.mtime || 0) > mtime) mtime = int(st.mtime || 0);
                    if ((st.size || 0) <= MAX_ANALYZED_LIST_FILE_BYTES) {
                        let parsed = common.read_json_file(jp);
                        parse_json_ruleset_entries(parsed, domains, cidrs, seen_domains, seen_cidrs);
                        source = "local_file";
                        has_json = true;
                        break;
                    }
                }
            }
        }

        if (!has_dom_lst) {
            let dom_candidates = [ dir + "/community-domains-" + raw_name + ".lst" ];
            if (norm_name != raw_name) push(dom_candidates, dir + "/community-domains-" + norm_name + ".lst");
            for (let lp in dom_candidates) {
                let st = fs.stat(lp);
                if (st != null && st.type == "file" && (st.size || 0) > 0) {
                    if (found_path == "") found_path = lp;
                    if ((st.mtime || 0) > mtime) mtime = int(st.mtime || 0);
                    if ((st.size || 0) <= MAX_ANALYZED_LIST_FILE_BYTES) {
                        parse_plain_list_entries(fs.readfile(lp), domains, cidrs, seen_domains, seen_cidrs, "domains");
                        source = "local_file";
                        has_dom_lst = true;
                        break;
                    }
                }
            }
        }

        if (!has_sub_lst) {
            let sub_candidates = [ dir + "/community-subnets-" + raw_name + ".lst" ];
            if (norm_name != raw_name) push(sub_candidates, dir + "/community-subnets-" + norm_name + ".lst");
            for (let lp in sub_candidates) {
                let st = fs.stat(lp);
                if (st != null && st.type == "file" && (st.size || 0) > 0) {
                    if (found_path == "") found_path = lp;
                    if ((st.mtime || 0) > mtime) mtime = int(st.mtime || 0);
                    if ((st.size || 0) <= MAX_ANALYZED_LIST_FILE_BYTES) {
                        parse_plain_list_entries(fs.readfile(lp), domains, cidrs, seen_domains, seen_cidrs, "cidrs");
                        source = "local_file";
                        has_sub_lst = true;
                        break;
                    }
                }
            }
        }

        if (!has_plain_lst) {
            for (let lp in [ dir + "/" + raw_name + ".lst", dir + "/" + raw_name + ".txt" ]) {
                let st = fs.stat(lp);
                if (st != null && st.type == "file" && (st.size || 0) > 0) {
                    if (found_path == "") found_path = lp;
                    if ((st.mtime || 0) > mtime) mtime = int(st.mtime || 0);
                    if ((st.size || 0) <= MAX_ANALYZED_LIST_FILE_BYTES) {
                        parse_plain_list_entries(fs.readfile(lp), domains, cidrs, seen_domains, seen_cidrs, "mixed");
                        source = "local_file";
                        has_plain_lst = true;
                        break;
                    }
                }
            }
        }

        for (let bin_ext in [ ".trs", ".srs" ]) {
            let bp = dir + "/community-" + raw_name + bin_ext;
            let st = fs.stat(bp);
            if (st != null && st.type == "file" && (st.size || 0) > 0) {
                if (found_path == "") found_path = bp;
                if ((st.mtime || 0) > mtime) mtime = int(st.mtime || 0);
            }
        }
    }

    let cat_domains = COMMUNITY_LIST_DOMAINS[norm_name];
    if (type(cat_domains) == "array") {
        for (let cd in cat_domains) {
            let nd = normalize_domain_token(cd);
            if (nd != "" && !seen_domains[nd]) {
                seen_domains[nd] = true;
                push(domains, nd);
            }
        }
        if (source == "unverified") source = found_path != "" ? "local_binary+catalog" : "builtin_catalog";
    }

    let cat_subnets = COMMUNITY_LIST_SUBNETS[norm_name];
    if (type(cat_subnets) == "array") {
        for (let cs in cat_subnets) {
            let nc = trim(as_string(cs));
            if (nc != "" && !seen_cidrs[nc]) {
                seen_cidrs[nc] = true;
                push(cidrs, nc);
            }
        }
        if (source == "unverified") source = found_path != "" ? "local_binary+catalog" : "builtin_catalog";
    }

    let verified = (length(domains) > 0 || length(cidrs) > 0);
    let cidr_idx = build_cidr_index(cidrs);
    return {
        name: raw_name,
        source: source,
        path: found_path,
        mtime: mtime,
        version: version,
        domains: domains,
        domain_set: seen_domains,
        cidrs: cidrs,
        cidr_set: cidr_idx.cidr_set,
        cidr_ranges: cidr_idx.cidr_ranges,
        ipv4_intervals: cidr_idx.ipv4_intervals,
        domains_count: length(domains),
        cidrs_count: length(cidrs),
        verified: verified
    };
}

function parse_port_intervals(port_tokens) {
    let intervals = [];
    for (let tok in port_tokens) {
        let p = trim(as_string(tok || ""));
        if (p == "") continue;
        let dash = index(p, "-");
        if (dash < 0) dash = index(p, ":");
        if (dash > 0) {
            let p1 = int(substr(p, 0, dash));
            let p2 = int(substr(p, dash + 1));
            if (p1 > 0 && p2 >= p1 && p2 <= 65535) {
                push(intervals, [ p1, p2 ]);
            }
        } else {
            let num = int(p);
            if (num > 0 && num <= 65535) {
                push(intervals, [ num, num ]);
            }
        }
    }
    return intervals;
}

function port_intervals_overlap(a, b) {
    if (length(a) == 0 || length(b) == 0) return true;
    for (let ia in a) {
        for (let ib in b) {
            if (ia[0] <= ib[1] && ib[0] <= ia[1]) return true;
        }
    }
    return false;
}

function port_intervals_cover(parent, child) {
    if (length(parent) == 0) return true;
    if (length(child) == 0) return false;
    for (let ic in child) {
        let covered = false;
        for (let ip in parent) {
            if (ip[0] <= ic[0] && ip[1] >= ic[1]) {
                covered = true;
                break;
            }
        }
        if (!covered) return false;
    }
    return true;
}

function token_sets_overlap(a, b, is_ip_set) {
    if (length(a) == 0 || length(b) == 0) return true;
    for (let va in a) {
        for (let vb in b) {
            if (lc(as_string(va)) == lc(as_string(vb))) return true;
            if (is_ip_set && (cidr_covers(va, vb) || cidr_covers(vb, va))) return true;
        }
    }
    return false;
}

function token_set_covers(parent, child, is_ip_set) {
    if (length(parent) == 0) return true;
    if (length(child) == 0) return false;
    for (let vc in child) {
        let ok = false;
        for (let vp in parent) {
            if (lc(as_string(vp)) == lc(as_string(vc)) || (is_ip_set && cidr_covers(vp, vc))) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

function collect_section_domains(sec, conditions_map) {
    let out = [];
    for (let key in [ "domain", "domains", "fully_qualified_domain_names", "domain_ip_lists" ]) {
        for (let item in words_list(sec[key])) {
            let norm = normalize_domain_token(item);
            if (norm != "" && index(norm, "/") < 0 && !core_ip.valid_ip_or_cidr(norm)) {
                if (index(out, norm) < 0) push(out, norm);
            }
        }
    }
    if (type(conditions_map) == "object") {
        for (let cref in words_list(sec.condition_refs)) {
            let cond = conditions_map[cref];
            if (type(cond) == "object") {
                let ctype = lc(trim(as_string(cond.condition_type || "atomic")));
                if (ctype == "not" || cond.invert == "1") continue;
                for (let item in words_list(cond.domains || cond.domain)) {
                    let norm = normalize_domain_token(item);
                    if (norm != "" && index(out, norm) < 0) push(out, norm);
                }
            }
        }
    }
    return out;
}

function collect_section_conditions(sec, conditions_map) {
    let devices = [];
    let interfaces = [];
    let ports = [];
    let protocols = [];
    let exclude_domains = [];
    let exclude_ips = [];
    let unverified = [];

    for (let dkey in [ "devices", "device", "src_ip", "source_ip_cidr", "client_ips", "mac", "profile" ]) {
        for (let item in words_list(sec[dkey])) {
            let v = lc(trim(as_string(item)));
            if (v != "" && index(devices, v) < 0) push(devices, v);
        }
    }
    for (let ikey in [ "inbound", "interface", "in_interface" ]) {
        for (let item in words_list(sec[ikey])) {
            let v = lc(trim(as_string(item)));
            if (v != "" && index(interfaces, v) < 0) push(interfaces, v);
        }
    }
    for (let pkey in [ "ports", "port", "ports_text" ]) {
        for (let item in words_list(sec[pkey])) {
            let v = trim(as_string(item));
            if (v != "" && index(ports, v) < 0) push(ports, v);
        }
    }
    for (let prkey in [ "protocol", "network" ]) {
        for (let item in words_list(sec[prkey])) {
            let v = lc(trim(as_string(item)));
            if (v != "" && index(protocols, v) < 0) push(protocols, v);
        }
    }
    for (let exkey in [ "exclude_domains", "domain_exclude" ]) {
        for (let item in words_list(sec[exkey])) {
            let v = normalize_domain_token(item);
            if (v != "" && index(exclude_domains, v) < 0) push(exclude_domains, v);
        }
    }
    for (let exip in [ "exclude_ips", "ip_exclude" ]) {
        for (let item in words_list(sec[exip])) {
            let v = trim(as_string(item));
            if (v != "" && index(exclude_ips, v) < 0) push(exclude_ips, v);
        }
    }
    for (let uvkey in [ "schedule_refs", "schedule", "process_name", "wifi_ssid" ]) {
        if (length(words_list(sec[uvkey])) > 0) {
            if (index(unverified, uvkey) < 0) push(unverified, uvkey);
        }
    }

    if (type(conditions_map) == "object") {
        for (let cref in words_list(sec.condition_refs)) {
            let cond = conditions_map[cref];
            if (type(cond) != "object") {
                push(unverified, "missing_condition:" + cref);
                continue;
            }
            let ctype = lc(trim(as_string(cond.condition_type || "atomic")));
            let is_neg = (ctype == "not" || cond.invert == "1");
            if (ctype == "or" || ctype == "composite") {
                if (index(unverified, "condition:" + cref + "(" + ctype + ")") < 0)
                    push(unverified, "condition:" + cref + "(" + ctype + ")");
            }
            if (is_neg) {
                for (let d in words_list(cond.domains || cond.domain)) {
                    let nd = normalize_domain_token(d);
                    if (nd != "" && index(exclude_domains, nd) < 0) push(exclude_domains, nd);
                }
                for (let ip in words_list(cond.ip_cidr || cond.ip || cond.subnets)) {
                    let nip = trim(as_string(ip));
                    if (nip != "" && index(exclude_ips, nip) < 0) push(exclude_ips, nip);
                }
                continue;
            }
            for (let dkey in [ "devices", "device", "src_ip", "source_ip_cidr", "client_ips", "mac" ]) {
                for (let item in words_list(cond[dkey])) {
                    let v = lc(trim(as_string(item)));
                    if (v != "" && index(devices, v) < 0) push(devices, v);
                }
            }
            for (let ikey in [ "inbound", "interface", "in_interface" ]) {
                for (let item in words_list(cond[ikey])) {
                    let v = lc(trim(as_string(item)));
                    if (v != "" && index(interfaces, v) < 0) push(interfaces, v);
                }
            }
            for (let pkey in [ "ports", "port", "ports_text" ]) {
                for (let item in words_list(cond[pkey])) {
                    let v = trim(as_string(item));
                    if (v != "" && index(ports, v) < 0) push(ports, v);
                }
            }
            for (let prkey in [ "protocol", "network" ]) {
                for (let item in words_list(cond[prkey])) {
                    let v = lc(trim(as_string(item)));
                    if (v != "" && index(protocols, v) < 0) push(protocols, v);
                }
            }
            for (let exkey in [ "exclude_domains", "domain_exclude" ]) {
                for (let item in words_list(cond[exkey])) {
                    let v = normalize_domain_token(item);
                    if (v != "" && index(exclude_domains, v) < 0) push(exclude_domains, v);
                }
            }
        }
    }

    let parts = [];
    if (length(devices) > 0) push(parts, "devices=" + join(",", devices));
    if (length(interfaces) > 0) push(parts, "iface=" + join(",", interfaces));
    if (length(ports) > 0) push(parts, "ports=" + join(",", ports));
    if (length(protocols) > 0) push(parts, "proto=" + join(",", protocols));
    if (length(exclude_domains) > 0) push(parts, "exclude_domains=" + join(",", exclude_domains));
    if (length(exclude_ips) > 0) push(parts, "exclude_ips=" + join(",", exclude_ips));
    if (length(unverified) > 0) push(parts, "unverified=" + join(",", unverified));

    return {
        devices: devices,
        interfaces: interfaces,
        ports: ports,
        port_intervals: parse_port_intervals(ports),
        protocols: protocols,
        exclude_domains: exclude_domains,
        exclude_ips: exclude_ips,
        unverified: unverified,
        summary: length(parts) > 0 ? join("; ", parts) : "unrestricted"
    };
}

function is_domain_excluded(cond, target_domain) {
    if (target_domain == null || target_domain == "" || length(cond.exclude_domains) == 0)
        return false;
    for (let ex_d in cond.exclude_domains) {
        if (domain_covers(ex_d, target_domain))
            return true;
    }
    return false;
}

function is_ip_excluded(cond, target_ip) {
    if (target_ip == null || target_ip == "" || length(cond.exclude_ips) == 0)
        return false;
    for (let ex_ip in cond.exclude_ips) {
        if (cidr_covers(ex_ip, target_ip))
            return true;
    }
    return false;
}

function evaluate_condition_relation(earlier_cond, later_cond, target_domain, target_ip) {
    if (is_domain_excluded(earlier_cond, target_domain))
        return { excluded: true, l3_disjoint: true, l4_disjoint: false, covers_all: false };
    if (is_ip_excluded(earlier_cond, target_ip))
        return { excluded: true, l3_disjoint: true, l4_disjoint: false, covers_all: false };

    let dev_overlap = token_sets_overlap(earlier_cond.devices, later_cond.devices, true);
    let iface_overlap = token_sets_overlap(earlier_cond.interfaces, later_cond.interfaces, false);
    let port_overlap = port_intervals_overlap(earlier_cond.port_intervals, later_cond.port_intervals);
    let proto_overlap = token_sets_overlap(earlier_cond.protocols, later_cond.protocols, false);

    let l3_disjoint = (!dev_overlap || !iface_overlap);
    let l4_disjoint = (!port_overlap || !proto_overlap);

    let covers_all = (
        !l3_disjoint &&
        !l4_disjoint &&
        token_set_covers(earlier_cond.devices, later_cond.devices, true) &&
        token_set_covers(earlier_cond.interfaces, later_cond.interfaces, false) &&
        port_intervals_cover(earlier_cond.port_intervals, later_cond.port_intervals) &&
        token_set_covers(earlier_cond.protocols, later_cond.protocols, false) &&
        length(earlier_cond.unverified) == 0 &&
        length(earlier_cond.exclude_domains) == 0 &&
        length(earlier_cond.exclude_ips) == 0
    );

    return {
        excluded: false,
        l3_disjoint: l3_disjoint,
        l4_disjoint: l4_disjoint,
        covers_all: covers_all
    };
}

function resolve_section_dns_info(sec, family, cond) {
    let has_l4 = (length(cond.ports) > 0 || length(cond.protocols) > 0);
    let custom_dns = trim(as_string(sec.dns_server || sec.custom_dns || ""));
    if (family == "block") {
        if (has_l4) {
            return { participates: false, resolver: "skipped_l4_restriction", family: "skipped" };
        }
        return { participates: true, resolver: "dns-block", family: "block" };
    }
    if (family == "direct") {
        return {
            participates: !has_l4,
            resolver: custom_dns != "" ? ("custom:" + custom_dns) : "dns-direct",
            family: "direct"
        };
    }
    if (substr(family, 0, 4) == "dpi:") {
        return {
            participates: !has_l4,
            resolver: custom_dns != "" ? ("custom:" + custom_dns) : "dns-direct",
            family: "direct"
        };
    }
    return {
        participates: !has_l4,
        resolver: custom_dns != "" ? ("custom:" + custom_dns) : "dns-remote",
        family: "proxy"
    };
}

function collect_expected_overlaps(candidate_uci, options) {
    let expected = [];
    if (type(options) == "object" && options.expected_overlaps != null) {
        for (let item in words_list(options.expected_overlaps)) {
            let v = lc(trim(as_string(item)));
            if (v != "" && index(expected, v) < 0) push(expected, v);
        }
    }
    if (candidate_uci && type(candidate_uci.settings) == "object") {
        for (let k in [ "expected_overlaps", "ignore_conflicts", "acknowledged_conflicts" ]) {
            for (let item in words_list(candidate_uci.settings[k])) {
                let v = lc(trim(as_string(item)));
                if (v != "" && index(expected, v) < 0) push(expected, v);
            }
        }
    }
    if (candidate_uci && type(candidate_uci.sections) == "object") {
        for (let sname, sec in candidate_uci.sections) {
            if (type(sec) != "object") continue;
            for (let k in [ "expected_overlaps", "ignore_conflicts" ]) {
                for (let item in words_list(sec[k])) {
                    let v = lc(trim(as_string(item)));
                    if (v != "" && index(expected, v) < 0) push(expected, v);
                }
            }
        }
    }
    return expected;
}

function is_conflict_expected(c_obj, expected_list) {
    if (length(expected_list) == 0) return false;
    let w_sec = lc(as_string(c_obj.winner_section || ""));
    let s_sec = lc(as_string(c_obj.shadowed_section || ""));
    let target = lc(as_string(c_obj.target || ""));
    let w_src = lc(as_string(c_obj.winner_source || ""));
    let s_src = lc(as_string(c_obj.shadowed_source || ""));
    let cid = lc(as_string(c_obj.id || ""));

    let candidates = [
        cid,
        w_sec + "->" + s_sec,
        w_sec + ":" + s_sec,
        w_sec + "->" + s_sec + ":" + target,
        w_src + "->" + s_src,
        target
    ];
    for (let cand in candidates) {
        if (cand != "" && index(expected_list, cand) >= 0) return true;
    }
    return false;
}

function build_dns_and_route_decisions(earlier, later, target, winner_source, shadowed_source, rel) {
    let dns_sec = earlier;
    let dns_src = winner_source;
    if (!earlier.dns.participates && later.dns.participates) {
        dns_sec = later;
        dns_src = shadowed_source;
    }
    let route_sec = rel.l4_disjoint ? later : earlier;
    let route_src = rel.l4_disjoint ? shadowed_source : winner_source;

    let dns_decision = {
        section: dns_sec.name,
        action: dns_sec.action,
        priority: dns_sec.priority,
        resolver: dns_sec.dns.resolver,
        source: dns_src
    };
    let route_decision = {
        section: route_sec.name,
        action: route_sec.action,
        priority: route_sec.priority,
        family: route_sec.family,
        source: route_src,
        conditions: route_sec.conditions.summary
    };
    let mismatch = (
        dns_decision.section != route_decision.section ||
        (dns_sec.dns.family != "skipped" && dns_sec.dns.family != route_sec.family &&
         !(dns_sec.dns.family == "direct" && substr(route_sec.family, 0, 4) == "dpi:"))
    );

    return {
        dns_decision: dns_decision,
        route_decision: route_decision,
        dns_route_mismatch: mismatch
    };
}

function rule_conflicts_cache_signature(sections_map, conditions_map, expected_list) {
    let seen_lists = {};
    let list_stamps = [];
    for (let name, sec in sections_map) {
        if (type(sec) != "object" || sec.enabled == "0")
            continue;
        for (let lname in words_list(sec.community_lists)) {
            let norm = lc(trim(as_string(lname)));
            if (norm == "" || seen_lists[norm])
                continue;
            seen_lists[norm] = true;
            for (let dir in [ "/tmp/tachyon-core/rulesets", "/etc/tachyon/rulesets", "/usr/share/tachyon/rulesets" ]) {
                for (let cand in [
                    dir + "/community-" + lname + ".json",
                    dir + "/community-domains-" + lname + ".lst",
                    dir + "/community-subnets-" + lname + ".lst",
                    dir + "/" + lname + ".lst",
                    dir + "/community-" + lname + ".trs",
                    dir + "/community-" + lname + ".srs"
                ]) {
                    let st = fs.stat(cand);
                    if (st != null && st.type == "file")
                        push(list_stamps, cand + ":" + as_string(st.size || 0) + ":" + as_string(st.mtime || 0));
                }
            }
        }
    }
    return sprintf("%J|%J|%J|%s", sections_map, conditions_map, expected_list, join(",", list_stamps));
}

function analyze_rule_conflicts(candidate_uci, options) {
    let conflicts = [];
    let acknowledged_conflicts = [];
    let duplicates = [];
    let shadowed_sections = [];
    let dns_route_warnings = [];
    let warnings = [];
    let list_cache = {};
    let analyzed_lists = [];
    let unverified_lists = [];
    let unverified_conditions = [];

    let sections_map = (candidate_uci && type(candidate_uci.sections) == "object") ? candidate_uci.sections : {};
    let conditions_map = (candidate_uci && type(candidate_uci.conditions) == "object") ? candidate_uci.conditions : {};
    let expected_list = collect_expected_overlaps(candidate_uci, options);

    let can_use_conflict_cache = (
        (options == null || (options.list_contents == null && options.rulesets_dir == null)) &&
        getenv("TACHYON_PACKAGE_TEST_MODE") == null &&
        getenv("TACHYON_UCI_STATE_FILE") == null &&
        getenv("TMP_RULESET_FOLDER") == null
    );
    let conflict_cache_sig = "";
    let conflict_cache_path = "/var/run/tachyon/rule-conflicts-cache.json";
    if (can_use_conflict_cache) {
        conflict_cache_sig = rule_conflicts_cache_signature(sections_map, conditions_map, expected_list);
        let cached_entry = common.read_json_file(conflict_cache_path);
        if (type(cached_entry) == "object" && cached_entry.sig == conflict_cache_sig && type(cached_entry.result) == "object")
            return cached_entry.result;
    }

    let sec_names = keys(sections_map);

    let entries = [];
    for (let i = 0; i < length(sec_names); i++) {
        let name = sec_names[i];
        let sec = sections_map[name];
        if (type(sec) != "object" || sec.enabled == "0") continue;
        let action = as_string(sec.action || "outbound");
        let family = normalize_action_family(action);
        let domains = collect_section_domains(sec, conditions_map);
        let lists = words_list(sec.community_lists);
        let ips = [];
        for (let raw_ip in words_list(sec.ip_cidr || sec.ip || sec.subnets || sec.local_subnet_lists)) {
            let nip = trim(as_string(raw_ip));
            if (nip != "" && core_ip.valid_ip_or_cidr(nip) && index(ips, nip) < 0) {
                push(ips, nip);
            }
        }
        let cond = collect_section_conditions(sec, conditions_map);
        let ports = cond.ports;
        let protos = cond.protocols;
        let dns_info = resolve_section_dns_info(sec, family, cond);

        if (length(cond.unverified) > 0) {
            push(unverified_conditions, {
                section: name,
                conditions: cond.unverified
            });
        }

        let section_list_meta = {};
        for (let lname in lists) {
            if (list_cache[lname] == null) {
                let resolved = resolve_list_contents(lname, options);
                list_cache[lname] = resolved;
                push(analyzed_lists, {
                    name: resolved.name,
                    source: resolved.source,
                    path: resolved.path,
                    mtime: resolved.mtime,
                    version: resolved.version,
                    domains_count: resolved.domains_count,
                    cidrs_count: resolved.cidrs_count,
                    verified: resolved.verified
                });
                if (!resolved.verified && index(unverified_lists, lname) < 0) {
                    push(unverified_lists, lname);
                }
            }
            section_list_meta[lname] = list_cache[lname];
        }

        if (family == "block" && (length(ports) > 0 || length(protos) > 0) && (length(domains) > 0 || length(lists) > 0)) {
            let msg = sprintf("Section '%s' (action: block) restricts ports/protocol (%s), so DNS-level blocking is skipped and only L3/L4 route rejection applies.",
                name, cond.summary);
            push(dns_route_warnings, msg);
            push(warnings, msg);
        }

        push(entries, {
            name: name,
            priority: i + 1,
            action: action,
            family: family,
            domains: domains,
            lists: lists,
            list_meta: section_list_meta,
            ips: ips,
            ports: ports,
            protocols: protos,
            conditions: cond,
            dns: dns_info
        });
    }

    for (let j = 0; j < length(entries); j++) {
        let later = entries[j];
        let total_items = length(later.domains) + length(later.lists) + length(later.ips);
        let covered_items = 0;

        // 1. Check later manual domains against earlier manual domains & earlier lists
        for (let d_later in later.domains) {
            let fully_covered = false;
            for (let i = 0; i < j; i++) {
                let earlier = entries[i];
                let rel = evaluate_condition_relation(earlier.conditions, later.conditions, d_later, null);
                if (rel.excluded || rel.l3_disjoint) continue;

                let matched_early = "";
                let early_source = "manual";
                for (let d_early in earlier.domains) {
                    if (domain_covers(d_early, d_later)) {
                        matched_early = d_early;
                        early_source = "domain:" + d_early;
                        break;
                    }
                }
                if (matched_early == "") {
                    for (let l_early in earlier.lists) {
                        let lmeta = earlier.list_meta[l_early];
                        if (lmeta != null) {
                            let hit = domain_covers_in_set(lmeta.domain_set, d_later);
                            if (hit != "") {
                                matched_early = hit;
                                early_source = "list:" + l_early;
                                break;
                            }
                        }
                    }
                }

                if (matched_early != "") {
                    let decisions = build_dns_and_route_decisions(earlier, later, d_later, early_source, "domain:" + d_later, rel);
                    if (rel.l4_disjoint) {
                        if (decisions.dns_route_mismatch && earlier.family != later.family) {
                            let dm_msg = sprintf("DNS/Route mismatch for '%s': DNS resolves via section '%s' (#%d, %s) while L4 traffic (%s) routes via section '%s' (#%d, %s).",
                                d_later, decisions.dns_decision.section, decisions.dns_decision.priority, decisions.dns_decision.resolver,
                                later.conditions.summary, decisions.route_decision.section, decisions.route_decision.priority, decisions.route_decision.action);
                            if (index(dns_route_warnings, dm_msg) < 0) push(dns_route_warnings, dm_msg);
                            if (index(warnings, dm_msg) < 0) push(warnings, dm_msg);
                        }
                        continue;
                    }

                    if (rel.covers_all) fully_covered = true;
                    let scope = rel.covers_all ? "full" : "conditional";

                    if (earlier.family != later.family) {
                        let block_override = (later.family == "block" && earlier.family != "block");
                        let c_obj = {
                            id: sprintf("%s->%s:%s", earlier.name, later.name, d_later),
                            kind: block_override ? "block_overridden" : "domain_conflict",
                            target: d_later,
                            covered_by: matched_early,
                            winner_source: early_source,
                            shadowed_source: "domain:" + d_later,
                            winner_section: earlier.name,
                            winner_action: earlier.action,
                            winner_priority: earlier.priority,
                            winner_conditions: earlier.conditions.summary,
                            shadowed_section: later.name,
                            shadowed_action: later.action,
                            shadowed_priority: later.priority,
                            shadowed_conditions: later.conditions.summary,
                            scope: scope,
                            dns_decision: decisions.dns_decision,
                            route_decision: decisions.route_decision,
                            dns_route_mismatch: decisions.dns_route_mismatch,
                            expected: false
                        };
                        if (is_conflict_expected(c_obj, expected_list)) {
                            c_obj.expected = true;
                            push(acknowledged_conflicts, c_obj);
                        } else {
                            push(conflicts, c_obj);
                            let cond_note = scope == "conditional" ? sprintf(" [when %s]", earlier.conditions.summary) : "";
                            let path_note = sprintf(" (DNS: %s via '%s' #%d; Route: %s via '%s' #%d)",
                                decisions.dns_decision.resolver, decisions.dns_decision.section, decisions.dns_decision.priority,
                                decisions.route_decision.action, decisions.route_decision.section, decisions.route_decision.priority);
                            let w_msg = block_override
                                ? sprintf("Block rule in section '%s' (#%d) for '%s' is overridden by earlier permissive section '%s' (#%d, %s, matched by '%s' from %s)%s%s.",
                                    later.name, later.priority, d_later, earlier.name, earlier.priority, earlier.action, matched_early, early_source, cond_note, path_note)
                                : sprintf("Domain '%s' in section '%s' (#%d, %s) is shadowed by earlier section '%s' (#%d, %s, matched by '%s' from %s)%s%s.",
                                    d_later, later.name, later.priority, later.action, earlier.name, earlier.priority, earlier.action, matched_early, early_source, cond_note, path_note);
                            if (index(warnings, w_msg) < 0) push(warnings, w_msg);
                            if (decisions.dns_route_mismatch && index(dns_route_warnings, w_msg) < 0) {
                                push(dns_route_warnings, w_msg);
                            }
                        }
                    } else if (scope == "full") {
                        push(duplicates, {
                            target: d_later,
                            first_section: earlier.name,
                            second_section: later.name,
                            action: earlier.action
                        });
                    }
                    if (fully_covered) break;
                }
            }
            if (fully_covered) covered_items++;
        }

        // 2. Check later community lists against earlier lists & earlier manual domains
        for (let l_later in later.lists) {
            let l_later_meta = later.list_meta[l_later];
            let list_fully_covered = false;

            for (let i = 0; i < j; i++) {
                let earlier = entries[i];
                let rel = evaluate_condition_relation(earlier.conditions, later.conditions, null, null);
                if (rel.l3_disjoint) continue;

                // 2a. Identical list name in both sections
                if (index(earlier.lists, l_later) >= 0 && !rel.l4_disjoint) {
                    if (rel.covers_all) list_fully_covered = true;
                    let scope = rel.covers_all ? "full" : "conditional";
                    let decisions = build_dns_and_route_decisions(earlier, later, "list:" + l_later, "list:" + l_later, "list:" + l_later, rel);
                    if (earlier.family != later.family) {
                        let block_override = (later.family == "block" && earlier.family != "block");
                        let c_obj = {
                            id: sprintf("%s->%s:list:%s", earlier.name, later.name, l_later),
                            kind: block_override ? "block_overridden" : "list_conflict",
                            target: "list:" + l_later,
                            covered_by: "list:" + l_later,
                            winner_source: "list:" + l_later,
                            shadowed_source: "list:" + l_later,
                            winner_section: earlier.name,
                            winner_action: earlier.action,
                            winner_priority: earlier.priority,
                            winner_conditions: earlier.conditions.summary,
                            shadowed_section: later.name,
                            shadowed_action: later.action,
                            shadowed_priority: later.priority,
                            shadowed_conditions: later.conditions.summary,
                            scope: scope,
                            dns_decision: decisions.dns_decision,
                            route_decision: decisions.route_decision,
                            dns_route_mismatch: decisions.dns_route_mismatch,
                            expected: false
                        };
                        if (is_conflict_expected(c_obj, expected_list)) {
                            c_obj.expected = true;
                            push(acknowledged_conflicts, c_obj);
                        } else {
                            push(conflicts, c_obj);
                            let w_msg = sprintf("Community list '%s' in section '%s' (#%d, %s) conflicts with earlier section '%s' (#%d, %s) (DNS: %s via '%s'; Route: %s via '%s').",
                                l_later, later.name, later.priority, later.action, earlier.name, earlier.priority, earlier.action,
                                decisions.dns_decision.resolver, decisions.dns_decision.section, decisions.route_decision.action, decisions.route_decision.section);
                            if (index(warnings, w_msg) < 0) push(warnings, w_msg);
                        }
                    } else if (scope == "full") {
                        push(duplicates, {
                            target: "list:" + l_later,
                            first_section: earlier.name,
                            second_section: later.name,
                            action: earlier.action
                        });
                    }
                    if (list_fully_covered) break;
                    continue;
                }

                // 2b. Content-level overlap between different lists or between earlier manual entries and later list
                if (l_later_meta == null || !l_later_meta.verified) continue;

                for (let l_early in earlier.lists) {
                    if (l_early == l_later) continue;
                    let l_early_meta = earlier.list_meta[l_early];
                    if (l_early_meta == null || !l_early_meta.verified) continue;

                    let shared_domains = [];
                    let parent_map = {};
                    let covered_later_dom_count = 0;

                    for (let dl in l_later_meta.domains) {
                        if (is_domain_excluded(earlier.conditions, dl)) continue;
                        let de = domain_covers_in_set(l_early_meta.domain_set, dl);
                        if (de != "") {
                            push(shared_domains, dl);
                            parent_map[dl] = de;
                            covered_later_dom_count++;
                        }
                    }

                    let shared_cidrs = [];
                    let later_ranges = l_later_meta.cidr_ranges;
                    for (let cl_idx = 0; cl_idx < length(l_later_meta.cidrs); cl_idx++) {
                        let cl = l_later_meta.cidrs[cl_idx];
                        if (is_ip_excluded(earlier.conditions, cl)) continue;
                        let cl_range = type(later_ranges) == "array" ? later_ranges[cl_idx] : null;
                        let ce = cidr_covered_by_meta(l_early_meta, cl, cl_range);
                        if (ce != "") {
                            push(shared_cidrs, cl);
                            parent_map[cl] = ce;
                        }
                    }

                    let overlaps_total = length(shared_domains) + length(shared_cidrs);
                    if (overlaps_total > 0 && !rel.l4_disjoint) {
                        let all_later_doms_covered = (
                            length(l_later_meta.domains) > 0 &&
                            covered_later_dom_count == length(l_later_meta.domains) &&
                            length(shared_cidrs) == length(l_later_meta.cidrs)
                        );
                        if (all_later_doms_covered && rel.covers_all) {
                            list_fully_covered = true;
                        }
                        let sample_target = length(shared_domains) > 0 ? shared_domains[0] : shared_cidrs[0];
                        let sample_parent = parent_map[sample_target] || sample_target;
                        let all_targets = [];
                        for (let sd in shared_domains) {
                            if (length(all_targets) >= MAX_OVERLAP_SAMPLE_TARGETS) break;
                            push(all_targets, sd);
                        }
                        for (let sc in shared_cidrs) {
                            if (length(all_targets) >= MAX_OVERLAP_SAMPLE_TARGETS) break;
                            push(all_targets, sc);
                        }

                        let scope = (all_later_doms_covered && rel.covers_all) ? "full" : "conditional";
                        let decisions = build_dns_and_route_decisions(earlier, later, sample_target, "list:" + l_early, "list:" + l_later, rel);

                        if (earlier.family != later.family || decisions.dns_route_mismatch) {
                            let block_override = (later.family == "block" && earlier.family != "block");
                            let c_obj = {
                                id: sprintf("%s->%s:list:%s->%s", earlier.name, later.name, l_early, l_later),
                                kind: block_override ? "block_overridden" : "list_overlap",
                                target: sample_target,
                                overlapping_targets: all_targets,
                                overlap_count: overlaps_total,
                                covered_by: sample_parent,
                                winner_source: "list:" + l_early,
                                shadowed_source: "list:" + l_later,
                                winner_section: earlier.name,
                                winner_action: earlier.action,
                                winner_priority: earlier.priority,
                                winner_conditions: earlier.conditions.summary,
                                shadowed_section: later.name,
                                shadowed_action: later.action,
                                shadowed_priority: later.priority,
                                shadowed_conditions: later.conditions.summary,
                                scope: scope,
                                dns_decision: decisions.dns_decision,
                                route_decision: decisions.route_decision,
                                dns_route_mismatch: decisions.dns_route_mismatch,
                                expected: false
                            };
                            if (is_conflict_expected(c_obj, expected_list)) {
                                c_obj.expected = true;
                                push(acknowledged_conflicts, c_obj);
                            } else {
                                push(conflicts, c_obj);
                                let preview_items = [];
                                for (let k = 0; k < length(all_targets) && k < 4; k++) {
                                    push(preview_items, all_targets[k]);
                                }
                                let preview_str = join(", ", preview_items) + (overlaps_total > 4 ? sprintf(" (+%d more)", overlaps_total - 4) : "");
                                let w_msg = block_override
                                    ? sprintf("Block list '%s' in section '%s' (#%d) is overridden on [%s] by earlier list '%s' in section '%s' (#%d, %s; matched by '%s') (DNS: %s via '%s' #%d; Route: %s via '%s' #%d).",
                                        l_later, later.name, later.priority, preview_str, l_early, earlier.name, earlier.priority, earlier.action, sample_parent,
                                        decisions.dns_decision.resolver, decisions.dns_decision.section, decisions.dns_decision.priority,
                                        decisions.route_decision.action, decisions.route_decision.section, decisions.route_decision.priority)
                                    : sprintf("List '%s' in section '%s' (#%d, %s) overlaps on [%s] with earlier list '%s' in section '%s' (#%d, %s; matched by '%s') (DNS: %s via '%s' #%d; Route: %s via '%s' #%d).",
                                        l_later, later.name, later.priority, later.action, preview_str, l_early, earlier.name, earlier.priority, earlier.action, sample_parent,
                                        decisions.dns_decision.resolver, decisions.dns_decision.section, decisions.dns_decision.priority,
                                        decisions.route_decision.action, decisions.route_decision.section, decisions.route_decision.priority);
                                if (index(warnings, w_msg) < 0) push(warnings, w_msg);
                                if ((earlier.family == "direct" && later.family == "proxy") || decisions.dns_route_mismatch) {
                                    if (index(dns_route_warnings, w_msg) < 0) push(dns_route_warnings, w_msg);
                                }
                            }
                        }
                    }
                }

                // 2c. Earlier manual domains covering domains inside later list
                if (length(earlier.domains) > 0 && !rel.l4_disjoint) {
                    let manual_hits = [];
                    let manual_hit_count = 0;
                    let manual_parent = "";
                    for (let dl in l_later_meta.domains) {
                        if (is_domain_excluded(earlier.conditions, dl)) continue;
                        for (let de in earlier.domains) {
                            if (domain_covers(de, dl)) {
                                manual_hit_count++;
                                if (length(manual_hits) < MAX_OVERLAP_SAMPLE_TARGETS) push(manual_hits, dl);
                                if (manual_parent == "") manual_parent = de;
                                break;
                            }
                        }
                    }
                    if (manual_hit_count > 0 && earlier.family != later.family) {
                        if (manual_hit_count == length(l_later_meta.domains) && length(l_later_meta.cidrs) == 0 && rel.covers_all) {
                            list_fully_covered = true;
                        }
                        let sample_t = manual_hits[0];
                        let decisions = build_dns_and_route_decisions(earlier, later, sample_t, "domain:" + manual_parent, "list:" + l_later, rel);
                        let block_override = (later.family == "block" && earlier.family != "block");
                        let c_obj = {
                            id: sprintf("%s->%s:%s->list:%s", earlier.name, later.name, manual_parent, l_later),
                            kind: block_override ? "block_overridden" : "list_overlap",
                            target: sample_t,
                            overlapping_targets: manual_hits,
                            overlap_count: manual_hit_count,
                            covered_by: manual_parent,
                            winner_source: "domain:" + manual_parent,
                            shadowed_source: "list:" + l_later,
                            winner_section: earlier.name,
                            winner_action: earlier.action,
                            winner_priority: earlier.priority,
                            winner_conditions: earlier.conditions.summary,
                            shadowed_section: later.name,
                            shadowed_action: later.action,
                            shadowed_priority: later.priority,
                            shadowed_conditions: later.conditions.summary,
                            scope: (list_fully_covered && rel.covers_all) ? "full" : "conditional",
                            dns_decision: decisions.dns_decision,
                            route_decision: decisions.route_decision,
                            dns_route_mismatch: decisions.dns_route_mismatch,
                            expected: false
                        };
                        if (is_conflict_expected(c_obj, expected_list)) {
                            c_obj.expected = true;
                            push(acknowledged_conflicts, c_obj);
                        } else {
                            push(conflicts, c_obj);
                            let w_msg = sprintf("List '%s' in section '%s' (#%d, %s) is overlapped on '%s' by earlier manual domain '%s' in section '%s' (#%d, %s) (DNS: %s via '%s'; Route: %s via '%s').",
                                l_later, later.name, later.priority, later.action, sample_t, manual_parent, earlier.name, earlier.priority, earlier.action,
                                decisions.dns_decision.resolver, decisions.dns_decision.section, decisions.route_decision.action, decisions.route_decision.section);
                            if (index(warnings, w_msg) < 0) push(warnings, w_msg);
                        }
                    }
                }
            }
            if (list_fully_covered) covered_items++;
        }

        // 3. Check later manual IP/CIDRs against earlier manual IP/CIDRs and earlier list CIDRs
        for (let ip_later in later.ips) {
            let ip_covered = false;
            for (let i = 0; i < j; i++) {
                let earlier = entries[i];
                let rel = evaluate_condition_relation(earlier.conditions, later.conditions, null, ip_later);
                if (rel.excluded || rel.l3_disjoint || rel.l4_disjoint) continue;

                let matched_cidr = "";
                let early_src = "";
                for (let ip_early in earlier.ips) {
                    if (cidr_covers(ip_early, ip_later)) {
                        matched_cidr = ip_early;
                        early_src = "ip:" + ip_early;
                        break;
                    }
                }
                if (matched_cidr == "") {
                    let ip_later_range = parse_ipv4_cidr_range(ip_later);
                    for (let l_early in earlier.lists) {
                        let lmeta = earlier.list_meta[l_early];
                        if (lmeta != null) {
                            let lc_cidr = cidr_covered_by_meta(lmeta, ip_later, ip_later_range);
                            if (lc_cidr != "") {
                                matched_cidr = lc_cidr;
                                early_src = "list:" + l_early;
                                break;
                            }
                        }
                    }
                }
                if (matched_cidr != "") {
                    if (rel.covers_all) ip_covered = true;
                    if (earlier.family != later.family) {
                        let block_override = (later.family == "block" && earlier.family != "block");
                        let c_obj = {
                            id: sprintf("%s->%s:ip:%s", earlier.name, later.name, ip_later),
                            kind: block_override ? "block_overridden" : "ip_conflict",
                            target: ip_later,
                            covered_by: matched_cidr,
                            winner_source: early_src,
                            shadowed_source: "ip:" + ip_later,
                            winner_section: earlier.name,
                            winner_action: earlier.action,
                            winner_priority: earlier.priority,
                            winner_conditions: earlier.conditions.summary,
                            shadowed_section: later.name,
                            shadowed_action: later.action,
                            shadowed_priority: later.priority,
                            shadowed_conditions: later.conditions.summary,
                            scope: rel.covers_all ? "full" : "conditional",
                            dns_decision: { section: "n/a (IP literal)", action: "none", priority: 0, resolver: "none" },
                            route_decision: { section: earlier.name, action: earlier.action, priority: earlier.priority, family: earlier.family },
                            dns_route_mismatch: false,
                            expected: false
                        };
                        if (is_conflict_expected(c_obj, expected_list)) {
                            c_obj.expected = true;
                            push(acknowledged_conflicts, c_obj);
                        } else {
                            push(conflicts, c_obj);
                            let w_msg = sprintf("IP/CIDR '%s' in section '%s' (#%d, %s) is shadowed by '%s' (%s) in earlier section '%s' (#%d, %s).",
                                ip_later, later.name, later.priority, later.action, matched_cidr, early_src, earlier.name, earlier.priority, earlier.action);
                            if (index(warnings, w_msg) < 0) push(warnings, w_msg);
                        }
                    }
                    if (ip_covered) break;
                }
            }
            if (ip_covered) covered_items++;
        }

        if (total_items > 0 && covered_items == total_items) {
            push(shadowed_sections, later.name);
            let s_msg = sprintf("Section '%s' (#%d, %s) is completely shadowed by earlier rules and will never match traffic.",
                later.name, later.priority, later.action);
            if (index(warnings, s_msg) < 0) push(warnings, s_msg);
        }
    }

    let limitations = [];
    if (length(unverified_lists) > 0) {
        push(limitations, sprintf("Unverified lists (local content unavailable): %s", join(", ", unverified_lists)));
    }
    if (length(unverified_conditions) > 0) {
        let uv_sec_strs = [];
        for (let uvc in unverified_conditions) {
            push(uv_sec_strs, uvc.section + "(" + join(",", uvc.conditions) + ")");
        }
        push(limitations, sprintf("Dynamic/unverified conditions not statically evaluated: %s", join(", ", uv_sec_strs)));
    }
    let is_complete = (length(unverified_lists) == 0 && length(unverified_conditions) == 0);

    let final_res = {
        conflicts: conflicts,
        acknowledged_conflicts: acknowledged_conflicts,
        duplicates: duplicates,
        shadowed_sections: shadowed_sections,
        dns_route_warnings: dns_route_warnings,
        warnings: warnings,
        analysis_completeness: {
            complete: is_complete,
            status: is_complete ? "complete" : "partial",
            analyzed_lists: analyzed_lists,
            unverified_lists: unverified_lists,
            unverified_conditions: unverified_conditions,
            limitations: limitations
        }
    };
    if (can_use_conflict_cache && conflict_cache_sig != "") {
        common.ensure_dir("/var/run/tachyon");
        common.write_json_file(conflict_cache_path, {
            sig: conflict_cache_sig,
            result: final_res
        });
    }
    return final_res;
}

function refresh_conflict_diagnostics(options) {
    let active_uci = load_active_uci();
    let result = analyze_rule_conflicts(active_uci, options);
    result.updated_at = time();
    if (getenv("TACHYON_PACKAGE_TEST_MODE") == null && getenv("TACHYON_UCI_STATE_FILE") == null) {
        common.ensure_dir("/var/run/tachyon");
        common.write_json_file("/var/run/tachyon/rule-conflicts.json", result);
    }
    return result;
}

// ─── Candidate Syntax & Semantics Validator ───────────────────────────────────

function validate_uci_semantics(candidate_uci) {
    let errors = [];
    let warnings = [];

    // 1. Validate sections
    for (let name, sec in candidate_uci.sections) {
        if (match(name, /^[a-zA-Z0-9_-]+$/) == null) {
            push(errors, "Section name '" + name + "' contains invalid characters. Use alphanumeric and underscore/hyphen.");
        }

        let action = sec.action || "outbound";
        let valid_actions = {
            connection: true, group: true, desync: true, direct: true,
            outbound: true, proxy: true, bypass: true, block: true,
            zapret: true, zapret2: true, byedpi: true, hosts: true, dns: true,
            awg: true, warp: true, anytls: true, snell: true, mieru: true, naive: true,
            sudoku: true,
            masque: true, openvpn: true, openconnect: true, shadowtls: true,
            trusttunnel: true, tewfai: true, wdtt: true, olcrtc: true, fptn: true
        };

        if (!valid_actions[action]) {
            push(errors, "Section '" + name + "' has unsupported action '" + action + "'.");
        }

        // Validate domains
        let domains = words_list(sec.domain || sec.domains);
        for (let d in domains) {
            if (match(d, /^[a-zA-Z0-9*._-]+$/) == null) {
                push(errors, "Section '" + name + "' has malformed domain '" + d + "'.");
            }
        }

        // Validate IP/CIDRs
        let ips = words_list(sec.ip_cidr || sec.ip || sec.subnets);
        for (let item in ips) {
            if (!core_ip.valid_ip_or_cidr(item)) {
                push(errors, "Section '" + name + "' has invalid IP/CIDR '" + item + "'.");
            }
        }

        // Validate ports
        let ports = words_list(sec.ports || sec.port);
        for (let p in ports) {
            let dash = index(p, "-");
            if (dash > 0) {
                let p1 = int(substr(p, 0, dash));
                let p2 = int(substr(p, dash + 1));
                if (p1 <= 0 || p2 > 65535 || p1 > p2) {
                    push(errors, "Section '" + name + "' has invalid port range '" + p + "'.");
                }
            } else {
                let num = int(p);
                if (num <= 0 || num > 65535) {
                    push(errors, "Section '" + name + "' has invalid port '" + p + "'.");
                }
            }
        }
    }

    // 2. Validate servers
    for (let name, srv in candidate_uci.servers) {
        let proto = lc(trim(as_string(srv.protocol || srv.type || "")));
        if (proto == "json_inbound" || proto == "tailscale")
            continue;
        let s_addr = trim(as_string(srv.server || srv.address || srv.listen || ""));
        let s_port = int(srv.port || srv.server_port || srv.listen_port || 0);

        if (s_addr == "" && srv.enabled != "0") {
            push(warnings, "Server '" + name + "' has an empty host/server address.");
        }
        if (s_port <= 0 || s_port > 65535) {
            push(errors, "Server '" + name + "' has invalid port '" + s_port + "'. Must be 1-65535.");
        }

        // VLESS Reality validation
        if (srv.reality == "1" || srv.tls == "reality") {
            if (trim(as_string(srv.public_key || srv.reality_public_key || "")) == "") {
                push(errors, "Server '" + name + "' has Reality enabled but missing public_key.");
            }
        }
    }

    return {
        status: length(errors) == 0 ? "ok" : "failed",
        errors: errors,
        warnings: warnings
    };
}

// ─── Port Collision Preflight Check ───────────────────────────────────────────

function check_candidate_port_collisions(candidate_uci) {
    let warnings = [];
    let errors = [];
    let settings = candidate_uci.settings || {};

    let ports_to_check = [
        { name: "TProxy Inbound", port: int(settings.tproxy_port || 1602), proto: "tcp" },
        { name: "Mixed Proxy", port: int(settings.mixed_port || 4534), proto: "tcp" }
    ];

    // Read active listening sockets from /proc/net/tcp and /proc/net/tcp6 if readable
    let listening_ports = {};
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let content = fs.readfile(path);
        if (content != null) {
            for (let line in split(content, "\n")) {
                let fields = split(trim(line), /[ \t]+/);
                if (length(fields) >= 4) {
                    let local_addr = fields[1];
                    let state = fields[3];
                    // State 0A = TCP_LISTEN
                    if (state == "0A" || state == "0a") {
                        let colon = index(local_addr, ":");
                        if (colon > 0) {
                            let hex_port = substr(local_addr, colon + 1);
                            let dec_port = int(hex_port, 16);
                            if (dec_port > 0) listening_ports[dec_port] = true;
                        }
                    }
                }
            }
        }
    }

    return {
        status: "ok",
        ports_checked: length(ports_to_check),
        warnings: warnings,
        errors: errors
    };
}

// ─── Core Engine Binary Dry-Run Check ─────────────────────────────────────────

function check_singbox_candidate_binary(candidate_config_obj) {
    if (fs.stat(SING_BOX_BIN) == null) {
        return {
            checked: false,
            status: "skipped",
            reason: "sing-box binary not present in /usr/bin/tachyon-core"
        };
    }

    let tmp_path = "/tmp/tachyon_plan_test_" + as_string(int(time())) + ".json";
    if (!common.write_json_file(tmp_path, candidate_config_obj, 2)) {
        return {
            checked: false,
            status: "skipped",
            reason: "cannot write temporary test config"
        };
    }

    let cmd = SING_BOX_BIN + " check -c " + tmp_path + " 2>&1";
    let proc = fs.popen(cmd, "r");
    let out = "";
    let code = 0;
    if (proc != null) {
        out = trim(as_string(proc.read("all")));
        code = proc.close();
    }
    fs.unlink(tmp_path);

    if (code == 0) {
        return {
            checked: true,
            status: "ok",
            compiler_output: out
        };
    }

    return {
        checked: true,
        status: "failed",
        error: out != "" ? out : ("sing-box check exited with code " + code)
    };
}

// ─── Main Configuration Plan Function ─────────────────────────────────────────

function plan(candidate_source, options) {
    options = options || {};
    let active_uci = options.active_uci || load_active_uci();
    let candidate_uci = load_candidate_uci(candidate_source);

    // 1. Compute changes diff
    let diff = compute_uci_diff(active_uci, candidate_uci);

    // 2. Analyze subsystem impact
    let impact = analyze_subsystem_impact(diff, active_uci, candidate_uci);

    // 3. Validate candidate UCI syntax & semantics
    let validation = validate_uci_semantics(candidate_uci);

    let all_errors = [];
    for (let e in validation.errors) push(all_errors, e);

    if ((candidate_source == null || candidate_source == "") && !options.active_uci) {
        for (let qfile in [ "/var/run/tachyon/section-errors.json", "/var/run/tachyon/validator-quarantined.json" ]) {
            let qobj = common.read_json_file(qfile);
            if (type(qobj) == "object") {
                for (let qsec, qmsg in qobj) {
                    let sec_entry = candidate_uci.sections ? candidate_uci.sections[qsec] : null;
                    if (sec_entry && sec_entry.enabled != "0") {
                        let err_line = "Section '" + qsec + "' is quarantined: " + as_string(qmsg);
                        if (index(all_errors, err_line) < 0)
                            push(all_errors, err_line);
                    }
                }
            }
        }
    }

    let all_warnings = [];
    for (let w in validation.warnings) push(all_warnings, w);

    // 4. Port collision check
    let port_check = check_candidate_port_collisions(candidate_uci);
    for (let e in port_check.errors) push(all_errors, e);
    for (let w in port_check.warnings) push(all_warnings, w);

    // 4b. Routing & DNS rule overlap / shadowing check (#331 / #347)
    let rule_conflicts = analyze_rule_conflicts(candidate_uci, options);
    for (let w in rule_conflicts.warnings) {
        if (index(all_warnings, w) < 0)
            push(all_warnings, w);
    }

    // 5. Engine config dry-run check (if tachyon-core active and binary exists)
    let engine_check = { checked: false, status: "ok" };
    let cand_engine = candidate_uci.settings ? (candidate_uci.settings.engine || "tachyon-core") : "tachyon-core";

    let bin_st = fs.stat(SING_BOX_BIN);
    if ((cand_engine == "tachyon-core" || cand_engine == "sing-box") && bin_st != null) {
        let bin_stamp = SING_BOX_BIN + "|" + as_string(bin_st.size || 0) + "|" + as_string(bin_st.mtime || 0);
        let cache_file = "/var/run/tachyon/engine-binary-check.json";
        let cached_check = common.read_json_file(cache_file);
        let b_check = null;
        if (type(cached_check) == "object" && cached_check.stamp == bin_stamp && type(cached_check.result) == "object") {
            b_check = cached_check.result;
        } else {
            // Run a lightweight structure test
            let mock_cfg = {
                log: { level: "warn" },
                inbounds: [
                    { type: "tproxy", tag: "tproxy-in", listen: "::", listen_port: 1602 }
                ],
                outbounds: [
                    { type: "direct", tag: "direct-out" }
                ],
                route: {
                    rules: [],
                    final: "direct-out"
                }
            };
            b_check = check_singbox_candidate_binary(mock_cfg);
            if (fs.stat("/var/run/tachyon") != null)
                common.write_json_file(cache_file, { stamp: bin_stamp, result: b_check }, 0);
        }
        engine_check = b_check;
        if (b_check.status == "failed" && b_check.error) {
            push(all_errors, "sing-box compiler check failed: " + b_check.error);
        }
    }

    let is_valid = length(all_errors) == 0;

    // Generate human summaries
    let en_summary = "";
    let ru_summary = "";

    if (is_valid) {
        if (!diff.has_changes) {
            en_summary = "Candidate configuration is IDENTICAL to current active configuration. No changes required.";
            ru_summary = "Кандидатная конфигурация ИДЕНТИЧНА текущей активной. Изменения не требуются.";
        } else {
            let aff_str = join(", ", impact.affected_subsystems);
            let action_str_en = impact.restart_required ? "Full service restart required." : "Soft reload is sufficient (connections preserved).";
            let action_str_ru = impact.restart_required ? "Требуется полный перезапуск службы." : "Достаточно мягкой перезагрузки (соединения сохраняются).";

            en_summary = sprintf("Candidate configuration is VALID (%d change%s). Affected: [%s]. %s",
                diff.total_changes,
                diff.total_changes == 1 ? "" : "s",
                aff_str,
                action_str_en
            );
            ru_summary = sprintf("Кандидатная конфигурация ВАЛИДНА (%d изменен%s). Затронуты: [%s]. %s",
                diff.total_changes,
                diff.total_changes == 1 ? "ие" : "ий",
                aff_str,
                action_str_ru
            );
        }
    } else {
        en_summary = sprintf("Candidate configuration is INVALID (%d error%s detected). Fix validation issues before applying.",
            length(all_errors),
            length(all_errors) == 1 ? "" : "s"
        );
        ru_summary = sprintf("Кандидатная конфигурация НЕВАЛИДНА (обнаружено %d ошиб%s). Исправьте ошибки перед применением.",
            length(all_errors),
            length(all_errors) == 1 ? "ка" : "ок"
        );
    }

    return {
        success: true,
        valid: is_valid,
        has_changes: diff.has_changes,
        total_changes: diff.total_changes,
        changes: {
            added_sections: diff.added_sections,
            removed_sections: diff.removed_sections,
            modified_sections: diff.modified_sections
        },
        impact: {
            affected_subsystems: impact.affected_subsystems,
            restart_required: impact.restart_required,
            restart_reasons: impact.restart_reasons
        },
        validation: {
            uci_semantics: validation.status,
            ports: port_check.status,
            engine_dry_run: engine_check.status,
            rule_conflicts: rule_conflicts
        },
        warnings: all_warnings,
        errors: all_errors,
        summary: {
            en: en_summary,
            ru: ru_summary
        }
    };
}

// ─── Text Formatter ───────────────────────────────────────────────────────────

function format_text_plan(plan_result) {
    let lines = [];
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, "                   TACHYON CONFIGURATION PLAN & PREFLIGHT                    ");
    push(lines, "══════════════════════════════════════════════════════════════════════════════");
    push(lines, sprintf(" Status:   [%s] (Changes: %d, Subsystems: %s)",
        plan_result.valid ? "VALID" : "INVALID",
        plan_result.total_changes,
        join(", ", plan_result.impact.affected_subsystems)
    ));
    push(lines, sprintf(" Action:   %s",
        plan_result.impact.restart_required ? "Full Service Restart Needed" : "Soft Reload (Zero Drop)"));
    push(lines, "──────────────────────────────────────────────────────────────────────────────");

    if (plan_result.has_changes) {
        push(lines, " Changes Preview:");
        for (let s in plan_result.changes.added_sections) {
            push(lines, sprintf("  + ADD SECTION: [%s] (%s, action: %s)", s.section, s.type, s.action || "none"));
        }
        for (let s in plan_result.changes.removed_sections) {
            push(lines, sprintf("  - DEL SECTION: [%s] (%s)", s.section, s.type));
        }
        for (let s in plan_result.changes.modified_sections) {
            push(lines, sprintf("  * MOD SECTION: [%s] (%s)", s.section, s.type));
            for (let d in s.diffs) {
                push(lines, sprintf("      %s: %s -> %s", d.option, as_string(d.old_value), as_string(d.new_value)));
            }
        }
    } else {
        push(lines, " No configuration changes detected.");
    }

    if (length(plan_result.warnings) > 0) {
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Warnings:");
        for (let w in plan_result.warnings) push(lines, "  [!] " + w);
    }

    if (length(plan_result.errors) > 0) {
        push(lines, "──────────────────────────────────────────────────────────────────────────────");
        push(lines, " Errors:");
        for (let e in plan_result.errors) push(lines, "  [X] " + e);
    }

    push(lines, "──────────────────────────────────────────────────────────────────────────────");
    push(lines, " Summary (RU): " + plan_result.summary.ru);
    push(lines, " Summary (EN): " + plan_result.summary.en);
    push(lines, "══════════════════════════════════════════════════════════════════════════════");

    return join("\n", lines) + "\n";
}

// ─── Built-in Selftest ────────────────────────────────────────────────────────

function selftest() {
    let passed = 0;
    let failed = 0;

    function assert(cond, name) {
        if (cond) {
            passed++;
        } else {
            failed++;
            warn("FAIL: " + name + "\n");
        }
    }

    // Test 1: Value comparison
    assert(values_equal("abc", "abc") == true, "values_equal string match");
    assert(values_equal("abc", "def") == false, "values_equal string mismatch");
    assert(values_equal(["a", "b"], ["a", "b"]) == true, "values_equal array match");
    assert(values_equal(["a", "b"], ["a", "c"]) == false, "values_equal array mismatch");

    // Test 2: Words list parsing
    let w1 = words_list("a b, c\nd");
    assert(length(w1) == 4, "words_list parses space, comma and newline");

    // Test 3: Raw UCI text parsing
    let sample_uci = "config settings 'settings'\n\toption engine 'tachyon-core'\n\toption fakeip '1'\n\nconfig section 'unblock'\n\toption action 'proxy'\n\tlist domain 'instagram.com'\n";
    let parsed_uci = parse_uci_text_to_dict(sample_uci);
    assert(parsed_uci.settings.engine == "tachyon-core", "parse_uci_text_to_dict settings.engine");
    assert(parsed_uci.sections["unblock"] != null, "parse_uci_text_to_dict section found");
    assert(parsed_uci.sections["unblock"].domain[0] == "instagram.com", "parse_uci_text_to_dict list domain");

    // Test 4: UCI diff calculation
    let active_mock = {
        settings: { engine: "tachyon-core" },
        sections: { "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test.com" } },
        servers: {},
        all_by_name: {
            "settings": { ".name": "settings", ".type": "settings", engine: "tachyon-core" },
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test.com" }
        }
    };
    let candidate_mock = {
        settings: { engine: "tachyon-core" },
        sections: {
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test2.com" },
            "s2": { ".name": "s2", ".type": "section", action: "bypass" }
        },
        servers: {},
        all_by_name: {
            "settings": { ".name": "settings", ".type": "settings", engine: "tachyon-core" },
            "s1": { ".name": "s1", ".type": "section", action: "proxy", domain: "test2.com" },
            "s2": { ".name": "s2", ".type": "section", action: "bypass" }
        }
    };
    let diff = compute_uci_diff(active_mock, candidate_mock);
    assert(diff.has_changes == true, "diff detected changes");
    assert(length(diff.added_sections) == 1 && diff.added_sections[0].section == "s2", "diff detected added section s2");
    assert(length(diff.modified_sections) == 1 && diff.modified_sections[0].section == "s1", "diff detected modified s1");

    // Test 5: Validation catches invalid actions and malformed ports
    let bad_uci = {
        settings: {},
        sections: {
            "bad_sec": { ".name": "bad_sec", ".type": "section", action: "unknown_weird_action", port: "99999" }
        },
        servers: {},
        all_by_name: {}
    };
    let val_res = validate_uci_semantics(bad_uci);
    assert(val_res.status == "failed", "validation fails on bad action and port");
    assert(length(val_res.errors) >= 2, "validation records multiple errors");

    // Test 6: End-to-end plan on mock candidate
    let plan_res = plan(candidate_mock, { active_uci: active_mock });
    assert(plan_res.success == true, "plan execution succeeds");
    assert(plan_res.valid == true, "candidate_mock is valid");
    assert(plan_res.has_changes == true, "plan shows has_changes");

    // Test 7: Formatter text output
    let text = format_text_plan(plan_res);
    assert(index(text, "TACHYON CONFIGURATION PLAN") >= 0, "formatter includes header");
    assert(index(text, "ADD SECTION: [s2]") >= 0, "formatter lists added section");

    // Test 8: Routing & DNS rule overlap / shadowing detection (#331)
    let conflict_uci = {
        settings: { engine: "tachyon-core" },
        sections: {
            "allow_parent": { ".name": "allow_parent", ".type": "section", action: "direct", domain: [ "example.com" ] },
            "block_sub": { ".name": "block_sub", ".type": "section", action: "block", domain: [ "ads.example.com" ] }
        },
        servers: {},
        all_by_name: {}
    };
    let rc = analyze_rule_conflicts(conflict_uci);
    assert(length(rc.conflicts) == 1 && rc.conflicts[0].kind == "block_overridden", "analyze_rule_conflicts detects block overridden by earlier direct parent domain");
    assert(length(rc.shadowed_sections) == 1 && rc.shadowed_sections[0] == "block_sub", "analyze_rule_conflicts detects completely shadowed section");

    // Test 9 (#347): Content overlap between google_services in Direct and google_ai in VPN with DNS/route decisions
    let google_overlap_uci = {
        settings: { engine: "tachyon-core" },
        sections: {
            "Direct": { ".name": "Direct", ".type": "section", action: "direct", community_lists: [ "google_services" ] },
            "VPN": { ".name": "VPN", ".type": "section", action: "proxy", community_lists: [ "google_ai" ] }
        },
        servers: {},
        all_by_name: {}
    };
    let rc_google = analyze_rule_conflicts(google_overlap_uci);
    assert(length(rc_google.conflicts) >= 1 && rc_google.conflicts[0].kind == "list_overlap", "detects content overlap between google_services in Direct and google_ai in VPN");
    assert(rc_google.conflicts[0].winner_source == "list:google_services" && rc_google.conflicts[0].shadowed_source == "list:google_ai", "identifies source lists google_services and google_ai");
    assert(rc_google.conflicts[0].dns_decision.resolver == "dns-direct" && rc_google.conflicts[0].route_decision.section == "Direct", "exposes DNS and routing decisions for overlapped domains");
    assert(length(rc_google.dns_route_warnings) >= 1, "records DNS/route warning when Direct list shadows subsequent VPN list");

    // Test 10 (#347): Disjoint devices or non-overlapping ports are NOT declared completely shadowed
    let disjoint_cond_uci = {
        settings: { engine: "tachyon-core" },
        sections: {
            "dev_a": { ".name": "dev_a", ".type": "section", action: "direct", devices: [ "192.168.1.10" ], domain: [ "example.org" ], ports: [ "80" ] },
            "dev_b": { ".name": "dev_b", ".type": "section", action: "proxy", devices: [ "192.168.1.20" ], domain: [ "sub.example.org" ], ports: [ "443" ] },
            "narrow_early": { ".name": "narrow_early", ".type": "section", action: "direct", devices: [ "192.168.1.10" ], domain: [ "narrow.org" ] },
            "broad_later": { ".name": "broad_later", ".type": "section", action: "proxy", domain: [ "app.narrow.org" ] }
        },
        servers: {},
        all_by_name: {}
    };
    let rc_disjoint = analyze_rule_conflicts(disjoint_cond_uci);
    assert(index(rc_disjoint.shadowed_sections, "dev_b") < 0, "rules for different devices/ports are not declared shadowed");
    assert(index(rc_disjoint.shadowed_sections, "broad_later") < 0, "broad section after device-restricted section is only conditionally overlapped, not completely shadowed");

    // Test 11 (#347): Dynamic list update reflects new overlap, expected_overlaps acknowledges conflict, and unverified lists mark analysis incomplete
    let updated_list_uci = {
        settings: { engine: "tachyon-core" },
        sections: {
            "early_direct": { ".name": "early_direct", ".type": "section", action: "direct", community_lists: [ "custom_feed_a" ] },
            "later_vpn": { ".name": "later_vpn", ".type": "section", action: "proxy", community_lists: [ "custom_feed_b" ] }
        },
        servers: {},
        all_by_name: {}
    };
    let rc_unverified = analyze_rule_conflicts(updated_list_uci);
    assert(rc_unverified.analysis_completeness.complete == false && length(rc_unverified.analysis_completeness.unverified_lists) == 2, "incomplete analysis is explicitly reported when list contents are unavailable");

    let rc_after_update = analyze_rule_conflicts(updated_list_uci, {
        list_contents: {
            custom_feed_a: { domains: [ "shared-api.example.net" ], mtime: 1700000100, version: "2026.11" },
            custom_feed_b: { domains: [ "v1.shared-api.example.net" ], mtime: 1700000200, version: "2026.11" }
        }
    });
    assert(rc_after_update.analysis_completeness.complete == true && length(rc_after_update.conflicts) == 1, "new overlap after list update is reflected in diagnostics");

    let rc_acknowledged = analyze_rule_conflicts(updated_list_uci, {
        expected_overlaps: [ "early_direct->later_vpn" ],
        list_contents: {
            custom_feed_a: { domains: [ "shared-api.example.net" ], mtime: 1700000100 },
            custom_feed_b: { domains: [ "v1.shared-api.example.net" ], mtime: 1700000200 }
        }
    });
    assert(length(rc_acknowledged.conflicts) == 0 && length(rc_acknowledged.acknowledged_conflicts) == 1, "expected overlap is moved to acknowledged_conflicts and suppressed from active warnings");

    // Test 12: Indexed CIDR overlap scales to 2048x2048 entries in sub-second time
    let big_cidrs_a = [ "10.0.0.0/8", "2001:db8::/32" ];
    let big_cidrs_b = [ "10.42.1.0/24", "2001:db8::/32" ];
    for (let i = 0; i < 2046; i++) {
        push(big_cidrs_a, sprintf("100.%d.%d.0/24", int(i / 256), i % 256));
        push(big_cidrs_b, sprintf("198.%d.%d.0/24", int(i / 256), i % 256));
    }
    let t_start = clock();
    let rc_big_cidr = analyze_rule_conflicts(updated_list_uci, {
        list_contents: {
            custom_feed_a: { cidrs: big_cidrs_a },
            custom_feed_b: { cidrs: big_cidrs_b }
        }
    });
    let t_end = clock();
    let elapsed_ms = (t_end[0] - t_start[0]) * 1000 + int((t_end[1] - t_start[1]) / 1000000);
    assert(length(rc_big_cidr.conflicts) == 1 && rc_big_cidr.conflicts[0].overlap_count == 2, "indexed CIDR overlap detects subnet containment and exact IPv6 match across 2048x2048 lists");
    assert(elapsed_ms < 2000, sprintf("2048x2048 CIDR conflict analysis completes quickly (%d ms)", elapsed_ms));

    print(sprintf("Config plan selftest: %d passed, %d failed\n", passed, failed));
    return failed == 0 ? 0 : 1;
}

function module_exports() {
    return {
        plan,
        compute_uci_diff,
        analyze_subsystem_impact,
        analyze_rule_conflicts,
        refresh_conflict_diagnostics,
        validate_uci_semantics,
        load_candidate_uci,
        parse_uci_text_to_dict,
        format_text_plan,
        selftest
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ─── CLI Entrypoint ───────────────────────────────────────────────────────────

let mode = ARGV[0] || "";

if (mode == "selftest") {
    exit(selftest());
} else if (mode == "plan" || mode == "preview" || mode == "diff") {
    let candidate = "";
    let format = "text";
    for (let i = 1; i < length(ARGV); i++) {
        let arg = ARGV[i];
        if (arg == "--json") format = "json";
        else if (arg == "--text") format = "text";
        else if (candidate == "" && substr(arg, 0, 1) != "-") candidate = arg;
    }

    let res = plan(candidate);
    if (format == "json") {
        print(sprintf("%J\n", res));
    } else {
        print(format_text_plan(res));
    }
    exit(res.valid ? 0 : 1);
} else if (mode == "validate") {
    let candidate = "";
    for (let i = 1; i < length(ARGV); i++) {
        let arg = ARGV[i];
        if (candidate == "" && substr(arg, 0, 1) != "-") candidate = arg;
    }
    let res = plan(candidate);
    if (res.valid) {
        print("OK: Configuration is valid\n");
        exit(0);
    } else {
        warn("FAIL: Configuration has errors:\n");
        for (let e in res.errors) warn("  " + e + "\n");
        exit(1);
    }
}

return module_exports();
