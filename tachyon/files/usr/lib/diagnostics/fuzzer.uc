#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let rag = require("diagnostics.rag");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const STATE_DIR = getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const STATE_FILE = STATE_DIR + "/fuzzer-state.json";
const PID_FILE = STATE_DIR + "/fuzzer-worker.pid";
const HISTORY_FILE = "/etc/tachyon/fuzzer_history.json";
const BYEDPI_PORT = 11089;
const NFQUEUE_QNUM_ZAPRET = 298;
const NFQUEUE_QNUM_ZAPRET2 = 299;
const FUZZER_FWMARK = "0x40000000";

function resolve_binary(paths) {
    for (let p in paths) {
        if (p && fs.stat(p) != null)
            return p;
    }
    return null;
}

function get_zapret2_bin() {
    return resolve_binary([
        getenv("ZAPRET2_NFQWS2_BIN"),
        "/opt/zapret2/nfq2/nfqws2",
        "/opt/zapret2/nfq/nfqws2",
        "/opt/zapret2/nfqws2",
        "/usr/bin/nfqws2"
    ]);
}

function get_zapret_bin() {
    return resolve_binary([
        getenv("ZAPRET_NFQWS_BIN"),
        "/opt/zapret/nfq/nfqws",
        "/opt/zapret/nfqws",
        "/usr/bin/nfqws"
    ]);
}

function get_byedpi_bin() {
    return resolve_binary([
        getenv("BYEDPI_BIN"),
        "/opt/byedpi/ciadpi",
        "/usr/bin/ciadpi"
    ]);
}

function get_zapret2_lua_flags(args_str) {
    if (index(args_str, "--lua-init") >= 0)
        return "";

    let candidate_dirs = [
        getenv("ZAPRET2_PROVIDER_LUA_DIR"),
        "/opt/zapret2/lua",
        "/usr/share/zapret2/lua",
        "/etc/zapret2/lua",
        "/opt/zapret/lua",
        "/usr/share/zapret/lua"
    ];

    let flags = "";
    for (let d in candidate_dirs) {
        if (!d || fs.stat(d) == null)
            continue;
        let lib_lua = d + "/zapret-lib.lua";
        let antidpi_lua = d + "/zapret-antidpi.lua";
        let auto_lua = d + "/zapret-auto.lua";
        if (fs.stat(lib_lua) != null || fs.stat(lib_lua + ".gz") != null) flags += sprintf("--lua-init=@%s ", lib_lua);
        if (fs.stat(antidpi_lua) != null || fs.stat(antidpi_lua + ".gz") != null) flags += sprintf("--lua-init=@%s ", antidpi_lua);
        if (fs.stat(auto_lua) != null || fs.stat(auto_lua + ".gz") != null) flags += sprintf("--lua-init=@%s ", auto_lua);
        if (flags != "")
            break;
    }
    if (flags == "" && fs.stat("/opt/zapret2/lua") != null) {
        flags = "--lua-init=@/opt/zapret2/lua/zapret-lib.lua --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua --lua-init=@/opt/zapret2/lua/zapret-auto.lua ";
    }
    return flags;
}

let _fuzzer_curl_dns_flags = null;
function get_fuzzer_curl_dns_flags() {
    if (_fuzzer_curl_dns_flags !== null)
        return _fuzzer_curl_dns_flags;
    if (system("curl --doh-url https://1.1.1.1/dns-query -V >/dev/null 2>&1") == 0) {
        _fuzzer_curl_dns_flags = "--doh-url https://1.1.1.1/dns-query ";
        return _fuzzer_curl_dns_flags;
    }
    if (system("curl --dns-servers 8.8.8.8 -V >/dev/null 2>&1") == 0) {
        _fuzzer_curl_dns_flags = "--dns-servers 8.8.8.8,1.1.1.1 ";
        return _fuzzer_curl_dns_flags;
    }
    _fuzzer_curl_dns_flags = "";
    return _fuzzer_curl_dns_flags;
}

const KNOWN_BLOB_FILES = {
    tls_max: { file: "tls_clienthello_max_ru.bin", size: 654, desc: "Max.ru authentic ClientHello" },
    tls_google: { file: "tls_clienthello_www_google_com.bin", size: 681, desc: "Google authentic ClientHello" },
    tls_gosuslugi: { file: "tls_clienthello_gosuslugi_ru.bin", size: 517, desc: "Gosuslugi Russian Government ClientHello" },
    tls_sber: { file: "tls_clienthello_sberbank_ru.bin", size: 517, desc: "Sberbank authentic ClientHello" },
    tls_iana: { file: "tls_clienthello_iana_org.bin", size: 517, desc: "IANA root authority ClientHello" },
    tls_vk: { file: "tls_clienthello_vk_com.bin", size: 517, desc: "VK authentic ClientHello" },
    tls_onetrust: { file: "tls_clienthello_www_onetrust_com.bin", size: 664, desc: "OneTrust CDN ClientHello" },
    quic_google: { file: "quic_initial_www_google_com.bin", size: 1200, desc: "Google QUIC Initial" },
    quic_yt1: { file: "quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_1.bin", size: 1230, desc: "GoogleVideo Kyber QUIC Initial" },
    quic_vk: { file: "quic_initial_vk_com.bin", size: 1357, desc: "VK QUIC Initial" },
    stun_fake: { file: "stun.bin", size: 100, desc: "STUN discovery packet" },
    discord_udp: { file: "stun.bin", size: 100, desc: "Discord Voice UDP fake packet" }
};

function get_zapret2_blob_dir() {
    let candidate_dirs = [
        getenv("ZAPRET2_PROVIDER_FILES_DIR") ? (getenv("ZAPRET2_PROVIDER_FILES_DIR") + "/fake") : null,
        "/opt/zapret2/files/fake",
        "/usr/share/zapret2/files/fake",
        "/etc/zapret2/files/fake",
        "/opt/zapret/files/fake",
        "/usr/share/zapret/files/fake"
    ];
    for (let d in candidate_dirs) {
        if (d && fs.stat(d) != null) return d;
    }
    return "/opt/zapret2/files/fake";
}

function resolve_zapret2_blobs(args_str) {
    if (!args_str || args_str == "") return "";
    let bdir = get_zapret2_blob_dir();
    let blob_flags = "";
    for (let name, info in KNOWN_BLOB_FILES) {
        if ((index(args_str, "blob=" + name) >= 0 || index(args_str, "seqovl_pattern=" + name) >= 0) &&
            index(args_str, "--blob=" + name + ":") < 0) {
            let blob_path = bdir + "/" + info.file;
            if (fs.stat(blob_path) != null || fs.stat("/opt/zapret2/files/fake/" + info.file) != null) {
                let actual_path = fs.stat(blob_path) != null ? blob_path : ("/opt/zapret2/files/fake/" + info.file);
                blob_flags += sprintf("--blob=%s:@%s ", name, actual_path);
            }
        }
    }
    return blob_flags;
}

function setup_fuzzer_direct_nftables(qnum, is_udp) {
    system("nft add table inet tachyon_fuzzer 2>/dev/null");
    system("nft 'add chain inet tachyon_fuzzer output { type filter hook output priority -200 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft add rule inet tachyon_fuzzer output meta mark %s counter return 2>/dev/null", FUZZER_FWMARK));
    if (is_udp) {
        system(sprintf("nft 'add rule inet tachyon_fuzzer output meta l4proto { tcp, udp } th dport { 80, 443, 2053, 2083, 2087, 2096, 8443, 19294-19344, 50000-65535 } counter queue num %d bypass' 2>/dev/null", qnum));
    } else {
        system(sprintf("nft 'add rule inet tachyon_fuzzer output meta l4proto tcp tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } counter queue num %d bypass' 2>/dev/null", qnum));
    }
    // Route hook with priority -155 (before TachyonTable's -150) marks test traffic with 0x00200000 (direct outbound mark)
    // This guarantees that TachyonTable's mangle_output immediately returns and test traffic goes DIRECT to WAN without Sing-box TProxy
    system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
    system(sprintf("nft add rule inet tachyon_fuzzer bypass_singbox meta mark %s counter return 2>/dev/null", FUZZER_FWMARK));
    system("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } meta mark set meta mark | 0x00200000 counter' 2>/dev/null");
    if (is_udp) {
        system("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto udp udp dport { 80, 443, 19294-19344, 50000-65535 } meta mark set meta mark | 0x00200000 counter' 2>/dev/null");
    }
}

function validate_strategy_args(engine, args_val) {
    args_val = trim(as_string(args_val));
    if (args_val == "") return false;
    engine = lc(as_string(engine));
    try {
        if (engine == "zapret2") {
            let val = require("providers.zapret2.validator");
            let res = val.validate_strategy("nfqws2", args_val, "");
            return res ? res.valid == true : true;
        } else if (engine == "zapret") {
            let val = require("providers.zapret.validator");
            let res = val.validate_strategy("nfqws", args_val, "");
            return res ? res.valid == true : true;
        } else if (engine == "byedpi") {
            let val = require("providers.byedpi.validator");
            let res = val.validate_strategy(args_val, "");
            return res ? res.valid == true : true;
        }
    } catch (e) {
        return true;
    }
    return true;
}

const PATTERNS_FILE = "/etc/tachyon/fuzzer_patterns.json";

const DEFAULT_PATTERNS = {
    zapret2: {
        splits: [ "1", "2", "3", "midsld", "sniext+2", "sniext+4", "1,midsld", "1,sniext+2" ],
        foolings: [ "badseq", "md5sig", "badack", "datanoack", "fakeddrop" ],
        ttls: [ 2, 3, 4, 5, 6, 8 ],
        seqovls: [ "1", "2" ],
        wsizes: [ "1" ],
        blobs: [ "tls_max", "tls_google", "tls_gosuslugi", "tls_sber", "tls_iana" ],
        syndata: true,
        repeats: [ 6, 8 ],
        payloads: [ "tls_client_hello", "http_req", "quic_initial" ]
    },
    zapret: {
        splits: [ "1", "2", "midsld", "sniext+4", "1,midsld" ],
        foolings: [ "badseq", "md5sig", "badack", "datanoack" ],
        ttls: [ 2, 3, 4, 6, 8 ],
        split_modes: [ "split2", "disorder2", "fake,split2", "fake,disorder2" ]
    },
    byedpi: {
        splits: [ "1", "2", "1+sniext", "midsld" ],
        disorders: [ "1", "2" ],
        ttls: [ 2, 3, 4, 6, 8 ],
        oobs: [ "1", "2" ],
        autos: [ "t,r,a,s", "r,s", "t,a" ],
        tlsrecs: [ "1+sniext" ],
        ipfrags: [ "24" ]
    },
    custom_strategies: []
};

