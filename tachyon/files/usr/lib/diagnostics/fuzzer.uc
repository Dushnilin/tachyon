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
const BYEDPI_PORT = 11089;
const NFQUEUE_QNUM_ZAPRET = 298;
const NFQUEUE_QNUM_ZAPRET2 = 299;
const FUZZER_FWMARK = "0x08000000";

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

// Target definitions
const TARGET_URLS = {
    youtube: "https://rr1---sn-4g5edn6r.googlevideo.com/generate_204",
    youtube_web: "https://www.youtube.com",
    discord: "https://discord.com/api/v9/gateway",
    instagram: "https://www.instagram.com",
    rutracker: "https://rutracker.org",
    telegram: "https://web.telegram.org"
};

// Strategy Matrices (Expanded Production Suite: 38 strategies across engines)
const STRATEGIES_ZAPRET2 = [
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
        id: "z2_fake_badseq_mid",
        name: "Fake Packet (TTL=8) + MidSLD Split",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8 --lua-desync=multisplit:pos=midsld:fooling=badseq",
        description: "Injects low-TTL fake ClientHello before segmented payload."
    },
    {
        id: "z2_fake_md5sig_ttl6",
        name: "Fake (TTL=6, MD5Sig) + Multisplit",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=6:fooling=md5sig --lua-desync=multisplit:pos=1,midsld",
        description: "MD5Sig TCP option drops packet at DPI while reaching end server."
    },
    {
        id: "z2_fake_badack_ttl8",
        name: "Fake (TTL=8, BadACK) + SNIExt Split",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=badack --lua-desync=multisplit:pos=1,sniext+2",
        description: "BadACK fooling invalidates packet in DPI state tracking."
    },
    {
        id: "z2_wsize_multisplit",
        name: "Window Size Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:fooling=badseq",
        description: "Forces single-byte TCP window segments to evade reassembly."
    },
    {
        id: "z2_wsize_seqovl_combo",
        name: "Window Clamp (wsize=1) + SeqOvl",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:seqovl=1:fooling=badseq",
        description: "Combines 1-byte window clamp with sequence overlap."
    },
    {
        id: "z2_aggressive_combo",
        name: "Aggressive Triple-Split + SeqOvl 2",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld,sniext+2:seqovl=2:fooling=badseq",
        description: "High-entropy triple fragmentation for heavily filtered regions."
    },
    {
        id: "z2_split2_pos1",
        name: "Classic Split2 (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=split2:pos=1:fooling=badseq",
        description: "Standard 2-fragment desync for compatibility."
    },
    {
        id: "z2_disorder2_pos1",
        name: "Classic Disorder2 (pos=1)",
        engine: "zapret2",
        args: "--lua-desync=disorder2:pos=1:fooling=badseq",
        description: "Sends out-of-order segment with badseq fooling."
    },
    {
        id: "z2_fake_datanoack",
        name: "Fake (TTL=8, DataNoAck) + Split2",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8:fooling=datanoack --lua-desync=split2:pos=1",
        description: "DataNoAck fooling confuses stateful DPI without triggering ACK RST."
    },
    {
        id: "z2_multiprofile_discord",
        name: "Discord Multi-Profile (TCP + UDP)",
        engine: "zapret2",
        args: "--filter-tcp=443 --lua-desync=multisplit:pos=1,midsld:seqovl=1 --new --filter-udp=50000-65535 --lua-desync=fake:ttl=8",
        description: "Combined profile: multisplit for HTTPS/API and fake UDP for Discord Voice."
    },
    {
        id: "z2_discord_udp",
        name: "Discord Voice UDP Desync",
        engine: "zapret2",
        args: "--filter-udp=50000-65535 --lua-desync=fake:ttl=8",
        description: "UDP fake packet desync for Discord RTC and Voice channels."
    },
    {
        id: "z2_quic_http3_udp",
        name: "QUIC / HTTP3 UDP Fake Desync",
        engine: "zapret2",
        args: "--filter-udp=443 --lua-desync=fake:ttl=8",
        description: "UDP fake desync for QUIC/HTTP3 protocol bypass."
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
    }
];

