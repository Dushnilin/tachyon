#!/usr/bin/env ucode

// DNS Turbo Cache prefetch worker.
// Resolves domains through the local DNS (127.0.0.1) to pre-populate the
// sing-box FakeIP cache so first-visit latency is 0 ms.
//
// Domain sources (in priority order):
//   1. user_domains / user_domains_text from every active tachyon section
//   2. domain / domain_suffix rule conditions from active sections
//   3. Built-in baseline list of commonly blocked services

let common = require("core.common");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

// ─── Fallback baseline list ───────────────────────────────────────────────────
// Used when a user has no custom domains configured yet. Covers the most
// popular Russian-blocked services and their CDN / API subdomains.

const BASELINE_DOMAINS = [
    // ── Telegram ──────────────────────────────────────────────────────────────
    "t.me", "telegram.org", "web.telegram.org", "desktop.telegram.org",
    "api.telegram.org", "core.telegram.org", "cdn.telegram.org",
    "updates.telegram.org", "media.telegram.org",

    // ── YouTube ───────────────────────────────────────────────────────────────
    "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
    "music.youtube.com", "studio.youtube.com", "ytimg.com", "s.ytimg.com",
    "i.ytimg.com", "yt3.ggpht.com", "googlevideo.com", "yt.be",
    "youtubei.googleapis.com", "youtube-nocookie.com",

    // ── Instagram / Meta ──────────────────────────────────────────────────────
    "instagram.com", "www.instagram.com", "cdninstagram.com",
    "i.instagram.com", "graph.instagram.com",
    "facebook.com", "www.facebook.com", "m.facebook.com", "fbcdn.net",
    "messenger.com", "www.messenger.com", "connect.facebook.net",
    "whatsapp.com", "www.whatsapp.com", "web.whatsapp.com",
    "media.whatsapp.net", "mmg.whatsapp.net",

    // ── Twitter / X ───────────────────────────────────────────────────────────
    "twitter.com", "www.twitter.com", "x.com", "www.x.com",
    "t.co", "twimg.com", "abs.twimg.com", "pbs.twimg.com",
    "video.twimg.com", "api.twitter.com", "api.x.com",

    // ── Discord ───────────────────────────────────────────────────────────────
    "discord.com", "www.discord.com", "discordapp.com", "discord.gg",
    "cdn.discordapp.com", "media.discordapp.net", "gateway.discord.gg",

    // ── Reddit ────────────────────────────────────────────────────────────────
    "reddit.com", "www.reddit.com", "old.reddit.com", "redd.it",
    "redditmedia.com", "redditstatic.com", "v.redd.it", "i.redd.it",

    // ── GitHub ────────────────────────────────────────────────────────────────
    "github.com", "api.github.com", "gist.github.com",
    "raw.githubusercontent.com", "objects.githubusercontent.com",
    "codeload.github.com", "avatars.githubusercontent.com",
    "github.githubassets.com",

    // ── Google ────────────────────────────────────────────────────────────────
    "google.com", "www.google.com", "google.ru", "mail.google.com",
    "drive.google.com", "docs.google.com", "meet.google.com",
    "calendar.google.com", "photos.google.com", "accounts.google.com",
    "translate.google.com", "maps.google.com", "lh3.googleusercontent.com",

    // ── Netflix ───────────────────────────────────────────────────────────────
    "netflix.com", "www.netflix.com", "nflxvideo.net", "nflximg.net", "nflxso.net",

    // ── Spotify ───────────────────────────────────────────────────────────────
    "spotify.com", "open.spotify.com", "api.spotify.com", "scdn.co",

    // ── TikTok ────────────────────────────────────────────────────────────────
    "tiktok.com", "www.tiktok.com", "m.tiktok.com", "tiktokcdn.com",

    // ── Twitch ────────────────────────────────────────────────────────────────
    "twitch.tv", "www.twitch.tv", "static-cdn.jtvnw.net", "api.twitch.tv",

    // ── Wikipedia ────────────────────────────────────────────────────────────
    "wikipedia.org", "ru.wikipedia.org", "en.wikipedia.org",
    "upload.wikimedia.org", "wikimedia.org",

    // ── LinkedIn / Pinterest / Snapchat ───────────────────────────────────────
    "linkedin.com", "www.linkedin.com",
    "pinterest.com", "www.pinterest.com", "i.pinimg.com",
    "snapchat.com", "www.snapchat.com",

    // ── Signal ────────────────────────────────────────────────────────────────
    "signal.org", "www.signal.org", "cdn.signal.org",

    // ── Steam / Gaming ────────────────────────────────────────────────────────
    "steampowered.com", "store.steampowered.com", "steamcommunity.com",
    "steamcdn-a.akamaihd.net", "cdn.cloudflare.steamstatic.com",
    "epicgames.com", "www.epicgames.com",
    "roblox.com", "www.roblox.com",

    // ── ProtonMail / Privacy ──────────────────────────────────────────────────
    "proton.me", "mail.proton.me", "protonmail.com",

    // ── Medium / Substack ─────────────────────────────────────────────────────
    "medium.com", "substack.com",

    // ── News ──────────────────────────────────────────────────────────────────
    "bbc.com", "bbc.co.uk", "reuters.com", "theguardian.com", "nytimes.com",

    // ── Misc ──────────────────────────────────────────────────────────────────
    "patreon.com", "canva.com", "notion.so", "figma.com",
    "slack.com", "zoom.us", "dropbox.com",
];