function get_patterns_config() {
    let custom = read_json_file(PATTERNS_FILE);
    if (custom && type(custom) == "object") {
        return {
            zapret2: custom.zapret2 || DEFAULT_PATTERNS.zapret2,
            zapret: custom.zapret || DEFAULT_PATTERNS.zapret,
            byedpi: custom.byedpi || DEFAULT_PATTERNS.byedpi,
            custom_strategies: custom.custom_strategies || []
        };
    }
    return DEFAULT_PATTERNS;
}

function save_patterns_config(cfg_obj) {
    if (!cfg_obj || type(cfg_obj) != "object") {
        print(sprintf("%J\n", { success: false, error: "Invalid patterns configuration object" }));
        return;
    }
    common.ensure_dir("/etc/tachyon");
    write_json_file(PATTERNS_FILE, cfg_obj);
    print(sprintf("%J\n", { success: true, message: "Patterns configuration saved successfully" }));
}

function reset_patterns_config() {
    try { fs.unlink(PATTERNS_FILE); } catch(e) {}
    print(sprintf("%J\n", { success: true, message: "Patterns configuration reset to factory defaults", patterns: DEFAULT_PATTERNS }));
}

// Target Suites & Definitions
const TARGET_SUITES = {
    youtube_suite: {
        name: "YouTube Full Suite (Web + Static CDN + Stream)",
        urls: [
            { name: "Web Interface", url: "https://www.youtube.com", weight: 40 },
            { name: "Static Assets (i.ytimg)", url: "https://i.ytimg.com/generate_204", weight: 30 },
            { name: "GoogleVideo Stream CDN", url: "https://redirector.googlevideo.com/generate_204", weight: 30 }
        ]
    },
    discord_suite: {
        name: "Discord Full Suite (API + WSS Gateway + CDN)",
        urls: [
            { name: "API Gateway", url: "https://discord.com/api/v9/gateway", weight: 40 },
            { name: "Global Assets CDN", url: "https://cdn.discordapp.com/generate_204", weight: 30 },
            { name: "Discord Web Portal", url: "https://discord.com/login", weight: 30 }
        ]
    },
    twitch_suite: {
        name: "Twitch Live Suite (Web + HLS Video + CDN)",
        urls: [
            { name: "Web Portal", url: "https://www.twitch.tv", weight: 40 },
            { name: "Static Assets CDN", url: "https://static-cdn.jtvnw.net/", weight: 30 },
            { name: "HLS Usher API", url: "https://usher.ttvnw.net/", weight: 30 }
        ]
    },
    twitter_suite: {
        name: "X / Twitter Suite (Web + API + CDN)",
        urls: [
            { name: "X Web Portal", url: "https://x.com", weight: 40 },
            { name: "API Endpoint", url: "https://api.x.com/", weight: 30 },
            { name: "Twimg Media CDN", url: "https://pbs.twimg.com/", weight: 30 }
        ]
    },
    chatgpt_suite: {
        name: "ChatGPT / OpenAI Suite (Web + Static CDN)",
        urls: [
            { name: "ChatGPT Portal", url: "https://chatgpt.com", weight: 50 },
            { name: "Static Assets CDN", url: "https://cdn.oaistatic.com/", weight: 50 }
        ]
    },
    instagram_suite: {
        name: "Instagram / Meta Suite (Web + Static CDN)",
        urls: [
            { name: "Web Interface", url: "https://www.instagram.com", weight: 50 },
            { name: "CDN Static Assets", url: "https://static.cdninstagram.com/", weight: 50 }
        ]
    },
    telegram_suite: {
        name: "Telegram Suite (Web + API)",
        urls: [
            { name: "Web App", url: "https://web.telegram.org", weight: 50 },
            { name: "Bot API", url: "https://api.telegram.org", weight: 50 }
        ]
    },
    rutracker_suite: {
        name: "RuTracker Suite (HTTP / HTTPS)",
        urls: [
            { name: "Main Portal", url: "https://rutracker.org", weight: 60 },
            { name: "CDN Static Logo", url: "https://static.rutracker.cc/logo/logo-3.png", weight: 40 }
        ]
    }
};

const TARGET_URLS = {
    youtube_suite: "https://www.youtube.com",
    youtube: "https://www.youtube.com",
    youtube_web: "https://www.youtube.com",
    discord_suite: "https://discord.com/api/v9/gateway",
    discord: "https://discord.com/api/v9/gateway",
    twitch_suite: "https://www.twitch.tv",
    twitch: "https://www.twitch.tv",
    twitter_suite: "https://x.com",
    twitter: "https://x.com",
    chatgpt_suite: "https://chatgpt.com",
    chatgpt: "https://chatgpt.com",
    instagram_suite: "https://www.instagram.com",
    instagram: "https://www.instagram.com",
    rutracker_suite: "https://rutracker.org",
    rutracker: "https://rutracker.org",
    telegram_suite: "https://web.telegram.org",
    telegram: "https://web.telegram.org",
    quic_http3: "https://www.google.com"
};

// Strategy Matrices (Expanded Elite Production Suite)
const STRATEGIES_ZAPRET2 = [
    // ── 1. REAL-WORLD PRODUCTION CHAMPIONS (From Active Router Config) ─────────
    {
        id: "z2_paws_max_multisplit",
        name: "PAWS Spoofing (Max.ru, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_max:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max",
        description: "PAWS TCP timestamp evasion with authentic Max.ru ClientHello pattern overlap. Top-tier TSPU bypass."
    },
    {
        id: "z2_paws_google_multisplit",
        name: "PAWS Spoofing (Google, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google",
        description: "PAWS spoofing using authentic Google ClientHello blob and exact 681-byte sequence overlap."
    },
    {
        id: "z2_paws_gosuslugi_multisplit",
        name: "PAWS Spoofing (Gosuslugi Whitelist) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_gosuslugi:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_gosuslugi",
        description: "Mimics official Russian Government Gosuslugi portal ClientHello with PAWS RFC 7323 drop."
    },
    {
        id: "z2_paws_sber_multisplit",
        name: "PAWS Spoofing (Sberbank Whitelist) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_sber:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_sber",
        description: "Mimics Sberbank TLS ClientHello with ancient TCP timestamp."
    },
    {
        id: "z2_paws_iana_multisplit",
        name: "PAWS Spoofing (IANA Root) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_iana:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_iana",
        description: "Authentic IANA ClientHello with PAWS timestamp spoofing."
    },

    // ── 2. TCP SYN DATA SUITE ──────────────────────────────────────────────────
    {
        id: "z2_syndata_multidisorder",
        name: "TCP SYN Data + Multidisorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multidisorder:pos=1,midsld",
        description: "Injects payload into TCP SYN packet and disorders following segments. Bypasses stateful DPI."
    },
    {
        id: "z2_syndata_multisplit",
        name: "TCP SYN Data + Multisplit (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq",
        description: "Combines SYN data injection with segmented SNI payload and badseq fooling."
    },
    {
        id: "z2_syndata_wsize",
        name: "TCP SYN Data + Window Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=syndata --lua-desync=multisplit:pos=1,midsld:wsize=1",
        description: "SYN data payload followed by 1-byte TCP window segments."
    },

    // ── 3. DUAL-STAGE & COMPOSITE DESYNC SUITE ────────────────────────────────
    {
        id: "z2_dual_fake_max",
        name: "Dual Fake (STUN + Max.ru, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=stun_fake:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=fake:blob=tls_max:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max",
        description: "Consecutive fake STUN and TLS packets with PAWS timestamps before overlapped multisplit."
    },
    {
        id: "z2_fake_repeats8_multisplit",
        name: "Burst Fake (repeats=8, tcp_ts) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1,midsld:seqovl=2:fooling=badseq",
        description: "High-intensity 8-packet fake burst with PAWS timestamp before segmented payload."
    },

    // ── 4. YOUTUBE 4K & GOOGLEVIDEO STREAM CDN SUITE ───────────────────────────
    {
        id: "z2_yt_multisplit_midsld",
        name: "YouTube 4K Multisplit + MidSLD",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq",
        description: "Optimized for GoogleVideo 4K chunk streams and TSPU TLS desync."
    },
    {
        id: "z2_yt_multisplit_sniext",
        name: "SNI Extension Split + Badseq",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,sniext+4:seqovl=1:fooling=badseq",
        description: "Splits deep into SNI extensions to fool next-gen DPI signatures."
    },
    {
        id: "z2_aggressive_combo",
        name: "Aggressive Triple-Split + SeqOvl 2",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld,sniext+2:seqovl=2:fooling=badseq",
        description: "High-entropy triple fragmentation for heavily filtered regions."
    },
    {
        id: "z2_wsize_seqovl_combo",
        name: "Window Clamp (wsize=1) + SeqOvl",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:seqovl=1:fooling=badseq",
        description: "Combines 1-byte window clamp with sequence overlap."
    },
    {
        id: "z2_wsize_multisplit",
        name: "Window Size Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:fooling=badseq",
        description: "Forces single-byte TCP window segments to evade reassembly."
    },

    // ── 5. DISCORD FULL-STACK & VOICE/RTC SUITE ────────────────────────────────
    {
        id: "z2_discord_fullstack",
        name: "Discord Full-Stack Multi-Profile",
        engine: "zapret2",
        args: "--filter-tcp=443 --lua-desync=fake:blob=tls_max:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max --new --filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=tls_google:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google --new --filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=6",
        description: "Production multi-profile: HTTPS, alternate Cloudflare edge ports, and Discord Voice/STUN UDP."
    },
    {
        id: "z2_discord_udp",
        name: "Discord Voice UDP Desync",
        engine: "zapret2",
        args: "--filter-udp=19294-19344,50000-65535 --filter-l7=discord,stun --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=6",
        description: "UDP fake packet desync for Discord RTC and Voice channels."
    },
    {
        id: "z2_quic_http3_udp",
        name: "QUIC / HTTP3 UDP Fake Desync (Google Kyber)",
        engine: "zapret2",
        args: "--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11",
        description: "UDP fake desync using 1200-byte Google QUIC Initial blob with 11 repeats."
    },

    // ── 6. ADVANCED REORDER & FAKED SEGMENTS ────────────────────────────────────
    {
        id: "z2_fakedsplit_badseq",
        name: "Faked Split (pos=1,midsld) + BadSeq",
        engine: "zapret2",
        args: "--lua-desync=fakedsplit:pos=1,midsld:fooling=badseq",
        description: "Splits real stream and inserts fake packets between fragments."
    },
    {
        id: "z2_fakeddisorder",
        name: "Faked Disorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=fakeddisorder:pos=1,midsld:fooling=badseq",
        description: "Inserts out-of-order fake fragments with invalid sequence fooling."
    },
    {
        id: "z2_hostfakesplit",
        name: "Hostfake Split (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=hostfakesplit:pos=1,midsld:fooling=badseq",
        description: "Replaces host header/SNI in first split packet with dummy host."
    },
    {
        id: "z2_tcpseg_multisplit",
        name: "TCPSeg (size=40) + Multisplit (pos=midsld)",
        engine: "zapret2",
        args: "--lua-desync=tcpseg:size=40 --lua-desync=multisplit:pos=midsld:fooling=badseq",
        description: "Forces low TCP MSS segment size before mid-SLD desync."
    },
    {
        id: "z2_multidisorder_midsld",
        name: "Classic Multidisorder (pos=1,midsld)",
        engine: "zapret2",
        args: "--lua-desync=multidisorder:pos=1,midsld:fooling=badseq",
        description: "Sends out-of-order segments at start and mid-SLD with badseq fooling."
    },
    {
        id: "z2_split_pos1",
        name: "Classic Multisplit (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1:fooling=badseq",
        description: "Standard 2-fragment multisplit desync for compatibility."
    },
    {
        id: "z2_disorder_pos1",
        name: "Classic Multidisorder (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=multidisorder:pos=1:fooling=badseq",
        description: "Sends out-of-order segment with badseq fooling."
    },

    // ── 7. LOW-TTL ADAPTIVE MATRIX ─────────────────────────────────────────────
    {
        id: "z2_fake_ttl3_md5sig",
        name: "Fake (TTL=3, MD5Sig) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=3:fooling=md5sig --lua-desync=multisplit:pos=1,midsld",
        description: "Aggressive low-TTL MD5Sig injection for close TSPU hops."
    },
    {
        id: "z2_fake_ttl4_badseq",
        name: "Fake (TTL=4, BadSeq) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=4:fooling=badseq --lua-desync=multisplit:pos=1,midsld",
        description: "Low-TTL fake ClientHello with badseq fooling and multisplit segmentation."
    },
    {
        id: "z2_fake_ttl5_md5sig",
        name: "Fake (TTL=5, MD5Sig) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=5:fooling=md5sig --lua-desync=multisplit:pos=1,midsld",
        description: "MD5Sig TCP option drops packet at DPI while reaching end server."
    },
    {
        id: "z2_fake_ttl6_badack",
        name: "Fake (TTL=6, BadACK) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=6:fooling=badack --lua-desync=multisplit:pos=1,sniext+2",
        description: "BadACK fooling invalidates packet in DPI state tracking."
    },
    {
        id: "z2_fake_badseq_mid",
        name: "Fake Packet (TTL=8) + MidSLD Split",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=badseq --lua-desync=multisplit:pos=midsld",
        description: "Injects fake ClientHello before segmented payload."
    },
    {
        id: "z2_fake_datanoack",
        name: "Fake (TTL=8, DataNoAck) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=datanoack --lua-desync=multisplit:pos=1",
        description: "DataNoAck fooling confuses stateful DPI without triggering ACK RST."
    },
    {
        id: "z2_oob_pos1",
        name: "OOB Out-of-Band Data (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=oob:pos=1",
        description: "TCP Out-Of-Band URG flag packet to desynchronize DPI reassembly."
    }
];

