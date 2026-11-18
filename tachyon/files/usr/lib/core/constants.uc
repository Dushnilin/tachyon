#!/usr/bin/env ucode

let common = require("core.common");
let as_string = common.as_string;
let shell_quote = common.shell_quote;

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

let fs = require("fs");

function detect_installed_version() {
    let ver = env("TACHYON_VERSION", "__COMPILED_VERSION_VARIABLE__");
    if (ver != "" && !match(ver, /COMPILED/) && ver != "unknown")
        return ver;

    try {
        let pkgs = require("core.packages");
        if (pkgs && pkgs.version) {
            let pkg_ver = pkgs.version("tachyon");
            if (pkg_ver != null && pkg_ver != "") return pkg_ver;
            pkg_ver = pkgs.version("luci-app-tachyon");
            if (pkg_ver != null && pkg_ver != "") return pkg_ver;
        }
    }
    catch (e) {
        // core.packages is absent on a source checkout and opkg is absent in
        // the test image; both fall through to the .control files below.
    }

    for (let path in [
        "/usr/lib/opkg/info/tachyon.control",
        "/usr/lib/opkg/info/luci-app-tachyon.control"
    ]) {
        let content = fs.readfile(path);
        if (content != null) {
            let m = match(content, /Version:\s*([0-9]+\.[0-9]+\.[0-9]+)/);
            if (m && m[1]) return m[1];
        }
    }

    let apk_db = fs.readfile("/lib/apk/db/installed");
    if (apk_db != null) {
        let lines = split(as_string(apk_db), "\n");
        let current_pkg = "";
        let fallback_ver = "";
        for (let line in lines) {
            if (substr(line, 0, 2) == "P:")
                current_pkg = trim(substr(line, 2));
            else if ((current_pkg == "tachyon" || current_pkg == "luci-app-tachyon") && substr(line, 0, 2) == "V:") {
                let v = match(trim(substr(line, 2)), /^([0-9]+\.[0-9]+\.[0-9]+)/);
                if (v && v[1]) {
                    if (current_pkg == "tachyon")
                        return v[1];
                    if (fallback_ver == "")
                        fallback_ver = v[1];
                }
            }
        }
        if (fallback_ver != "")
            return fallback_ver;
    }

    return "";
}

function detect_installed_commit_sha() {
    let sha = env("TACHYON_COMMIT_SHA", "__COMPILED_COMMIT_SHA__");
    if (sha != "" && !match(sha, /COMPILED/) && sha != "unknown")
        return sha;

    let file_sha = trim(as_string(fs.readfile("/etc/tachyon_commit")));
    if (file_sha != "" && file_sha != "unknown")
        return file_sha;

    let proc = fs.popen("git rev-parse --short HEAD 2>/dev/null");
    if (proc != null) {
        let git_sha = trim(as_string(proc.read("all")));
        proc.close();
        if (git_sha != "" && match(git_sha, /^[0-9a-fA-F]{7,40}$/) != null)
            return git_sha;
    }

    return "";
}