function generate_combinatorial_zapret2() {
    let list = [];
    let seen = {};
    
    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!validate_strategy_args("zapret2", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("z2_gen_%d", length(list) + 1),
            name: name,
            engine: "zapret2",
            args: args,
            description: desc
        });
    };
    
    for (let s in STRATEGIES_ZAPRET2) add(s.name, s.args, s.description);
    
    let positions = ["1", "2", "midsld", "sniext+4", "1,midsld", "1,sniext+2", "1,midsld,sniext+2"];
    let foolings = ["badseq", "md5sig", "badack", "datanoack"];
    let seqovls = ["1", "2"];
    let ttls = [4, 6, 8, 10];
    
    for (let pos in positions) {
        for (let fooling in foolings) {
            add(sprintf("Multisplit (pos=%s, %s)", pos, fooling),
                sprintf("--lua-desync=multisplit:pos=%s:fooling=%s", pos, fooling),
                "Permutation of multisplit position and fooling method");
            for (let seqovl in seqovls) {
                add(sprintf("Multisplit + SeqOvl (pos=%s, seqovl=%s, %s)", pos, seqovl, fooling),
                    sprintf("--lua-desync=multisplit:pos=%s:seqovl=%s:fooling=%s", pos, seqovl, fooling),
                    "Permutation of multisplit with sequence overlap");
                add(sprintf("Multisplit + wsize=1 (pos=%s, seqovl=%s, %s)", pos, seqovl, fooling),
                    sprintf("--lua-desync=multisplit:pos=%s:wsize=1:seqovl=%s:fooling=%s", pos, seqovl, fooling),
                    "Window size clamp with sequence overlap");
            }
        }
    }
    
    for (let ttl in ttls) {
        for (let fooling in foolings) {
            for (let pos in ["1", "midsld", "sniext+4", "1,midsld"]) {
                add(sprintf("Fake (TTL=%d, %s) + Multisplit (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=multisplit:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by multisplit payload");
                add(sprintf("Fake (TTL=%d, %s) + Split2 (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=split2:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by 2-part split");
                add(sprintf("Fake (TTL=%d, %s) + Disorder2 (pos=%s)", ttl, fooling, pos),
                    sprintf("--lua-desync=fake:ttl=%d:fooling=%s --lua-desync=disorder2:pos=%s", ttl, fooling, pos),
                    "Low-TTL fake injection followed by out-of-order segment");
            }
        }
    }
    
    return list;
}

function generate_combinatorial_zapret() {
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
    
    let modes = ["split2", "disorder2", "fake,split2", "fake,disorder2"];
    let positions = ["1", "2", "midsld", "sniext"];
    let foolings = ["badseq", "md5sig", "badack"];
    let ttls = [4, 6, 8, 10];
    let seqovls = [1, 2];
    
    for (let mode in modes) {
        for (let pos in positions) {
            for (let fooling in foolings) {
                if (index(mode, "fake") >= 0) {
                    for (let ttl in ttls) {
                        add(sprintf("%s (pos=%s, TTL=%d, %s)", mode, pos, ttl, fooling),
                            sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-ttl=%d --dpi-desync-fooling=%s", mode, pos, ttl, fooling),
                            "Permutation of fake desync with split pos and fooling");
                    }
                } else {
                    add(sprintf("%s (pos=%s, %s)", mode, pos, fooling),
                        sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-fooling=%s", mode, pos, fooling),
                        "Permutation of desync with split pos and fooling");
                    for (let seqovl in seqovls) {
                        add(sprintf("%s + SeqOvl=%d (pos=%s, %s)", mode, seqovl, pos, fooling),
                            sprintf("--dpi-desync=%s --dpi-desync-split-pos=%s --dpi-desync-split-seqovl=%d --dpi-desync-fooling=%s", mode, pos, seqovl, fooling),
                            "Permutation with sequence overlap");
                    }
                }
            }
        }
    }
    
    return list;
}

function generate_combinatorial_byedpi() {
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
    
    let splits = ["1", "2", "1+sniext", "midsld"];
    let disorders = ["1", "2"];
    let ttls = [3, 4, 6, 8, 10];
    let oobs = ["1", "2"];
    let autos = ["t,r,a,s", "r,s", "t,a", "t,r,s"];
    
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
    
    for (let ttl in ttls) {
        for (let s in splits) {
            for (let d in disorders) {
                add(sprintf("Split=%s + Disorder=%s + Fake (TTL=%d)", s, d, ttl),
                    sprintf("--split %s --disorder %s --fake -1 --ttl %d", s, d, ttl),
                    "Fake injection with split and disorder");
            }
        }
    }
    
    for (let s in splits) {
        add(sprintf("TLS-Rec (1+sniext) + Split=%s", s),
            sprintf("--tlsrec 1+sniext --split %s", s),
            "TLS record boundary fragmentation");
        add(sprintf("IP-Frag (24) + Split=%s", s),
            sprintf("--ip-frag 24 --split %s", s),
            "IP packet fragmentation");
        add(sprintf("IP-Frag (32) + Split=%s", s),
            sprintf("--ip-frag 32 --split %s", s),
            "IP packet fragmentation on 32-byte boundary");
    }
    
    return list;
}

function get_strategies_for_engine(engine, mode) {
    engine = lc(as_string(engine));
    mode = lc(as_string(mode || "presets"));
    
    if (mode == "combinatorial" || mode == "deep_fuzz" || mode == "full") {
        if (engine == "zapret2")
            return generate_combinatorial_zapret2();
        if (engine == "zapret")
            return generate_combinatorial_zapret();
        if (engine == "byedpi")
            return generate_combinatorial_byedpi();
        
        let all = [];
        for (let s in generate_combinatorial_zapret2()) push(all, s);
        for (let s in generate_combinatorial_zapret()) push(all, s);
        for (let s in generate_combinatorial_byedpi()) push(all, s);
        return all;
    }
    
    if (engine == "zapret2")
        return STRATEGIES_ZAPRET2;
    if (engine == "zapret")
        return STRATEGIES_ZAPRET;
    if (engine == "byedpi")
        return STRATEGIES_BYEDPI;
    
    // Default or 'all': combine all
    let all = [];
    for (let s in STRATEGIES_ZAPRET2) push(all, s);
    for (let s in STRATEGIES_ZAPRET) push(all, s);
    for (let s in STRATEGIES_BYEDPI) push(all, s);
    return all;
}

function resolve_target_url(target, custom_url) {
    if (custom_url && trim(as_string(custom_url)) != "")
        return trim(as_string(custom_url));
    
    target = lc(as_string(target));
    if (TARGET_URLS[target])
        return TARGET_URLS[target];
    
    return TARGET_URLS.youtube;
}

function ensure_state_dir() {
    common.ensure_dir(STATE_DIR);
}

function save_fuzzer_state(state) {
    ensure_state_dir();
    common.write_json_file(STATE_FILE, state);
}

function query_llm(provider, api_key, custom_url, prompt_text, model_override) {
    provider = lc(trim(as_string(provider || "openai")));
    model_override = trim(as_string(model_override || ""));

    if (provider == "anthropic" || provider == "claude") {
        let api_url = "https://api.anthropic.com/v1/messages";
        let model = model_override != "" ? model_override : "claude-3-5-haiku-20241022";
        let payload = {
            model: model,
            max_tokens: 1500,
            messages: [{ role: "user", content: prompt_text }]
        };
        let payload_path = "/tmp/fuzzer_llm_payload.json";
        common.write_json_file(payload_path, payload);

        let curl_args = [
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "x-api-key: " + api_key,
            "-H", "anthropic-version: 2023-06-01",
            "--connect-timeout", "10",
            "-m", "60",
            "-d", "@" + payload_path,
            api_url
        ];

        let pipe = fs.popen(command_from_args(curl_args), "r");
        let output = pipe ? pipe.read("all") : "";
        if (pipe) pipe.close();
        common.remove_file(payload_path);

        if (output == "") return null;
        let response_data = null;
        try { response_data = json(output); } catch (e) {}
        if (response_data && type(response_data.content) == "array" && length(response_data.content) > 0) {
            return response_data.content[0].text;
        }
        return null;
    }

    let api_url = "https://api.openai.com/v1/chat/completions";
    let model = model_override != "" ? model_override : "gpt-4o-mini";

    if (provider == "deepseek") {
        api_url = "https://api.deepseek.com/chat/completions";
        model = model_override != "" ? model_override : "deepseek-chat";
    } else if (provider == "openrouter") {
        api_url = "https://openrouter.ai/api/v1/chat/completions";
        model = model_override != "" ? model_override : "openai/gpt-4o-mini";
    } else if (provider == "ollama") {
        if (custom_url != "") {
            let base = replace(custom_url, /\/v1\/chat\/completions\/?$/, "");
            api_url = base + "/v1/chat/completions";
        } else {
            api_url = "http://192.168.1.100:11434/v1/chat/completions";
        }
        model = model_override != "" ? model_override : "llama3:latest";
    } else if (provider == "lmstudio") {
        if (custom_url != "") {
            let base = replace(custom_url, /\/v1\/chat\/completions\/?$/, "");
            api_url = base + "/v1/chat/completions";
        } else {
            api_url = "http://192.168.1.100:1234/v1/chat/completions";
        }
        model = model_override != "" ? model_override : "local-model";
    } else if (provider == "custom" && custom_url != "") {
        api_url = custom_url;
        model = model_override != "" ? model_override : "gpt-4o-mini";
    }

    let payload = {
        model: model,
        messages: [{ role: "user", content: prompt_text }],
        temperature: 0.3
    };

    let payload_path = "/tmp/fuzzer_llm_payload.json";
    common.write_json_file(payload_path, payload);

    let curl_args = [
        "curl", "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " + api_key,
        "--connect-timeout", "10",
        "-m", "60",
        "-d", "@" + payload_path,
        api_url
    ];

    let pipe = fs.popen(command_from_args(curl_args), "r");
    let output = pipe ? pipe.read("all") : "";
    if (pipe) pipe.close();
    common.remove_file(payload_path);

    if (output == "") return null;
    let response_data = null;
    try { response_data = json(output); } catch (e) {}
    if (response_data && type(response_data.choices) == "array" && length(response_data.choices) > 0) {
        return response_data.choices[0].message ? response_data.choices[0].message.content : null;
    }
    return null;
}

function uci_settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || uci_core.get_all(CONFIG_NAME, "main") || {};
}