const STRATEGIES_ZAPRET = [
    {
        id: "z1_split2_pos2",
        name: "Standard Split2 (pos=2)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=2",
        description: "Base HTTP/TLS split inside SNI header."
    },
    {
        id: "z1_split2_pos1",
        name: "Standard Split2 (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-pos=1",
        description: "1-byte TLS ClientHello split."
    },
    {
        id: "z1_disorder2_badseq",
        name: "Disorder2 + BadSeq (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq",
        description: "Sends out-of-order packets with invalid TCP sequence fooling."
    },
    {
        id: "z1_disorder2_midsld",
        name: "Disorder2 + MidSLD (pos=midsld)",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=midsld --dpi-desync-fooling=badseq",
        description: "Disorders stream in the middle of second-level domain name."
    },
    {
        id: "z1_fake_split2_ttl8",
        name: "Fake SNI + Split2 (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends TTL=8 fake packet followed by segmented ClientHello."
    },
    {
        id: "z1_fake_split2_ttl6",
        name: "Fake SNI + Split2 (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Sends TTL=6 fake packet for closer TSPU hops."
    },
    {
        id: "z1_fake_split2_ttl4",
        name: "Fake SNI + Split2 (TTL=4)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=4 --dpi-desync-fooling=badseq",
        description: "Low TTL=4 fake packet for nearest TSPU filters."
    },
    {
        id: "z1_fake_disorder2_ttl8",
        name: "Fake SNI + Disorder2 (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends fake packet and disorders real segments."
    },
    {
        id: "z1_seqovl_split2_1",
        name: "Sequence Overlap (SeqOvl=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=1 --dpi-desync-fooling=badseq",
        description: "1-byte overlapping TCP payload to confuse stateful DPI."
    },
    {
        id: "z1_seqovl_split2_2",
        name: "Sequence Overlap (SeqOvl=2)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=2 --dpi-desync-fooling=badseq",
        description: "2-byte overlapping TCP payload for aggressive DPI desync."
    },
    {
        id: "z1_seqovl_split2_336",
        name: "Deep Sequence Overlap (SeqOvl=336)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=336 --dpi-desync-fooling=badseq",
        description: "336-byte full SNI overlap to overwrite ClientHello in DPI reassembly."
    },
    {
        id: "z1_md5sig_disorder",
        name: "MD5Sig Fooling + Disorder (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-fooling=md5sig --dpi-desync-ttl=6",
        description: "Injects TCP MD5 signature option to trigger DPI packet drop."
    },
    {
        id: "z1_badack_disorder",
        name: "BadACK Fooling + Disorder (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-fooling=badack --dpi-desync-ttl=8",
        description: "Injects BadACK sequence to break TCP state tracking."
    },
    {
        id: "z1_fake_midsld_split",
        name: "Fake + MidSLD Split (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=midsld --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Splits in middle of domain name with fake injection."
    },
    {
        id: "z1_cutoff_fake_split",
        name: "Cutoff d4 + Fake,Split2 (TTL=6)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-cutoff=d4 --dpi-desync-ttl=6 --dpi-desync-fooling=badseq",
        description: "Stops desync after 4 server data packets to preserve CPU and performance."
    },
    {
        id: "z1_repeats_fake_split",
        name: "Burst Repeats=6 Fake + Split2 (pos=1)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends 6 consecutive fake packets to saturate DPI connection tracking."
    }
];

const STRATEGIES_BYEDPI = [
    {
        id: "bd_auto_tr_d2",
        name: "ByeDPI Auto (t,r,a,s) + Disorder",
        engine: "byedpi",
        args: "-o 2 --auto=t,r,a,s -d 2",
        description: "Adaptive ByeDPI auto-mode with disorder and OOB."
    },
    {
        id: "bd_auto_tr_s1",
        name: "ByeDPI Auto (t,r,a,s) + Split",
        engine: "byedpi",
        args: "-o 1 --auto=t,r,a,s -s 1",
        description: "Adaptive ByeDPI auto-mode with 1-byte split."
    },
    {
        id: "bd_auto_drop_sack",
        name: "Auto (t,r,s) + Split 1 + Drop SACK",
        engine: "byedpi",
        args: "-s 1 -d 1 --auto=t,r,s --drop-sack",
        description: "Enforces drop-sack to prevent TCP SACK reassembly by DPI."
    },
    {
        id: "bd_disorder_fake_ttl8",
        name: "Disorder + Fake (TTL=8)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 8",
        description: "1-byte split with reverse disorder and fake handshake packet."
    },
    {
        id: "bd_disorder_fake_ttl6",
        name: "Disorder + Fake (TTL=6)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 6",
        description: "1-byte split with fake TTL=6 for intermediate hops."
    },
    {
        id: "bd_disorder_fake_ttl4",
        name: "Disorder + Fake (TTL=4)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 4",
        description: "1-byte split with low fake TTL=4."
    },
    {
        id: "bd_midsld_fake_frag_t6",
        name: "SNI Extension + Fake (TTL=6)",
        engine: "byedpi",
        args: "-s 1+sniext -f -1 -t 6",
        description: "SNI extension split with low-TTL fake payload."
    },
    {
        id: "bd_midsld_fake_frag_t8",
        name: "SNI Extension + Fake (TTL=8)",
        engine: "byedpi",
        args: "-s 1+sniext -f -1 -t 8",
        description: "SNI extension split with fake TTL=8."
    },
    {
        id: "bd_tls_sni_split2",
        name: "TLS SNI Split + Disorder (pos=2)",
        engine: "byedpi",
        args: "--split 2 --disorder 2",
        description: "Direct TLS SNI offset split with out-of-order delivery."
    },
    {
        id: "bd_tls_sni_split1",
        name: "TLS SNI Split + Disorder (pos=1)",
        engine: "byedpi",
        args: "--split 1 --disorder 1",
        description: "1-byte TLS ClientHello split with disorder."
    },
    {
        id: "bd_tlsrec_sniext",
        name: "TLS Record Split (1+sniext)",
        engine: "byedpi",
        args: "--tlsrec 1+sniext --split 1",
        description: "Fragments TLS Record header before SNI extension."
    },
    {
        id: "bd_fake_sni_disorder",
        name: "Fake SNI (-N) + Disorder",
        engine: "byedpi",
        args: "-N -s 1 -d 1 --auto=t,r,s",
        description: "Replaces SNI with fake random domain and disorders payload."
    },
    {
        id: "bd_ip_frag_24",
        name: "IP Fragmentation (24 bytes)",
        engine: "byedpi",
        args: "--ip-frag 24 --split 1",
        description: "Network layer IP fragmentation on 24-byte boundary."
    },
    {
        id: "bd_fake_sniext_disorder",
        name: "Aggressive Fake (TTL=8) + SNIExt",
        engine: "byedpi",
        args: "--fake -1 --ttl 8 --split 1+sniext --disorder 1",
        description: "Fake handshake with SNI extension split and disorder."
    },
    {
        id: "bd_aggressive_combo",
        name: "Aggressive Multi-Desync (-s 1 -d 1 -o 1 -q 1)",
        engine: "byedpi",
        args: "-s 1 -d 1 -o 1 -q 1 --auto=t,r,s --drop-sack",
        description: "Combines split, disorder, OOB, and drop-sack for tough censorship."
    }
];