// ─── Domain extraction from UCI sections ─────────────────────────────────────

function list_to_array(value) {
    if (type(value) == "array")
        return value;
    let s = trim(common.as_string(value));
    return s != "" ? [ s ] : [];
}

function parse_text_domains(text) {
    let result = [];
    for (let line in split(common.as_string(text), /[\n\r]+/)) {
        // Strip full-line comments (# or // style)
        line = trim(line);
        if (line == "" || substr(line, 0, 1) == "#" || substr(line, 0, 2) == "//")
            continue;
        // Strip inline comments
        line = replace(line, /[ \t]+\/\/.*$/, "");
        line = replace(line, /[ \t]+#.*$/, "");
        for (let token in split(line, /[,\s]+/)) {
            token = trim(token);
            // Strip leading dots (domain_suffix style) and wildcards
            token = replace(token, /^\*?\./, "");
            if (token != "" && substr(token, 0, 1) != "#" && substr(token, 0, 2) != "//")
                push(result, token);
        }
    }
    return result;
}

function collect_section_domains(section) {
    let result = [];
    let list_type = common.as_string(section.user_domain_list_type || "disabled");

    // user_domains (UCI list, type=dynamic)
    if (list_type == "dynamic") {
        for (let d in list_to_array(section.user_domains))
            for (let x in parse_text_domains(d))
                push(result, x);
    }

    // user_domains_text (textarea, type=text)
    if (list_type == "text") {
        for (let x in parse_text_domains(common.as_string(section.user_domains_text || "")))
            push(result, x);
    }

    // domain / domain_suffix rule conditions
    for (let key in [ "domain", "domain_suffix" ]) {
        for (let d in list_to_array(section[key]))
            for (let x in parse_text_domains(d))
                push(result, x);
        let text = common.as_string(section[key + "s"] || "");  // plural textarea
        if (text != "")
            for (let x in parse_text_domains(text))
                push(result, x);
    }

    return result;
}

function collect_user_domains() {
    let seen = {};
    let result = [];

    uci_core.foreach(CONFIG_NAME, "section", function(section) {
        if (section.enabled == "0")
            return;
        for (let domain in collect_section_domains(section)) {
            domain = lc(trim(domain));
            if (domain != "" && !seen[domain]) {
                seen[domain] = true;
                push(result, domain);
            }
        }
    });

    return result;
}

// ─── Prefetch ─────────────────────────────────────────────────────────────────

function prefetch() {
    let settings = common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    if (!common.bool_option(settings, "dns_turbo_cache", true))
        return;

    // Give sing-box time to fully initialize — poll instead of blocking sleep
    let ready = false;
    for (let i = 0; i < 20; i++) {
        if (common.command_success_from_args(["nslookup", "localhost", "127.0.0.1"])) {
            ready = true;
            break;
        }
        common.command_success_from_args(["sleep", "1"]);
    }
    if (!ready) return;

    // 1. Collect domains from user's actual sections (highest priority)
    let seen = {};
    let domains = [];

    for (let d in collect_user_domains()) {
        if (!seen[d]) {
            seen[d] = true;
            push(domains, d);
        }
    }

    // 2. Merge baseline list (skip already queued)
    for (let d in BASELINE_DOMAINS) {
        d = lc(d);
        if (!seen[d]) {
            seen[d] = true;
            push(domains, d);
        }
    }

    // 3. Resolve all via local DNS to warm FakeIP cache (batched parallel)
    let batch = [];
    for (let i, domain in domains) {
        push(batch, common.shell_quote(domain));
        if (length(batch) >= 15 || i == length(domains) - 1) {
            let batch_cmd = "for d in " + join(" ", batch) + "; do nslookup \"$d\" 127.0.0.1 >/dev/null 2>&1; done &";
            common.command_success_from_args(["sh", "-c", batch_cmd]);
            batch = [];
        }
    }
}

let mode = ARGV[0];
if (mode == "prefetch")
    prefetch();