function synthesize_ai_strategies(engine, target, custom_url, user_prompt) {
    engine = lc(as_string(engine || "zapret2"));
    target = lc(as_string(target || "youtube"));
    custom_url = trim(as_string(custom_url || ""));
    user_prompt = trim(as_string(user_prompt || ""));
    
    let cfg = uci_settings();
    let provider = lc(trim(as_string(cfg.ai_doctor_provider || "openai")));
    let api_key = cfg.ai_doctor_api_key || "";
    let custom_url_llm = cfg.ai_doctor_custom_url || "";
    let model_override = trim(cfg.ai_doctor_model || "");
    
    let has_key = (api_key != "");
    let is_local_or_custom = (provider == "ollama" || provider == "lmstudio" || (provider == "custom" && custom_url_llm != ""));
    
    if (!has_key && !is_local_or_custom) {
        print(sprintf("%J\n", {
            success: false,
            error: "AI Doctor API key is not configured in Tachyon settings (Diagnostics -> AI Doctor)."
        }));
        return;
    }
    
    let target_url = resolve_target_url(target, custom_url);
    
    // Fast direct probe without desync
    let probe_cmd = sprintf(
        "curl -so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}' --connect-timeout 3 --max-time 4 %s 2>/dev/null",
        shell_quote(target_url)
    );
    let pipe = fs.popen(probe_cmd, "r");
    let raw_probe = pipe ? pipe.read("all") : "";
    if (pipe) pipe.close();
    
    let probe_status = "Direct connection without desync failed or timed out.";
    if (raw_probe && raw_probe != "") {
        let parts = split(trim(raw_probe), "\t");
        let http_code = int(parts[0]);
        if (http_code > 0)
            probe_status = sprintf("Direct HTTP %d, Connect %s sec, TTFB %s sec", http_code, parts[1] || "0", parts[2] || "0");
    }
    
    // Retrieve RAG context
    let rag_query = sprintf("%s %s DPI bypass desync strategy TSPU %s", engine, target, user_prompt);
    let rag_context = "";
    try {
        rag_context = rag.retrieve(rag_query, provider, api_key, custom_url_llm, model_override, 3);
    } catch (e) {
        rag_context = "";
    }
    
    let prompt = sprintf(
        "You are an expert Anti-Censorship and Deep Packet Inspection (DPI) bypass engineer specializing in OpenWrt, Zapret, Zapret2 (nfqws2), and ByeDPI (ciadpi).\n" +
        "Synthesize 3 to 5 highly effective, customized bypass strategies for the engine '%s' targeting service '%s' (%s).\n\n" +
        "Target Service: %s\n" +
        "Target URL: %s\n" +
        "Baseline Network Probe: %s\n" +
        "User Context / Notes: %s\n\n" +
        (rag_context != "" ? "=== Relevant Technical Documentation (RAG) ===\n" + rag_context + "\n=============================================\n\n" : "") +
        "Syntax Specifications for '%s':\n" +
        (engine == "zapret2" ?
            "- Uses nfqws2 Lua actions: --lua-desync=<func>[:key=val[:key=val]].\n" +
            "- Valid actions: multisplit (pos=1,midsld:seqovl=1:fooling=badseq, pos=1,sniext+4:seqovl=1:fooling=badseq, pos=1,midsld,sniext+2:seqovl=2:fooling=badseq), fake (ttl=8:fooling=badseq), split2 (pos=1), disorder2 (pos=1).\n" +
            "- Valid fooling options: badseq, md5sig, badack, datanoack.\n" +
            "- Window clamp: wsize=1.\n" +
            "- Multi-profile support: e.g. --filter-tcp=443 --lua-desync=... --new --filter-udp=50000-65535 --lua-desync=fake:ttl=8.\n" :
        engine == "zapret" ?
            "- Uses nfqws CLI options: --dpi-desync=<modes> [--dpi-desync-split-pos=<pos>] [--dpi-desync-split-seqovl=<N>] [--dpi-desync-ttl=<N>] [--dpi-desync-fooling=<fooling>].\n" +
            "- Valid modes: fake, split2, disorder2, multisplit, ipfrag2.\n" +
            "- Valid fooling: badseq, md5sig, badack.\n" :
            "- Uses ciadpi CLI options: -s <pos>, -d <pos>, -f <offset>, -t <ttl>, -o <offset>, --auto=t,r,a,s, --split, --disorder, --fake, --ttl.\n") +
        "\nREQUIREMENT: Respond ONLY with a valid JSON object matching this schema without any markdown formatting or backticks:\n" +
        "{\n" +
        "  \"analysis\": \"Concise 2-3 sentence technical diagnosis of the blocking pattern and rationale for these strategies.\",\n" +
        "  \"strategies\": [\n" +
        "    {\n" +
        "      \"id\": \"ai_strat_1\",\n" +
        "      \"name\": \"Descriptive human-readable strategy name\",\n" +
        "      \"engine\": \"%s\",\n" +
        "      \"args\": \"Exact valid CLI argument string\",\n" +
        "      \"description\": \"What this strategy does\",\n" +
        "      \"rationale\": \"Why this parameter combination works against this filter\"\n" +
        "    }\n" +
        "  ]\n" +
        "}",
        engine, target, target_url, target, target_url, probe_status, user_prompt != "" ? user_prompt : "None provided", engine, engine
    );
    
    let raw_ai_res = query_llm(provider, api_key, custom_url_llm, prompt, model_override);
    if (!raw_ai_res || trim(raw_ai_res) == "") {
        print(sprintf("%J\n", {
            success: false,
            error: "Failed to receive response from LLM provider (" + provider + ")."
        }));
        return;
    }
    
    // Clean potential markdown fences
    let clean_json = trim(raw_ai_res);
    clean_json = replace(clean_json, /^```json\s*/i, "");
    clean_json = replace(clean_json, /^```\s*/, "");
    clean_json = replace(clean_json, /\s*```$/, "");
    
    let parsed = null;
    try {
        parsed = json(clean_json);
    } catch (e) {
        // Try substring extraction
        let start_idx = index(clean_json, "{");
        let end_idx = rindex(clean_json, "}");
        if (start_idx >= 0 && end_idx > start_idx) {
            try {
                parsed = json(substr(clean_json, start_idx, end_idx - start_idx + 1));
            } catch (e2) {}
        }
    }
    
    if (!parsed || type(parsed.strategies) != "array" || length(parsed.strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "LLM produced invalid JSON schema",
            raw: substr(clean_json, 0, 300)
        }));
        return;
    }
    
    let valid_strategies = [];
    for (let i = 0; i < length(parsed.strategies); i++) {
        let s = parsed.strategies[i];
        if (!s || !s.args || trim(as_string(s.args)) == "") continue;
        let s_engine = s.engine || engine;
        let is_valid = validate_strategy_args(s_engine, s.args);
        if (is_valid) {
            push(valid_strategies, {
                id: s.id || sprintf("ai_strat_%d", i + 1),
                name: s.name || sprintf("AI Strategy %d", i + 1),
                engine: s_engine,
                args: trim(as_string(s.args)),
                description: s.description || "",
                rationale: s.rationale || ""
            });
        }
    }
    
    if (length(valid_strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "No generated strategies passed syntax validation",
            raw_strategies: parsed.strategies
        }));
        return;
    }
    
    // Save AI strategies to temporary custom file for benchmark execution
    ensure_state_dir();
    common.write_json_file("/tmp/fuzzer_ai_strategies.json", valid_strategies);
    
    print(sprintf("%J\n", {
        success: true,
        engine,
        target,
        target_url,
        analysis: parsed.analysis || "AI strategy synthesis complete.",
        strategies: valid_strategies
    }));
}

function get_fuzzer_state() {
    let state = common.read_json_file(STATE_FILE);
    if (!state || type(state) != "object") {
        return {
            running: false,
            job_id: null,
            engine: "zapret2",
            target: "youtube",
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
}

function parse_curl_output(output, result) {
    output = trim(as_string(output));
    if (output == "") {
        result.error = "Probe timeout or connection refused";
        return result;
    }
    
    let parts = split(output, "\t");
    if (length(parts) < 4) {
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
    
    if (http_code >= 200 && http_code < 400) {
        result.success = true;
        let speed_factor = (result.speed_kbps / 200.0) + 1.0;
        let ttfb_factor = 1000.0 / (result.ttfb_ms + 1.0);
        result.score = int(ttfb_factor * speed_factor);
    } else {
        result.success = false;
        result.score = 0;
        result.error = sprintf("HTTP Status %d", http_code);
    }
    
    return result;
}

function run_probe(engine, args_str, target_url) {
    cleanup_temp_daemons();
    
    let result = {
        success: false,
        http_code: 0,
        handshake_ms: 0,
        ttfb_ms: 0,
        speed_kbps: 0,
        score: 0,
        error: ""
    };
    
    engine = lc(as_string(engine));
    
    if (engine == "byedpi") {
        let bin = get_byedpi_bin();
        if (!bin) {
            result.error = "ByeDPI binary not found";
            return result;
        }
        
        let pid_path = STATE_DIR + "/fuzzer_byedpi.pid";
        let spawn_cmd = sprintf("%s -i 127.0.0.1 -p %d %s", bin, BYEDPI_PORT, args_str);
        system(common.background_command_with_pid(spawn_cmd, ">/dev/null", ">" + shell_quote(pid_path)));
        system("sleep 0.15");
        
        let curl_cmd = sprintf(
            "curl -x socks5h://127.0.0.1:%d -so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}' --connect-timeout 4 --max-time 6 %s 2>/dev/null",
            BYEDPI_PORT,
            shell_quote(target_url)
        );
        
        let pipe = fs.popen(curl_cmd, "r");
        let output = pipe ? pipe.read("all") : "";
        if (pipe) pipe.close();
        
        cleanup_temp_daemons();
        
        return parse_curl_output(output, result);
    }
    
    if (engine == "zapret" || engine == "zapret2") {
        let is_z2 = engine == "zapret2";
        let bin = is_z2 ? get_zapret2_bin() : get_zapret_bin();
        let qnum = is_z2 ? NFQUEUE_QNUM_ZAPRET2 : NFQUEUE_QNUM_ZAPRET;
        let pid_path = is_z2 ? (STATE_DIR + "/fuzzer_zapret2.pid") : (STATE_DIR + "/fuzzer_zapret.pid");
        
        if (!bin) {
            result.error = (is_z2 ? "Zapret v2" : "Zapret v1") + " binary not found";
            return result;
        }
        
        let lua_init_flags = "";
        if (is_z2 && fs.stat("/opt/zapret2/lua/zapret-lib.lua") != null && index(args_str, "--lua-init") < 0) {
            lua_init_flags = "--lua-init=@/opt/zapret2/lua/zapret-lib.lua --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua --lua-init=@/opt/zapret2/lua/zapret-auto.lua ";
        }
        
        let spawn_cmd = sprintf("%s --qnum=%d --fwmark=%s %s%s --pidfile=%s --daemon", bin, qnum, FUZZER_FWMARK, lua_init_flags, args_str, pid_path);
        system(common.background_command(spawn_cmd));
        system("sleep 0.15");
        
        // Setup temporary isolated nftables queue for probe
        system("nft add table inet tachyon_fuzzer 2>/dev/null");
        system("nft 'add chain inet tachyon_fuzzer output { type filter hook output priority -150 ; }' 2>/dev/null");
        system(sprintf("nft add rule inet tachyon_fuzzer output meta mark %s counter return 2>/dev/null", FUZZER_FWMARK));
        system(sprintf("nft 'add rule inet tachyon_fuzzer output meta l4proto tcp tcp dport { 80, 443 } counter queue num %d bypass' 2>/dev/null", qnum));
        
        // Execute probe with interface-mark if supported, or standard direct curl
        let curl_cmd = sprintf(
            "curl -so /dev/null -w '%%{http_code}\\t%%{time_appconnect}\\t%%{time_starttransfer}\\t%%{speed_download}' --connect-timeout 4 --max-time 6 %s 2>/dev/null",
            shell_quote(target_url)
        );
        
        let pipe = fs.popen(curl_cmd, "r");
        let output = pipe ? pipe.read("all") : "";
        if (pipe) pipe.close();
        
        cleanup_temp_daemons();
        
        return parse_curl_output(output, result);
    }
    
    result.error = "Unknown engine: " + engine;
    return result;
}

function run_fuzzer_worker(engine, target, custom_url, rule_section, custom_file, mode) {
    let target_url = resolve_target_url(target, custom_url);
    let strategies = null;
    if (custom_file && custom_file != "" && fs.stat(custom_file) != null) {
        strategies = common.read_json_file(custom_file);
    }
    if (!strategies || type(strategies) != "array" || length(strategies) == 0) {
        strategies = get_strategies_for_engine(engine, mode);
    }
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
        finished_at: 0
    };
    
    save_fuzzer_state(state);
    
    try {
        let highest_score = -1;
        let best = null;
        
        for (let i = 0; i < total; i++) {
            let strat = strategies[i];
            state.current_index = i + 1;
            state.current_strategy = strat;
            state.progress_pct = int(((i) / double(total)) * 100.0);
            save_fuzzer_state(state);
            
            let probe = run_probe(strat.engine || engine, strat.args, target_url);
            
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
                badge: ""
            };
            
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
        shell_quote(target || "youtube"),
        shell_quote(custom_url || ""),
        shell_quote(rule_section || ""),
        shell_quote(custom_file || ""),
        shell_quote(mode || "presets")
    );
    
    system(common.background_command_with_pid(cmd, ">/dev/null", ">" + shell_quote(PID_FILE)));
    
    print(sprintf("%J\n", { success: true, job_id, engine: engine || "zapret2", target: target || "youtube", mode: mode || "presets" }));
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

function apply_strategy(engine, args_val, target_rule) {
    engine = lc(as_string(engine));
    args_val = trim(as_string(args_val));
    target_rule = trim(as_string(target_rule));
    
    if (args_val == "") {
        print(sprintf("%J\n", { success: false, error: "Empty strategy arguments" }));
        return;
    }
    
    let uci = uci_core.cursor();
    let applied = false;
    
    // If target rule section is specified, update that rule
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
        // Apply as provider global setting
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
    
    // Mark reload pending
    system(common.background_command("tachyon reload"));
    
    print(sprintf("%J\n", {
        success: true,
        engine,
        applied_to: target_rule != "" ? target_rule : "global",
        args: args_val
    }));
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
} else if (op == "ai_synthesize" || op == "synthesize") {
    synthesize_ai_strategies(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
} else if (op == "generate" || op == "strategies_generate") {
    print(sprintf("%J\n", get_strategies_for_engine(ARGV[1], ARGV[2] || "combinatorial")));
} else if (op == "strategies") {
    let strat_mode = ARGV[1] || "presets";
    print(sprintf("%J\n", {
        available_engines: get_available_engines(),
        zapret2: get_strategies_for_engine("zapret2", strat_mode),
        zapret: get_strategies_for_engine("zapret", strat_mode),
        byedpi: get_strategies_for_engine("byedpi", strat_mode)
    }));
} else {
    warn("Usage: fuzzer.uc [start|status|stop|apply|strategies|generate|ai_synthesize|worker] ...\n");
    exit(1);
}