function generate_combinatorial_zapret2() {
    let cfg = get_patterns_config();
    let p = cfg.zapret2 || DEFAULT_PATTERNS.zapret2;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!validate_strategy_args("zapret2", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("z2_comb_%d", length(list) + 1),
            name: name,
            engine: "zapret2",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_ZAPRET2) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "zapret2" && cs.args) {
                add(cs.name || "Custom Zapret v2", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let splits = p.splits || [ "1", "2", "3", "midsld", "sniext+2", "sniext+4", "1,midsld", "1,sniext+2" ];
    let foolings = p.foolings || [ "badseq", "md5sig", "badack", "datanoack", "fakeddrop" ];
    let ttls = p.ttls || [ 2, 3, 4, 5, 6, 8 ];
    let seqovls = p.seqovls || [ "1", "2" ];
    let wsizes = p.wsizes || [ "1" ];
    let blobs = p.blobs || [ "tls_max", "tls_google", "tls_gosuslugi", "tls_sber", "tls_iana" ];
    let repeats_list = p.repeats || [ 6, 8 ];
    
    // 1. Multisplit combinations
    for (let pos in splits) {
        for (let fooling in foolings) {
            add(sprintf("Multisplit (pos=%s, %s)", pos, fooling),
                sprintf("--lua-desync=multisplit:pos=%s:fooling=%s", pos, fooling),
                "Multisplit position and fooling method");
        }
        for (let sq in seqovls) {
            add(sprintf("Multisplit + SeqOvl %s (pos=%s, badseq)", sq, pos),
                sprintf("--lua-desync=multisplit:pos=%s:seqovl=%s:fooling=badseq", pos, sq),
                "Multisplit with sequence overlap");
        }
        for (let w in wsizes) {
            add(sprintf("Multisplit + Window %s (pos=%s, badseq)", w, pos),
                sprintf("--lua-desync=multisplit:pos=%s:wsize=%s:fooling=badseq", pos, w),
                "Multisplit with TCP window size clamping");
        }
    }
    
    // 2. Multidisorder combinations
    for (let pos in [ "1", "2", "midsld", "1,midsld" ]) {
        for (let fooling in [ "badseq", "md5sig", "badack" ]) {
            add(sprintf("Multidisorder (pos=%s, %s)", pos, fooling),
                sprintf("--lua-desync=multidisorder:pos=%s:fooling=%s", pos, fooling),
                "Out-of-order segment delivery with fooling");
        }
    }
    
    // 3. PAWS Timestamp Spoofing with Authentic Blobs (Top-tier TSPU evasion)
    for (let blob in blobs) {
        for (let rep in repeats_list) {
            for (let pos in [ "1", "1,midsld", "midsld" ]) {
                add(sprintf("Fake PAWS (%s, rep=%d) + Multisplit (pos=%s)", blob, rep, pos),
                    sprintf("--lua-desync=fake:blob=%s:repeats=%d:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=%s", blob, rep, pos),
                    "PAWS ancient TCP timestamp spoofing with authentic ClientHello blob");
                add(sprintf("Fake PAWS (%s, rep=%d) + Multidisorder (pos=%s)", blob, rep, pos),
                    sprintf("--lua-desync=fake:blob=%s:repeats=%d:tcp_ts=-600000:tcp_ts_up --lua-desync=multidisorder:pos=%s", blob, rep, pos),
                    "PAWS ancient TCP timestamp spoofing with multidisorder segments");
            }
        }
    }
    
    // 4. Exact SeqOvl Pattern Overlaps
    let blob_patterns = [
        { name: "tls_max", size: 664 },
        { name: "tls_google", size: 681 },
        { name: "tls_gosuslugi", size: 517 },
        { name: "tls_sber", size: 517 }
    ];
    for (let bp in blob_patterns) {
        add(sprintf("SeqOvl Pattern %s (%d B, pos=1)", bp.name, bp.size),
            sprintf("--lua-desync=multisplit:pos=1:seqovl=%d:seqovl_pattern=%s", bp.size, bp.name),
            "Sequence overlap filled with authentic ClientHello pattern");
        add(sprintf("Fake PAWS (%s) + SeqOvl Pattern (%d B)", bp.name, bp.size),
            sprintf("--lua-desync=fake:blob=%s:repeats=8:tcp_ts=-600000:tcp_ts_up --lua-desync=multisplit:pos=1:seqovl=%d:seqovl_pattern=%s", bp.name, bp.size, bp.name),
            "Combined PAWS fake burst and pattern sequence overlap");
    }
    
    // 5. TCP SYN Data combinations
    for (let pos in [ "1", "1,midsld", "midsld" ]) {
        add(sprintf("SYN Data + Multidisorder (pos=%s)", pos),
            sprintf("--lua-desync=syndata --lua-desync=multidisorder:pos=%s", pos),
            "TCP SYN data payload with out-of-order data segments");
        add(sprintf("SYN Data + Multisplit (pos=%s, seqovl=1)", pos),
            sprintf("--lua-desync=syndata --lua-desync=multisplit:pos=%s:seqovl=1:fooling=badseq", pos),
            "TCP SYN data payload with multisplit sequence overlap");
        add(sprintf("SYN Data + Window Clamp (wsize=1, pos=%s)", pos),
            sprintf("--lua-desync=syndata --lua-desync=multisplit:pos=%s:wsize=1:fooling=badseq", pos),
            "TCP SYN data payload with 1-byte window clamp");
    }
    
    // 6. Low-TTL Fake combinations
    for (let ttl in ttls) {
        for (let fooling in [ "badseq", "md5sig", "badack" ]) {
            for (let pos in [ "1", "1,midsld", "midsld" ]) {
                add(sprintf("Fake (TTL=%d, %s) + Multisplit (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=multisplit:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by multisplit payload");
                add(sprintf("Fake (TTL=%d, %s) + Multidisorder (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=multidisorder:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by multidisorder payload");
            }
        }
    }
    
    // 7. Fakedsplit, Fakeddisorder & Hostfakesplit
    for (let pos in [ "1", "1,midsld", "midsld" ]) {
        add(sprintf("Fakedsplit (pos=%s, badseq)", pos),
            sprintf("--lua-desync=fakedsplit:pos=%s:fooling=badseq", pos),
            "Stream splitting with embedded fake packets");
        add(sprintf("Fakeddisorder (pos=%s, badseq)", pos),
            sprintf("--lua-desync=fakeddisorder:pos=%s:fooling=badseq", pos),
            "Out-of-order stream with embedded fake fragments");
        add(sprintf("Hostfakesplit (pos=%s, badseq)", pos),
            sprintf("--lua-desync=hostfakesplit:pos=%s:fooling=badseq", pos),
            "Host header substitution in initial packet");
    }
    
    return list;
}

function generate_combinatorial_zapret() {
    let cfg = get_patterns_config();
    let p = cfg.zapret || DEFAULT_PATTERNS.zapret;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!validate_strategy_args("zapret", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("z1_gen_%d", length(list) + 1),
            name: name,
            engine: "zapret",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_ZAPRET) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "zapret" && cs.args) {
                add(cs.name || "Custom Zapret v1", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let modes = p.split_modes || [ "split2", "disorder2", "fake,split2", "fake,disorder2" ];
    let positions = p.splits || [ "1", "2", "midsld" ];
    
    for (let mode in modes) {
        for (let pos in positions) {
            for (let fooling in [ "badseq", "md5sig", "badack" ]) {
                if (index(mode, "fake") >= 0) {
                    for (let ttl in [ 3, 4, 8 ]) {
                        add(sprintf("%s (pos=%s, TTL=%d, %s)", mode, pos, ttl, fooling),
                            sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-ttl=%d --dpi-desync-fooling=%s", mode, pos, ttl, fooling),
                            "Fake desync with split pos and fooling");
                    }
                } else {
                    add(sprintf("%s (pos=%s, %s)", mode, pos, fooling),
                        sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-fooling=%s", mode, pos, fooling),
                        "Desync with split pos and fooling");
                }
            }
        }
    }
    
    return list;
}

function generate_combinatorial_byedpi() {
    let cfg = get_patterns_config();
    let p = cfg.byedpi || DEFAULT_PATTERNS.byedpi;
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!validate_strategy_args("byedpi", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("bd_gen_%d", length(list) + 1),
            name: name,
            engine: "byedpi",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_BYEDPI) add(s.name, s.args, s.description);
    
    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && cs.engine == "byedpi" && cs.args) {
                add(cs.name || "Custom ByeDPI", cs.args, cs.description || "User custom strategy");
            }
        }
    }
    
    let splits = p.splits || [ "1", "2", "1+sniext", "midsld" ];
    let disorders = p.disorders || [ "1", "2" ];
    let oobs = p.oobs || [ "1", "2" ];
    let autos = p.autos || [ "t,r,a,s", "r,s", "t,a" ];
    
    for (let a in autos) {
        for (let o in oobs) {
            for (let d in disorders) {
                add(sprintf("Auto (%s) + OOB=%s + Disorder=%s", a, o, d),
                    sprintf("-o %s --auto=%s -d %s", o, a, d),
                    "Adaptive auto mode with OOB and disorder");
            }
            for (let s in splits) {
                add(sprintf("Auto (%s) + OOB=%s + Split=%s", a, o, s),
                    sprintf("-o %s --auto=%s -s %s", o, a, s),
                    "Adaptive auto mode with OOB and split");
            }
        }
    }
    
    for (let ttl in [ 3, 4, 8 ]) {
        for (let s in [ "1", "1+sniext", "midsld" ]) {
            for (let d in [ "1", "2" ]) {
                add(sprintf("Split=%s + Disorder=%s + Fake (TTL=%d)", s, d, ttl),
                    sprintf("--split %s --disorder %s --fake -1 --ttl %d", s, d, ttl),
                    "Fake injection with split and disorder");
            }
        }
    }
    
    return list;
}

function get_strategies_for_engine(engine, mode) {
    engine = lc(as_string(engine));
    mode = lc(trim(as_string(mode || "presets")));
    let cfg = get_patterns_config();
    
    if (mode == "custom" || mode == "user") {
        let custom_list = [];
        for (let cs in cfg.custom_strategies) {
            if (cs && (engine == "all" || cs.engine == engine) && cs.args) {
                push(custom_list, {
                    id: cs.id || sprintf("custom_%d", length(custom_list) + 1),
                    name: cs.name || "Custom Strategy",
                    engine: cs.engine || engine,
                    args: cs.args,
                    description: cs.description || ""
                });
            }
        }
        return custom_list;
    }
    
    if (mode == "combinatorial" || mode == "deep_fuzz" || mode == "deep") {
        if (engine == "zapret2") return generate_combinatorial_zapret2();
        if (engine == "zapret") return generate_combinatorial_zapret();
        if (engine == "byedpi") return generate_combinatorial_byedpi();
        if (engine == "all") {
            let combined = [];
            for (let s in generate_combinatorial_zapret2()) push(combined, s);
            for (let s in generate_combinatorial_zapret()) push(combined, s);
            for (let s in generate_combinatorial_byedpi()) push(combined, s);
            return combined;
        }
    }
    
    let base = [];
    if (engine == "zapret2") base = STRATEGIES_ZAPRET2;
    else if (engine == "zapret") base = STRATEGIES_ZAPRET;
    else if (engine == "byedpi") base = STRATEGIES_BYEDPI;
    else if (engine == "all") {
        for (let s in STRATEGIES_ZAPRET2) push(base, s);
        for (let s in STRATEGIES_ZAPRET) push(base, s);
        for (let s in STRATEGIES_BYEDPI) push(base, s);
    }
    
    let result = [];
    for (let s in base) push(result, s);
    for (let cs in cfg.custom_strategies) {
        if (cs && (engine == "all" || cs.engine == engine) && cs.args) {
            push(result, {
                id: cs.id || sprintf("custom_%d", length(result) + 1),
                name: cs.name || "Custom Strategy",
                engine: cs.engine || engine,
                args: cs.args,
                description: cs.description || "User custom strategy"
            });
        }
    }
    
    return result;
}

function resolve_target_url(target_key, custom_url) {
    if (custom_url && custom_url != "")
        return custom_url;
    return TARGET_URLS[target_key] || TARGET_URLS.youtube;
}

function resolve_target_urls_list(target_key, custom_url) {
    if (custom_url && custom_url != "") {
        return [ { name: "Custom Target", url: custom_url, weight: 100 } ];
    }
    target_key = as_string(target_key || "youtube_suite");
    let suite = TARGET_SUITES[target_key];
    if (suite && suite.urls && length(suite.urls) > 0) {
        return suite.urls;
    }
    let single = TARGET_URLS[target_key] || TARGET_URLS.youtube;
    return [ { name: target_key, url: single, weight: 100 } ];
}

function ensure_state_dir() {
    common.ensure_dir(STATE_DIR);
}

function save_fuzzer_state(state) {
    ensure_state_dir();
    common.write_json_file(STATE_FILE, state);
}

function safe_json_parse(str) {
    if (!str || str == "") return null;
    let obj = null;
    try {
        obj = json(str);
    } catch (e) {
        obj = null;
    }
    return obj;
}

function query_llm(provider, api_key, custom_url, prompt_text, model_override) {
    provider = lc(trim(as_string(provider || "openai")));
    model_override = trim(as_string(model_override || ""));

    if (provider == "anthropic" || provider == "claude") {
        let api_url = "https://api.anthropic.com/v1/messages";
        let model = model_override != "" ? model_override : "claude-3-5-haiku-20241022";
        let body = {
            model,
            max_tokens: 1000,
            messages: [{ role: "user", content: prompt_text }]
        };
        let cmd = sprintf(
            "curl -s -m 35 --connect-timeout 10 -X POST -H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d %s %s 2>/dev/null",
            shell_quote(api_key),
            shell_quote(sprintf("%J", body)),
            shell_quote(api_url)
        );
        let pipe = fs.popen(cmd, "r");
        let output = pipe ? pipe.read("all") : "";
        if (pipe) pipe.close();
        let parsed = safe_json_parse(output);
        if (parsed && parsed.content && type(parsed.content) == "array" && length(parsed.content) > 0) {
            return parsed.content[0].text;
        }
        return null;
    }

    let base_url = "https://api.openai.com/v1";
    let default_model = "gpt-4o-mini";
    if (provider == "deepseek") {
        base_url = "https://api.deepseek.com/v1";
        default_model = "deepseek-chat";
    } else if (provider == "openrouter") {
        base_url = "https://openrouter.ai/api/v1";
        default_model = "deepseek/deepseek-chat";
    } else if (provider == "ollama") {
        base_url = custom_url && custom_url != "" ? custom_url : "http://127.0.0.1:11434/v1";
        default_model = "llama3.2";
    } else if (provider == "lmstudio" || provider == "custom") {
        base_url = custom_url && custom_url != "" ? custom_url : "http://127.0.0.1:1234/v1";
        default_model = "local-model";
    }

    base_url = replace(base_url, /\/+$/, "");
    let api_url = base_url + "/chat/completions";
    let model = model_override != "" ? model_override : default_model;
    let body = {
        model,
        messages: [
            { role: "system", content: "You are a network censorship and DPI bypass expert. Always return responses formatted strictly as requested." },
            { role: "user", content: prompt_text }
        ],
        temperature: 0.3
    };

    let auth_header = api_key != "" ? sprintf("-H 'Authorization: Bearer %s'", api_key) : "";
    let cmd = sprintf(
        "curl -s -m 35 --connect-timeout 10 -X POST %s -H 'Content-Type: application/json' -d %s %s 2>/dev/null",
        auth_header,
        shell_quote(sprintf("%J", body)),
        shell_quote(api_url)
    );
    let pipe = fs.popen(cmd, "r");
    let output = pipe ? pipe.read("all") : "";
    if (pipe) pipe.close();
    let parsed = safe_json_parse(output);
    if (parsed && parsed.choices && type(parsed.choices) == "array" && length(parsed.choices) > 0) {
        let msg = parsed.choices[0].message;
        if (msg && msg.content) {
            return msg.content;
        }
    }
    return null;
}

function parse_llm_json(raw_text) {
    raw_text = trim(as_string(raw_text));
    if (raw_text == "") return null;
    let direct = safe_json_parse(raw_text);
    if (direct && type(direct) == "object") return direct;

    let m = match(raw_text, /```json\s*([\s\S]*?)\s*```/);
    if (m && m[1]) {
        let parsed = safe_json_parse(m[1]);
        if (parsed && type(parsed) == "object") return parsed;
    }

    m = match(raw_text, /\{[\s\S]*\}/);
    if (m && m[0]) {
        let parsed = safe_json_parse(m[0]);
        if (parsed && type(parsed) == "object") return parsed;
    }
    return null;
}

function synthesize_ai_strategies(engine, target, custom_url, user_prompt) {
    let current = get_fuzzer_state();
    if (current.running) {
        print(sprintf("%J\n", { success: false, error: "Fuzzer is currently running a benchmark" }));
        return;
    }

    engine = lc(as_string(engine || "zapret2"));
    target = trim(as_string(target || "youtube_suite"));
    user_prompt = trim(as_string(user_prompt || ""));
    let target_url = resolve_target_url(target, custom_url);

    let baseline = run_probe(engine, "", target, custom_url);

    let query_text = sprintf("%s %s %s", engine, target, user_prompt);
    let rag_docs = rag.retrieve(query_text, 4);

    let uci = uci_core.cursor();
    let ai_sec = uci.get_all(CONFIG_NAME, "ai") || {};
    let provider = ai_sec.provider || "openai";
    let api_key = ai_sec.api_key || "";
    let ai_custom_url = ai_sec.custom_url || "";
    let model_override = ai_sec.model || "";

    let prompt = sprintf(
        "You are an expert DPI Bypass Engineer specializing in OpenWrt, Zapret, Zapret2 (nfqws2), and ByeDPI (ciadpi).\n" +
        "We need to bypass censorship / TSPU blocking for target service '%s' (%s) using engine '%s'.\n\n" +
        "LIVE PROBE DIAGNOSTICS:\n" +
        "- Direct HTTP Code: %d\n" +
        "- Connect Time: %d ms\n" +
        "- TTFB: %d ms\n" +
        "- Probe Error: %s\n" +
        "- User Notes / ISP Context: %s\n\n" +
        "TECHNICAL KNOWLEDGE BASE FRAGMENTS:\n%s\n\n" +
        "TASK:\n" +
        "1. Analyze why this target is blocked or throttled.\n" +
        "2. Formulate 3 to 5 highly effective, syntactically valid DPI desync strategies for '%s'.\n" +
        "3. Output MUST be strictly valid JSON matching this schema:\n" +
        "{\n" +
        '  "analysis": "Brief 1-2 sentence diagnosis of the blocking pattern",\n' +
        '  "strategies": [\n' +
        '    {\n' +
        '      "id": "ai_strat_1",\n' +
        '      "name": "Human-readable descriptive strategy name",\n' +
        '      "args": "Exact command-line arguments string for the engine",\n' +
        '      "description": "Why this combination should bypass the block"\n' +
        '    }\n' +
        '  ]\n' +
        "}\n\n" +
        "RULES FOR STRATEGY ARGS:\n" +
        "- For zapret2: use valid options like '--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq' or '--lua-desync=fake:ttl=4:fooling=badseq --lua-desync=multisplit:pos=1,midsld'. DO NOT include binary name.\n" +
        "- For zapret: use valid options like '--dpi-desync=fake,split2 --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-ttl=4'. DO NOT include binary name.\n" +
        "- For byedpi: use valid options like '-s 1 -d 1 --auto=t,r,s -o 1'. DO NOT include binary name.\n\n" +
        "JSON OUTPUT:",
        target, target_url, engine,
        baseline.http_code, baseline.handshake_ms, baseline.ttfb_ms,
        baseline.error != "" ? baseline.error : "none",
        user_prompt != "" ? user_prompt : "None provided",
        rag_docs,
        engine
    );

    let raw_reply = query_llm(provider, api_key, ai_custom_url, prompt, model_override);
    if (!raw_reply) {
        print(sprintf("%J\n", {
            success: false,
            error: "Failed to receive response from AI provider. Check API key and network connectivity."
        }));
        return;
    }

    let parsed_json = parse_llm_json(raw_reply);
    if (!parsed_json || !parsed_json.strategies || type(parsed_json.strategies) != "array" || length(parsed_json.strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "AI returned non-JSON or invalid format",
            raw_response: raw_reply
        }));
        return;
    }

    let valid_strategies = [];
    for (let i = 0; i < length(parsed_json.strategies); i++) {
        let st = parsed_json.strategies[i];
        if (st && st.args && validate_strategy_args(engine, st.args)) {
            push(valid_strategies, {
                id: st.id || sprintf("ai_strat_%d", i + 1),
                name: st.name || sprintf("AI Strategy %d", i + 1),
                engine,
                args: trim(st.args),
                description: st.description || ""
            });
        }
    }

    if (length(valid_strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "All AI strategies failed syntax validation for engine " + engine,
            raw_strategies: parsed_json.strategies
        }));
        return;
    }

    let custom_file = STATE_DIR + "/fuzzer_ai_strategies.json";
    ensure_state_dir();
    common.write_json_file(custom_file, valid_strategies);

    print(sprintf("%J\n", {
        success: true,
        engine,
        target,
        target_url,
        analysis: parsed_json.analysis || "AI strategy synthesis complete",
        strategies: valid_strategies,
        custom_file
    }));
}