function constants_map() {
    let c = {};

    c.TACHYON_VERSION = detect_installed_version();
    c.TACHYON_COMMIT_SHA = detect_installed_commit_sha();
    c.TACHYON_CONFIG_NAME = env("TACHYON_CONFIG_NAME", "tachyon");
    c.TACHYON_CONFIG = env("TACHYON_CONFIG", "/etc/config/" + c.TACHYON_CONFIG_NAME);
    c.TACHYON_BIN = env("TACHYON_BIN", "/usr/bin/tachyon");
    c.TACHYON_SERVICE_NAME = env("TACHYON_SERVICE_NAME", "tachyon");
    c.TACHYON_SERVICE_INIT = env("TACHYON_SERVICE_INIT", "/etc/init.d/tachyon");
    c.TACHYON_RELEASE_REPO = env("TACHYON_RELEASE_REPO", "Dushnilin/tachyon");
    c.TACHYON_LUCI_VIEW_NAMESPACE = env("TACHYON_LUCI_VIEW_NAMESPACE", "tachyon");
    c.TACHYON_LUCI_VIEW_DIR = env("TACHYON_LUCI_VIEW_DIR", "/www/luci-static/resources/view/" + c.TACHYON_LUCI_VIEW_NAMESPACE);
    c.TACHYON_LUCI_I18N_DOMAIN = env("TACHYON_LUCI_I18N_DOMAIN", "tachyon");

    c.RESOLV_CONF = env("RESOLV_CONF", "/etc/resolv.conf");
    c.CHECK_PROXY_IP_DOMAIN = env("CHECK_PROXY_IP_DOMAIN", "ip.podkop.fyi");
    c.FAKEIP_TEST_DOMAIN = env("FAKEIP_TEST_DOMAIN", "fakeip.podkop.fyi");
    c.TMP_TACHYON_CORE_FOLDER = env("TMP_TACHYON_CORE_FOLDER", "/tmp/tachyon-core");
    c.TMP_RULESET_FOLDER = env("TMP_RULESET_FOLDER", c.TMP_TACHYON_CORE_FOLDER + "/rulesets");
    c.TMP_SUBSCRIPTION_FOLDER = env("TMP_SUBSCRIPTION_FOLDER", c.TMP_TACHYON_CORE_FOLDER + "/subscriptions");
    c.CLOUDFLARE_OCTETS = env("CLOUDFLARE_OCTETS", "8.47 162.159 188.114");
    c.COREUTILS_BASE64_REQUIRED_VERSION = env("COREUTILS_BASE64_REQUIRED_VERSION", "9.7");
    c.RT_TABLE_NAME = env("RT_TABLE_NAME", "tachyon");

    c.NFT_TABLE_NAME = env("NFT_TABLE_NAME", "TachyonTable");
    c.NFT_LOCALV4_SET_NAME = env("NFT_LOCALV4_SET_NAME", "localv4");
    c.NFT_LOCALV6_SET_NAME = env("NFT_LOCALV6_SET_NAME", "localv6");
    c.NFT_COMMON_SET_NAME = env("NFT_COMMON_SET_NAME", "tachyon_subnets");
    c.NFT_COMMON6_SET_NAME = env("NFT_COMMON6_SET_NAME", "tachyon_subnets6");
    c.NFT_PORT_SET_NAME = env("NFT_PORT_SET_NAME", "tachyon_ports");
    c.NFT_IP_PORT_SET_NAME = env("NFT_IP_PORT_SET_NAME", "tachyon_ip_ports");
    c.NFT_IP_PORT6_SET_NAME = env("NFT_IP_PORT6_SET_NAME", "tachyon_ip6_ports");
    c.NFT_DISCORD_SET_NAME = env("NFT_DISCORD_SET_NAME", "tachyon_discord_subnets");
    c.NFT_DISCORD6_SET_NAME = env("NFT_DISCORD6_SET_NAME", "tachyon_discord_subnets6");
    c.NFT_INTERFACE_SET_NAME = env("NFT_INTERFACE_SET_NAME", "tachyon_interfaces");
    c.NFT_FAKEIP_MARK = env("NFT_FAKEIP_MARK", "0x04000000");
    c.NFT_OUTBOUND_MARK = env("NFT_OUTBOUND_MARK", "0x08000000");

    c.CORE_MANAGED_SERVICE_MARKER = env("TACHYON_CORE_MANAGED_SERVICE_MARKER", "Tachyon managed tachyon-core service");
    c.CORE_DNS_SERVER_TAG = env("TACHYON_CORE_DNS_SERVER_TAG", "dns-server");
    c.CORE_FAKEIP_DNS_SERVER_TAG = env("TACHYON_CORE_FAKEIP_DNS_SERVER_TAG", "fakeip-server");
    c.CORE_FAKEIP_INET4_RANGE = env("TACHYON_CORE_FAKEIP_INET4_RANGE", "198.18.0.0/15");
    c.CORE_FAKEIP_INET6_RANGE = env("TACHYON_CORE_FAKEIP_INET6_RANGE", "fc00::/18");
    c.CORE_BOOTSTRAP_SERVER_TAG = env("TACHYON_CORE_BOOTSTRAP_SERVER_TAG", "bootstrap-dns-server");
    c.CORE_FAKEIP_DNS_RULE_TAG = env("TACHYON_CORE_FAKEIP_DNS_RULE_TAG", "fakeip-dns-rule-tag");
    c.CORE_FAKEIP_RULESET_DNS_RULE_TAG = env("TACHYON_CORE_FAKEIP_RULESET_DNS_RULE_TAG", "fakeip-ruleset-dns-rule-tag");
    c.CORE_SERVICE_FAKEIP_DNS_RULE_TAG = env("TACHYON_CORE_SERVICE_FAKEIP_DNS_RULE_TAG", "service-fakeip-dns-rule-tag");
    c.CORE_TPROXY_INBOUND_TAG = env("TACHYON_CORE_TPROXY_INBOUND_TAG", "tproxy-in");
    c.CORE_TPROXY_INBOUND_ADDRESS = env("TACHYON_CORE_TPROXY_INBOUND_ADDRESS", "0.0.0.0");
    c.CORE_TPROXY_INBOUND6_TAG = env("TACHYON_CORE_TPROXY_INBOUND6_TAG", "tproxy6-in");
    c.CORE_TPROXY_INBOUND6_ADDRESS = env("TACHYON_CORE_TPROXY_INBOUND6_ADDRESS", "::1");
    c.CORE_TPROXY_INBOUND_PORT = env("TACHYON_CORE_TPROXY_INBOUND_PORT", "1602");
    c.CORE_DNS_INBOUND_TAG = env("TACHYON_CORE_DNS_INBOUND_TAG", "dns-in");
    c.CORE_DNS_INBOUND_ADDRESS = env("TACHYON_CORE_DNS_INBOUND_ADDRESS", "127.0.0.42");
    c.CORE_DNS_INBOUND_PORT = env("TACHYON_CORE_DNS_INBOUND_PORT", "53");
    c.CORE_DNS_BLOCK_INBOUND_TAG = env("TACHYON_CORE_DNS_BLOCK_INBOUND_TAG", "dns-block-in");
    c.CORE_DNS_BLOCK_INBOUND_ADDRESS = env("TACHYON_CORE_DNS_BLOCK_INBOUND_ADDRESS", "::");
    c.CORE_DNS_BLOCK_INBOUND_PORT = env("TACHYON_CORE_DNS_BLOCK_INBOUND_PORT", "1053");
    c.CORE_SERVICE_MIXED_INBOUND_TAG = env("TACHYON_CORE_SERVICE_MIXED_INBOUND_TAG", "service-mixed-in");
    c.CORE_SERVICE_MIXED_INBOUND_ADDRESS = env("TACHYON_CORE_SERVICE_MIXED_INBOUND_ADDRESS", "127.0.0.1");
    c.CORE_SERVICE_MIXED_INBOUND_PORT = env("TACHYON_CORE_SERVICE_MIXED_INBOUND_PORT", "4534");
    c.CORE_DIRECT_OUTBOUND_TAG = env("TACHYON_CORE_DIRECT_OUTBOUND_TAG", "direct-out");
    c.CORE_BYPASS_OUTBOUND_TAG = env("TACHYON_CORE_BYPASS_OUTBOUND_TAG", "bypass-out");
    c.CORE_CLASH_API_CONTROLLER_PORT = env("TACHYON_CORE_CLASH_API_CONTROLLER_PORT", "9090");
    c.CORE_VERSION_STATE_FILE = env("TACHYON_CORE_VERSION_FILE", "/etc/tachyon/tachyon-core-version");
    c.TACHYON_CORE_DNS_INBOUND_ADDRESS = c.CORE_DNS_INBOUND_ADDRESS;
    c.TACHYON_CORE_TPROXY_INBOUND6_ADDRESS = c.CORE_TPROXY_INBOUND6_ADDRESS;
    c.TACHYON_CORE_TPROXY_INBOUND_PORT = c.CORE_TPROXY_INBOUND_PORT;
    c.TACHYON_CORE_CLASH_API_CONTROLLER_PORT = c.CORE_CLASH_API_CONTROLLER_PORT;
    c.TACHYON_CORE_VERSION_FILE = c.CORE_VERSION_STATE_FILE;

    c.TACHYON_LISTS_RAW_URL = env("TACHYON_LISTS_RAW_URL", "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release");
    c.GITHUB_RAW_URL = env("GITHUB_RAW_URL", c.TACHYON_LISTS_RAW_URL);
    c.SUBNETS_TWITTER = env("SUBNETS_TWITTER", c.TACHYON_LISTS_RAW_URL + "/subnets/twitter.lst");
    c.SUBNETS_META = env("SUBNETS_META", c.TACHYON_LISTS_RAW_URL + "/subnets/meta.lst");
    c.SUBNETS_DISCORD = env("SUBNETS_DISCORD", c.TACHYON_LISTS_RAW_URL + "/subnets/discord.lst");
    c.SUBNETS_ROBLOX = env("SUBNETS_ROBLOX", c.TACHYON_LISTS_RAW_URL + "/subnets/roblox.lst");
    c.SUBNETS_TELERAM = env("SUBNETS_TELERAM", c.TACHYON_LISTS_RAW_URL + "/subnets/telegram.lst");
    c.SUBNETS_CLOUDFLARE = env("SUBNETS_CLOUDFLARE", c.TACHYON_LISTS_RAW_URL + "/subnets/cloudflare.lst");
    c.SUBNETS_HETZNER = env("SUBNETS_HETZNER", c.TACHYON_LISTS_RAW_URL + "/subnets/hetzner.lst");
    c.SUBNETS_OVH = env("SUBNETS_OVH", c.TACHYON_LISTS_RAW_URL + "/subnets/ovh.lst");
    c.SUBNETS_DIGITALOCEAN = env("SUBNETS_DIGITALOCEAN", c.TACHYON_LISTS_RAW_URL + "/subnets/digitalocean.lst");
    c.SUBNETS_CLOUDFRONT = env("SUBNETS_CLOUDFRONT", c.TACHYON_LISTS_RAW_URL + "/subnets/cloudfront.lst");
    c.SUBNETS_GOOGLE_MEET = env("SUBNETS_GOOGLE_MEET", c.TACHYON_LISTS_RAW_URL + "/subnets/google_meet.lst");
    c.SUBNETS_ZOOM_TEAMS = env("SUBNETS_ZOOM_TEAMS", c.TACHYON_LISTS_RAW_URL + "/subnets/zoom_teams.lst");
    c.SUBNETS_DISCORD_VOICE = env("SUBNETS_DISCORD_VOICE", c.TACHYON_LISTS_RAW_URL + "/subnets/discord_voice.lst");
    c.SUBNETS_CALLOFDUTY = env("SUBNETS_CALLOFDUTY", c.TACHYON_LISTS_RAW_URL + "/subnets/callofduty.lst");
    c.SUBNETS_GAME_BACKENDS = env("SUBNETS_GAME_BACKENDS", c.TACHYON_LISTS_RAW_URL + "/subnets/game_backends.lst");
    c.SUBNETS_CS2_DOTA2 = env("SUBNETS_CS2_DOTA2", c.TACHYON_LISTS_RAW_URL + "/subnets/cs2_dota2.lst");
    c.SUBNETS_DOH_DOT_DNS = env("SUBNETS_DOH_DOT_DNS", c.TACHYON_LISTS_RAW_URL + "/subnets/doh_dot_dns.lst");
    c.SUBNETS_VPS_CLOUDS = env("SUBNETS_VPS_CLOUDS", c.TACHYON_LISTS_RAW_URL + "/subnets/vps_clouds.lst");
    c.SUBNETS_ET_SPAMHAUS_BLOCK = env("SUBNETS_ET_SPAMHAUS_BLOCK", c.TACHYON_LISTS_RAW_URL + "/subnets/et_spamhaus_block.lst");
    c.SUBNETS_HAGEZI_TIF_IP_BLOCK = env("SUBNETS_HAGEZI_TIF_IP_BLOCK", c.TACHYON_LISTS_RAW_URL + "/subnets/hagezi_tif_ip_block.lst");
    c.SUBNETS_BOTNET_ATTACKERS_IP_BLOCK = env("SUBNETS_BOTNET_ATTACKERS_IP_BLOCK", c.TACHYON_LISTS_RAW_URL + "/subnets/botnet_attackers_ip_block.lst");
    c.COMMUNITY_SERVICES = env("COMMUNITY_SERVICES", "russia_inside russia_outside ukraine_inside belarus_inside geoblock block porn news anime youtube youtube_images tmdb_metadata streaming_west books_archives podcasts_radio hdrezka tiktok google_ai google_play google_meet google_services hodca discord discord_voice meta twitter cloudflare cloudfront digitalocean hetzner ovh vps_clouds doh_dot_dns telegram roblox ads_hagezi_pro supercell github twitch ru_whitelist ru_domains ru_only_inside push steam_cdn captive_ntp_stun ru_blocked ru_blocked_all antifilter refilter apple microsoft win_spy steam epicgames riot origin escapefromtarkov faceit callofduty game_backends cs2_dota2 survival_coop mmorpg netease_tencent_games japanese_publishers fighting_racing strategy_sim meta_quest chess_boardgames gaming_mods_stats pinterest torrent twitch_ads kick ai_all openai anthropic xai openrouter cursor perplexity copilot deepseek qwen kimi midjourney elevenlabs huggingface ai_video ai_cloud_gpu spotify netflix soundcloud_music rutracker_lampa patreon_creators whatsapp messengers reddit zoom_teams linkedin games_all ubisoft warthunder blizzard xbox playstation nintendo gog wargaming hoyoverse minecraft rockstar pubg docker tor fastly jetbrains gitlab_notion figma_adobe pkg_registries paas_db captcha_auth cloud_gaming_remote cloud_storage gamedev_3d security_passwords smarthome_iot smarttv_apps smart_cars linux_repos speedtest crypto paypal_fintech travel_booking shopping_global edtech_learning freelance_remote sports_fitness xiaomi_smarttv_ads android_ads_block gambling_block phishing_malware_block telemetry_mobile_block et_spamhaus_block hagezi_tif_ip_block botnet_attackers_ip_block");

    return c;
}

function print_shell_env(constants) {
    for (let name in sort(keys(constants)))
        print(name, "=", shell_quote(constants[name]), "\n");
}

function module_exports() {
    return constants_map();
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
let constants = constants_map();

if (mode == "shell-env")
    print_shell_env(constants);
else if (mode == "json")
    print(sprintf("%J", constants), "\n");
else if (mode == "get")
    print(as_string(constants[ARGV[1]]), "\n");
else {
    warn("Usage: core/constants.uc <shell-env|json|get> ...\n");
    exit(1);
}