function get_fuzzer_state() {
    let state = common.read_json_file(STATE_FILE);
    if (!state || type(state) != "object") {
        return {
            running: false,
            job_id: null,
            engine: "zapret2",
            target: "youtube_suite",
            progress_pct: 0,
            current_index: 0,
            total_strategies: 0,
            current_strategy: null,
            results: [],
            best_strategy: null,
            error: null,
            started_at: 0,
            finished_at: 0
        };
    }
    return state;
}

function kill_pid_file(path) {
    let pid_str = fs.readfile(path);
    if (pid_str) {
        let pid = trim(as_string(pid_str));
        if (pid != "") {
            system(sprintf("kill %s >/dev/null 2>&1 || kill -9 %s >/dev/null 2>&1", pid, pid));
        }
        try { fs.unlink(path); } catch (e) {}
    }
}

function cleanup_temp_daemons() {
    kill_pid_file(STATE_DIR + "/fuzzer_byedpi.pid");
    kill_pid_file(STATE_DIR + "/fuzzer_zapret.pid");
    kill_pid_file(STATE_DIR + "/fuzzer_zapret2.pid");
    system("nft delete table inet tachyon_fuzzer 2>/dev/null");
    try { fs.unlink(STATE_DIR + "/fuzzer_daemon_err.log"); } catch (e) {}
}

function parse_curl_output(output, result) {
    result = result || {};
    output = trim(as_string(output));
    if (output == "") {
        result.success = false;
        result.http_code = 0;
        result.handshake_ms = 0;
        result.ttfb_ms = 0;
        result.speed_kbps = 0;
        result.score = 0;
        result.error = "Probe timeout or connection refused";
        return result;
    }
    
    let parts = split(output, "\t");
    if (length(parts) < 4) {
        result.success = false;
        result.http_code = 0;
        result.score = 0;
        result.error = "Malformed probe metrics output";
        return result;
    }
    
    let http_code = int(parts[0]);
    let appconnect = double(parts[1]);
    let starttransfer = double(parts[2]);
    let speed_bytes = double(parts[3]);
    
    result.http_code = http_code;
    result.handshake_ms = int(appconnect * 1000.0);
    result.ttfb_ms = int(starttransfer * 1000.0);
    result.speed_kbps = int(speed_bytes / 1024.0);
    
    // Any valid HTTP response from origin (including 401/403/404/405 when hitting endpoints without auth headers)
    // proves that TCP handshake, TLS ClientHello, and HTTP negotiation successfully reached the remote server past TSPU.
    if ((http_code >= 200 && http_code < 400) || http_code == 401 || http_code == 403 || http_code == 404 || http_code == 405) {
        result.success = true;
        let base_score = (http_code >= 200 && http_code < 400) ? 100 : 85;
        let latency_score = max(0, 1000 - result.ttfb_ms);
        let speed_score = int(result.speed_kbps / 10.0);
        result.score = base_score + latency_score + speed_score;
        result.error = "";
    } else {
        result.success = false;
        result.score = 0;
        result.error = http_code > 0 ? sprintf("HTTP Status %d", http_code) : "Connection dropped by DPI";
    }
    
    return result;
}

// ── DPI Type Detection ──────────────────────────────────────────────────────
// Probes the target without any bypass to determine how it's being blocked.
// Returns: { type: "rst"|"throttle"|"dns_block"|"unknown"|"none",
//            confidence: 0-100, details: string, recommended_engines: string[] }
function detect_dpi_type(target_key, custom_url) {
    let urls_list = resolve_target_urls_list(target_key, custom_url);
    let target_url = urls_list[0] ? urls_list[0].url : "https://www.google.com";
    let dns_flags = get_fuzzer_curl_dns_flags();

    let result = {
        type: "unknown",
        confidence: 0,
        details: "",
        recommended_engines: [],
        probe_metrics: { http_code: 0, handshake_ms: 0, ttfb_ms: 0, speed_kbps: 0, error: "" }
    };

    // Direct probe with bypass of Sing-box TProxy
    system("nft add table inet tachyon_fuzzer 2>/dev/null");
    system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
    system("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443 } meta mark set meta mark | 0x00200000 counter' 2>/dev/null");

    let curl_cmd = sprintf(
        "curl %s-so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}' -L --connect-timeout 4 --max-time 6 %s 2>&1",
        dns_flags,
        shell_quote(target_url)
    );
    let pipe = fs.popen(curl_cmd, "r");
    let output = pipe ? pipe.read("all") : "";
    if (pipe) pipe.close();
    output = trim(output);

    cleanup_temp_daemons();

    let metrics = {};
    parse_curl_output(output, metrics);
    result.probe_metrics = {
        http_code: metrics.http_code || 0,
        handshake_ms: metrics.handshake_ms || 0,
        ttfb_ms: metrics.ttfb_ms || 0,
        speed_kbps: metrics.speed_kbps || 0,
        error: metrics.error || ""
    };

    // Also check for DNS-level blocking
    let domain = target_url;
    let dm = match(domain, /https?:\/\/([^/]+)/);
    if (dm && dm[1]) domain = dm[1];

    let dns_cmd = sprintf("nslookup %s 2>&1", shell_quote(domain));
    let dns_pipe = fs.popen(dns_cmd, "r");
    let dns_out = dns_pipe ? dns_pipe.read("all") : "";
    if (dns_pipe) dns_pipe.close();

    let dns_blocked = false;
    if (index(dns_out, "NXDOMAIN") >= 0 || index(dns_out, "can't resolve") >= 0 || index(dns_out, "** server can't find") >= 0) {
        dns_blocked = true;
    }

    // Analyze failure patterns
    let http_code = metrics.http_code || 0;
    let handshake = metrics.handshake_ms || 0;
    let ttfb = metrics.ttfb_ms || 0;
    let error_str = metrics.error || "";

    if (dns_blocked) {
        result.type = "dns_block";
        result.confidence = 90;
        result.details = sprintf("DNS resolution failed for %s — likely DNS-level blocking or hijacking", domain);
        result.recommended_engines = ["byedpi", "zapret2"];
    } else if (index(error_str, "Connection reset") >= 0 || index(error_str, "ECONNRESET") >= 0) {
        result.type = "rst";
        result.confidence = 85;
        result.details = sprintf("TCP RST received from DPI — active TCP reset injection detected");
        result.recommended_engines = ["zapret2", "zapret"];
    } else if (http_code == 0 || index(error_str, "Connection refused") >= 0 || index(error_str, "ECONNREFUSED") >= 0) {
        result.type = "rst";
        result.confidence = 70;
        result.details = sprintf("Connection refused — likely RST or blackhole by DPI");
        result.recommended_engines = ["zapret2", "zapret"];
    } else if (http_code >= 400 && http_code < 500) {
        result.type = "throttle";
        result.confidence = 60;
        result.details = sprintf("HTTP %d returned — DPI may be injecting HTTP errors or throttling", http_code);
        result.recommended_engines = ["zapret2", "byedpi"];
    } else if (handshake > 2000) {
        result.type = "throttle";
        result.confidence = 75;
        result.details = sprintf("Very slow TLS handshake (%dms) — likely DPI deep inspection causing delay", handshake);
        result.recommended_engines = ["zapret2", "zapret"];
    } else if (ttfb > 3000 && http_code >= 200 && http_code < 400) {
        result.type = "throttle";
        result.confidence = 65;
        result.details = sprintf("High TTFB (%dms) despite successful connection — likely bandwidth throttling", ttfb);
        result.recommended_engines = ["zapret2", "byedpi"];
    } else if (http_code >= 200 && http_code < 400) {
        result.type = "none";
        result.confidence = 95;
        result.details = sprintf("Target accessible — no DPI blocking detected (HTTP %d, TTFB %dms)", http_code, ttfb);
        result.recommended_engines = [];
    } else {
        result.type = "unknown";
        result.confidence = 30;
        result.details = sprintf("Inconclusive — HTTP %d, error: %s", http_code, error_str != "" ? error_str : "none");
        result.recommended_engines = ["zapret2", "zapret", "byedpi"];
    }

    return result;
}

// ── History Persistence ──────────────────────────────────────────────────────
function load_history() {
    let data = read_json_file(HISTORY_FILE);
    if (data && type(data) == "object" && data.entries && type(data.entries) == "array") {
        return data;
    }
    return { entries: [] };
}

function save_history(history) {
    common.ensure_dir("/etc/tachyon");
    while (length(history.entries) > 50) {
        shift(history.entries);
    }
    write_json_file(HISTORY_FILE, history);
}

function append_history(entry) {
    let history = load_history();
    push(history.entries, {
        timestamp: entry.timestamp || clock()[0],
        engine: entry.engine || "unknown",
        target: entry.target || "unknown",
        mode: entry.mode || "presets",
        best_strategy: entry.best_strategy || null,
        total_tested: entry.total_tested || 0,
        working_count: entry.working_count || 0,
        dpi_detection: entry.dpi_detection || null,
        duration_sec: entry.duration_sec || 0
    });
    save_history(history);
}

function get_history(limit) {
    let history = load_history();
    let entries = history.entries || [];
    let n = int(limit) || 0;
    if (n > 0 && length(entries) > n) {
        let start = length(entries) - n;
        let sliced = [];
        for (let i = start; i < length(entries); i++) {
            push(sliced, entries[i]);
        }
        entries = sliced;
    }
    return entries;
}

// ── Strategy Priority Reranking (based on DPI type) ─────────────────────────
function rerank_strategies_by_dpi(strategies, dpi_type) {
    if (!dpi_type || dpi_type.type == "none" || dpi_type.type == "unknown")
        return strategies;

    let priority_ids = [];
    if (dpi_type.type == "rst") {
        priority_ids = ["badseq", "md5sig", "multisplit", "disorder"];
    } else if (dpi_type.type == "throttle") {
        priority_ids = ["multisplit", "seqovl", "wsize", "split2"];
    } else if (dpi_type.type == "dns_block") {
        priority_ids = ["fake", "ttl=3", "ttl=4", "sniext"];
    }

    if (length(priority_ids) == 0)
        return strategies;

    let scored = [];
    for (let s in strategies) {
        let score = 0;
        let args_lower = lc(as_string(s.args));
        let name_lower = lc(as_string(s.name));
        for (let pid in priority_ids) {
            if (index(args_lower, pid) >= 0 || index(name_lower, pid) >= 0) {
                score += 10;
            }
        }
        push(scored, { strat: s, score: score });
    }

    for (let i = 0; i < length(scored) - 1; i++) {
        for (let j = i + 1; j < length(scored); j++) {
            if (scored[j].score > scored[i].score) {
                let tmp = scored[i];
                scored[i] = scored[j];
                scored[j] = tmp;
            }
        }
    }

    let result = [];
    for (let item in scored) {
        push(result, item.strat);
    }
    return result;
}

function run_probe(engine, args_str, target_key, custom_url) {
    cleanup_temp_daemons();
    
    let urls_list = resolve_target_urls_list(target_key, custom_url);
    let total_urls = length(urls_list);
    
    let result = {
        success: false,
        http_code: 0,
        handshake_ms: 0,
        ttfb_ms: 0,
        speed_kbps: 0,
        score: 0,
        error: "",
        sub_probes: []
    };
    
    engine = lc(as_string(engine));
    let is_udp = index(args_str, "--filter-udp") >= 0 || index(args_str, "--dpi-desync-any-protocol") >= 0 || target_key == "quic_http3";
    
    if (engine == "byedpi") {
        let bin = get_byedpi_bin();
        if (!bin) {
            result.error = "ByeDPI binary not found";
            return result;
        }
        
        let pid_path = STATE_DIR + "/fuzzer_byedpi.pid";
        let stderr_log = STATE_DIR + "/fuzzer_daemon_err.log";
        let spawn_cmd = sprintf("cd /tmp && %s -i 127.0.0.1 -p %d %s 2>%s", bin, BYEDPI_PORT, args_str, shell_quote(stderr_log));
        system(common.background_command_with_pid(spawn_cmd, ">/dev/null", ">" + shell_quote(pid_path)));
        system("sleep 0.25");
        
        let pid_str = fs.readfile(pid_path);
        let pid_running = false;
        if (pid_str) {
            let pid = trim(as_string(pid_str));
            if (pid != "" && match(pid, /^[0-9]+$/) != null && system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) == 0) {
                pid_running = true;
            }
        }
        
        if (!pid_running) {
            let err_content = fs.readfile(stderr_log);
            let err_msg = err_content ? trim(as_string(err_content)) : "";
            if (err_msg != "") {
                let first_line = split(err_msg, "\n")[0];
                result.error = sprintf("Daemon failed to start: %s", first_line);
            } else {
                result.error = "ByeDPI daemon failed to start (invalid arguments)";
            }
            cleanup_temp_daemons();
            return result;
        }
        
        // Ensure ciadpi direct outbound connections bypass Sing-Box TProxy
        system("nft add table inet tachyon_fuzzer 2>/dev/null");
        system("nft 'add chain inet tachyon_fuzzer bypass_singbox { type route hook output priority -155 ; policy accept; }' 2>/dev/null");
        system("nft 'add rule inet tachyon_fuzzer bypass_singbox meta l4proto tcp tcp dport { 80, 443 } meta mark set meta mark | 0x00200000 counter' 2>/dev/null");
        
        let passed_count = 0;
        let sum_handshake = 0;
        let sum_ttfb = 0;
        let max_speed = 0;
        let last_http = 0;
        
        for (let target_item in urls_list) {
            let curl_cmd = sprintf(
                "curl -x socks5h://127.0.0.1:%d -so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}' -L --connect-timeout 4 --max-time 6 %s 2>/dev/null",
                BYEDPI_PORT,
                shell_quote(target_item.url)
            );
            let pipe = fs.popen(curl_cmd, "r");
            let output = pipe ? pipe.read("all") : "";
            if (pipe) pipe.close();
            
            let single_res = parse_curl_output(output, {});
            single_res.target_name = target_item.name;
            single_res.url = target_item.url;
            push(result.sub_probes, single_res);
            
            if (single_res.success) {
                passed_count++;
                sum_handshake += single_res.handshake_ms;
                sum_ttfb += single_res.ttfb_ms;
                if (single_res.speed_kbps > max_speed) max_speed = single_res.speed_kbps;
                last_http = single_res.http_code;
            } else {
                if (last_http == 0) last_http = single_res.http_code;
                if (single_res.error && result.error == "") result.error = single_res.error;
                break;
            }
        }
        
        cleanup_temp_daemons();
        
        if (passed_count == total_urls) {
            result.success = true;
            result.http_code = last_http > 0 ? last_http : 200;
            result.handshake_ms = int(sum_handshake / double(total_urls));
            result.ttfb_ms = int(sum_ttfb / double(total_urls));
            result.speed_kbps = max_speed;
            result.score = 100 + max(0, 1000 - result.ttfb_ms) + int(result.speed_kbps / 10.0);
            result.error = "";
        } else {
            result.success = false;
            result.http_code = last_http;
            result.score = 0;
            if (result.error == "") {
                result.error = sprintf("Failed %d of %d endpoints", total_urls - passed_count, total_urls);
            }
        }
        
        return result;
    }
    
    if (engine == "zapret" || engine == "zapret2") {
        let is_z2 = engine == "zapret2";
        let bin = is_z2 ? get_zapret2_bin() : get_zapret_bin();
        let qnum = is_z2 ? NFQUEUE_QNUM_ZAPRET2 : NFQUEUE_QNUM_ZAPRET;
        let pid_path = is_z2 ? (STATE_DIR + "/fuzzer_zapret2.pid") : (STATE_DIR + "/fuzzer_zapret.pid");
        let stderr_log = STATE_DIR + "/fuzzer_daemon_err.log";
        
        if (!bin) {
            result.error = (is_z2 ? "Zapret v2" : "Zapret v1") + " binary not found";
            return result;
        }
        
        let lua_init_flags = "";
        let blob_flags = "";
        if (is_z2) {
            lua_init_flags = get_zapret2_lua_flags(args_str);
            blob_flags = resolve_zapret2_blobs(args_str);
        }
        
        let filter_prefix = "";
        if (is_z2 && index(args_str, "--filter-tcp") < 0 && index(args_str, "--filter-l7") < 0) {
            filter_prefix = "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ";
        }
        if (is_z2 && is_udp && index(args_str, "--filter-udp") < 0) {
            filter_prefix += "--filter-udp=443 --payload=quic_initial ";
        }
        
        let spawn_cmd = sprintf("cd /tmp && %s --qnum=%d --fwmark=%s %s%s%s%s --pidfile=%s --daemon 2>%s", bin, qnum, FUZZER_FWMARK, lua_init_flags, blob_flags, filter_prefix, args_str, pid_path, shell_quote(stderr_log));
        system(common.background_command(spawn_cmd));
        system("sleep 0.25");
        
        let pid_str = fs.readfile(pid_path);
        let pid_running = false;
        if (pid_str) {
            let pid = trim(as_string(pid_str));
            if (pid != "" && match(pid, /^[0-9]+$/) != null && system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) == 0) {
                pid_running = true;
            }
        }
        
        if (!pid_running) {
            let err_content = fs.readfile(stderr_log);
            let err_msg = err_content ? trim(as_string(err_content)) : "";
            if (err_msg != "") {
                let first_line = split(err_msg, "\n")[0];
                result.error = sprintf("Daemon failed to start: %s", first_line);
            } else {
                result.error = sprintf("Daemon %s failed to start (invalid arguments or missing Lua library)", is_z2 ? "nfqws2" : "nfqws");
            }
            cleanup_temp_daemons();
            return result;
        }
        
        setup_fuzzer_direct_nftables(qnum, is_udp);
        
        let passed_count = 0;
        let sum_handshake = 0;
        let sum_ttfb = 0;
        let max_speed = 0;
        let last_http = 0;
        let dns_flags = get_fuzzer_curl_dns_flags();
        
        for (let target_item in urls_list) {
            let curl_cmd = sprintf(
                "curl %s-so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}' -L --connect-timeout 4 --max-time 6 %s 2>/dev/null",
                dns_flags,
                shell_quote(target_item.url)
            );
            let pipe = fs.popen(curl_cmd, "r");
            let output = pipe ? pipe.read("all") : "";
            if (pipe) pipe.close();
            
            let single_res = parse_curl_output(output, {});
            single_res.target_name = target_item.name;
            single_res.url = target_item.url;
            push(result.sub_probes, single_res);
            
            if (single_res.success) {
                passed_count++;
                sum_handshake += single_res.handshake_ms;
                sum_ttfb += single_res.ttfb_ms;
                if (single_res.speed_kbps > max_speed) max_speed = single_res.speed_kbps;
                last_http = single_res.http_code;
            } else {
                if (last_http == 0) last_http = single_res.http_code;
                if (single_res.error && result.error == "") result.error = single_res.error;
                break;
            }
        }
        
        cleanup_temp_daemons();
        
        if (passed_count == total_urls) {
            result.success = true;
            result.http_code = last_http > 0 ? last_http : 200;
            result.handshake_ms = int(sum_handshake / double(total_urls));
            result.ttfb_ms = int(sum_ttfb / double(total_urls));
            result.speed_kbps = max_speed;
            result.score = 100 + max(0, 1000 - result.ttfb_ms) + int(result.speed_kbps / 10.0);
            result.error = "";
        } else {
            result.success = false;
            result.http_code = last_http;
            result.score = 0;
            if (result.error == "") {
                result.error = sprintf("Failed %d of %d endpoints", total_urls - passed_count, total_urls);
            }
        }
        
        return result;
    }
    
    result.error = "Unknown engine: " + engine;
    return result;
}

function run_fuzzer_worker(engine, target, custom_url, rule_section, custom_file, mode) {
    let target_url = resolve_target_url(target, custom_url);

    // ── Pre-fuzz DPI detection ────────────────────────────────────────────
    let dpi_detection = detect_dpi_type(target, custom_url);

    let strategies = null;
    if (custom_file && custom_file != "" && fs.stat(custom_file) != null) {
        strategies = common.read_json_file(custom_file);
    }
    if (!strategies || type(strategies) != "array" || length(strategies) == 0) {
        strategies = get_strategies_for_engine(engine, mode);
    }

    // Rerank strategies based on detected DPI type
    strategies = rerank_strategies_by_dpi(strategies, dpi_detection);

    let total = length(strategies);
    
    let state = {
        running: true,
        job_id: sprintf("fuzz_%d", clock()[0]),
        engine,
        target,
        target_url,
        mode: as_string(mode || "presets"),
        rule_section: as_string(rule_section),
        custom_file: as_string(custom_file || ""),
        progress_pct: 0,
        current_index: 0,
        total_strategies: total,
        current_strategy: null,
        results: [],
        best_strategy: null,
        error: null,
        started_at: clock()[0],
        finished_at: 0,
        dpi_detection: dpi_detection
    };
    
    save_fuzzer_state(state);
    
    try {
        let highest_score = -1;
        let best = null;
        let working_count = 0;
        
        for (let i = 0; i < total; i++) {
            let strat = strategies[i];
            state.current_index = i + 1;
            state.current_strategy = strat;
            state.progress_pct = int(((i) / double(total)) * 100.0);
            save_fuzzer_state(state);
            
            let probe = run_probe(strat.engine || engine, strat.args, target, custom_url);
            
            let item_result = {
                id: strat.id || sprintf("strat_%d", i + 1),
                name: strat.name || sprintf("Strategy %d", i + 1),
                engine: strat.engine || engine,
                args: strat.args,
                description: strat.description || "",
                rationale: strat.rationale || "",
                success: probe.success,
                http_code: probe.http_code,
                handshake_ms: probe.handshake_ms,
                ttfb_ms: probe.ttfb_ms,
                speed_kbps: probe.speed_kbps,
                score: probe.score,
                error: probe.error,
                sub_probes: probe.sub_probes || [],
                badge: ""
            };
            
            if (item_result.success) working_count++;

            if (item_result.score > highest_score && item_result.success) {
                highest_score = item_result.score;
                best = item_result;
            }
            
            push(state.results, item_result);
            state.progress_pct = int(((i + 1) / double(total)) * 100.0);
            save_fuzzer_state(state);
        }
        
        // Assign badges
        if (best) {
            best.badge = "🏆 Best Match";
            state.best_strategy = best;
        }
        
        // Mark fastest and most stable
        let min_ttfb = 999999;
        let fastest = null;
        for (let r in state.results) {
            if (r.success && r.ttfb_ms > 0 && r.ttfb_ms < min_ttfb) {
                min_ttfb = r.ttfb_ms;
                fastest = r;
            }
        }
        if (fastest && fastest.id != (best ? best.id : "")) {
            fastest.badge = "⚡ Ultra Fast";
        }
        
        state.running = false;
        state.current_strategy = null;
        state.finished_at = clock()[0];
        save_fuzzer_state(state);

        // ── Persist to history ────────────────────────────────────────────
        let duration = state.finished_at - state.started_at;
        append_history({
            timestamp: state.finished_at,
            engine: engine,
            target: target,
            mode: mode,
            best_strategy: best ? {
                id: best.id,
                name: best.name,
                engine: best.engine,
                args: best.args,
                score: best.score,
                ttfb_ms: best.ttfb_ms,
                speed_kbps: best.speed_kbps
            } : null,
            total_tested: total,
            working_count: working_count,
            dpi_detection: dpi_detection,
            duration_sec: int(duration)
        });
    } catch (err) {
        state.running = false;
        state.error = as_string(err);
        state.finished_at = clock()[0];
        save_fuzzer_state(state);
    }
    
    cleanup_temp_daemons();
}

function start_fuzzer(engine, target, custom_url, rule_section, custom_file, mode) {
    let current = get_fuzzer_state();
    if (current.running) {
        print(sprintf("%J\n", { success: false, error: "Fuzzer is already running", job_id: current.job_id }));
        return;
    }
    
    ensure_state_dir();
    
    let job_id = sprintf("fuzz_%d", clock()[0]);
    let cmd = sprintf(
        "ucode -L /usr/lib/tachyon /usr/lib/tachyon/diagnostics/fuzzer.uc worker %s %s %s %s %s %s",
        shell_quote(engine || "zapret2"),
        shell_quote(target || "youtube_suite"),
        shell_quote(custom_url || ""),
        shell_quote(rule_section || ""),
        shell_quote(custom_file || ""),
        shell_quote(mode || "presets")
    );
    
    system(common.background_command_with_pid(cmd, ">/dev/null", ">" + shell_quote(PID_FILE)));
    
    print(sprintf("%J\n", { success: true, job_id, engine: engine || "zapret2", target: target || "youtube_suite", mode: mode || "presets" }));
}

function stop_fuzzer() {
    kill_pid_file(PID_FILE);
    cleanup_temp_daemons();
    
    let state = get_fuzzer_state();
    state.running = false;
    state.error = "Stopped by user";
    state.finished_at = clock()[0];
    save_fuzzer_state(state);
    
    print(sprintf("%J\n", { success: true, message: "Fuzzer stopped" }));
}

function get_available_engines() {
    return {
        zapret2: get_zapret2_bin() != null,
        zapret: get_zapret_bin() != null,
        byedpi: get_byedpi_bin() != null
    };
}

function normalize_strategy_for_uci(engine, args_val) {
    args_val = trim(as_string(args_val));
    if (engine == "zapret2") {
        let blob_defs = resolve_zapret2_blobs(args_val);
        if (blob_defs != "") {
            args_val = trim(blob_defs) + " " + args_val;
        }
    }
    return args_val;
}

function apply_strategy(engine, args_val, target_rule) {
    engine = lc(as_string(engine));
    args_val = trim(as_string(args_val));
    target_rule = trim(as_string(target_rule));
    
    if (args_val == "") {
        print(sprintf("%J\n", { success: false, error: "Empty strategy arguments" }));
        return;
    }
    
    args_val = normalize_strategy_for_uci(engine, args_val);
    
    let uci = uci_core.cursor();
    let applied = false;
    
    if (target_rule != "" && target_rule != "global") {
        uci.set(CONFIG_NAME, target_rule, "action", engine);
        if (engine == "zapret2")
            uci.set(CONFIG_NAME, target_rule, "nfqws2_opt", args_val);
        else if (engine == "zapret")
            uci.set(CONFIG_NAME, target_rule, "nfqws_opt", args_val);
        else if (engine == "byedpi")
            uci.set(CONFIG_NAME, target_rule, "byedpi_cmd_opts", args_val);
        applied = true;
    } else {
        let provider_sec = engine;
        let sec_obj = uci.get_all(CONFIG_NAME, provider_sec);
        if (sec_obj == null) {
            uci.set(CONFIG_NAME, provider_sec, "provider");
        }
        uci.set(CONFIG_NAME, provider_sec, "enabled", "1");
        if (engine == "zapret2")
            uci.set(CONFIG_NAME, provider_sec, "nfqws2_opt", args_val);
        else if (engine == "zapret")
            uci.set(CONFIG_NAME, provider_sec, "nfqws_opt", args_val);
        else if (engine == "byedpi")
            uci.set(CONFIG_NAME, provider_sec, "byedpi_cmd_opts", args_val);
        applied = true;
    }
    
    uci.commit(CONFIG_NAME);
    system(common.background_command("tachyon reload"));
    
    print(sprintf("%J\n", {
        success: true,
        engine,
        applied_to: target_rule != "" ? target_rule : "global",
        args: args_val
    }));
}

function auto_apply_best(target_rule) {
    let state = get_fuzzer_state();
    if (!state.best_strategy || state.best_strategy.score <= 0) {
        print(sprintf("%J\n", { success: false, error: "No winning strategy found — run a benchmark first" }));
        return;
    }
    let best = state.best_strategy;
    apply_strategy(best.engine, best.args, target_rule);
}

function clear_history() {
    save_history({ entries: [] });
    print(sprintf("%J\n", { success: true, message: "Fuzzer history cleared" }));
}

// CLI Dispatcher
let op = ARGV[0] || "status";

if (op == "start") {
    start_fuzzer(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
} else if (op == "worker") {
    run_fuzzer_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
} else if (op == "status") {
    print(sprintf("%J\n", get_fuzzer_state()));
} else if (op == "stop") {
    stop_fuzzer();
} else if (op == "apply") {
    apply_strategy(ARGV[1], ARGV[2], ARGV[3]);
} else if (op == "get_patterns" || op == "patterns") {
    print(sprintf("%J\n", { success: true, patterns: get_patterns_config() }));
} else if (op == "save_patterns") {
    let cfg = safe_json_parse(ARGV[1]);
    save_patterns_config(cfg);
} else if (op == "reset_patterns") {
    reset_patterns_config();
} else if (op == "ai_synthesize" || op == "synthesize") {
    synthesize_ai_strategies(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
} else if (op == "detect_dpi") {
    let detection = detect_dpi_type(ARGV[1], ARGV[2]);
    print(sprintf("%J\n", detection));
} else if (op == "auto_apply") {
    auto_apply_best(ARGV[1]);
} else if (op == "history") {
    let entries = get_history(ARGV[1]);
    print(sprintf("%J\n", { success: true, entries: entries }));
} else if (op == "clear_history") {
    clear_history();
} else if (op == "generate" || op == "strategies_generate") {
    print(sprintf("%J\n", get_strategies_for_engine(ARGV[1], ARGV[2] || "combinatorial")));
} else if (op == "strategies") {
    let strat_mode = ARGV[1] || "presets";
    print(sprintf("%J\n", {
        available_engines: get_available_engines(),
        target_suites: TARGET_SUITES,
        patterns: get_patterns_config(),
        zapret2: get_strategies_for_engine("zapret2", strat_mode),
        zapret: get_strategies_for_engine("zapret", strat_mode),
        byedpi: get_strategies_for_engine("byedpi", strat_mode)
    }));
} else {
    warn("Usage: fuzzer.uc [start|status|stop|apply|strategies|generate|get_patterns|save_patterns|reset_patterns|ai_synthesize|detect_dpi|auto_apply|history|clear_history|worker] ...\n");
    exit(1);
}

