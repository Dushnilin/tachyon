#!/usr/bin/env ucode
//
// Fuzzer strategy catalogue, presets and generators for native tachyon-core desync.
//
// Extracted from diagnostics/fuzzer.uc. Holds the built-in desync strategy
// matrix, preset loading/merging, combinatorial and adaptive generators, and
// the public "strategies" surface the CLI exposes.
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let fuzzer_runner = require("diagnostics.fuzzer_runner");
let history = require("diagnostics.fuzzer.history");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json_file = common.write_json_file;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";

const PATTERNS_FILE = "/etc/tachyon/fuzzer_patterns.json";
const BUILTIN_PRESETS_FILE = getenv("TACHYON_PRESETS_FILE") || "/usr/share/tachyon/dpi-presets.json";
const USER_PRESETS_FILE = "/etc/tachyon/dpi-presets-user.json";

const DEFAULT_PATTERNS = {
    desync: {
        presets: [ "auto", "fake_split", "fake_disorder", "multi_disorder", "multi_split", "tlsrec", "disorder", "split", "fake", "oob" ],
        modes: [ "fake_split", "fake_disorder", "multi_disorder", "multi_split", "tlsrec", "disorder", "split", "fake", "oob" ],
        splits: [ "midsld", "sni", "sniext+1", "host+1", "midsld-2", "endhost-1", "1", "2" ],
        foolings: [ "md5", "md5_badack", "badack", "datanoack", "autottl", "timestamp", "badseq", "badsum", "badseq_badack_badsum", "hopbyhop" ],
        ttls: [ 3, 4, 5, 6, 8 ],
        fake_snis: [ "www.google.com", "max.ru", "vk.com", "gosuslugi.ru", "rzd.ru", "ozon.ru", "padencap", "rndsni" ],
        repeats: [ 2, 4, 6, 8 ]
    },
    custom_strategies: []
};

let _builtin_presets_cache = null;
let _preset_autoid = 0;

const STRATEGIES_DESYNC = [
    // ── 1. BUILT-IN CORE PRESETS ───────────────────────────────────────────────
    {
        id: "ds_preset_auto",
        name: "Native Desync Preset: Adaptive 2.0 Autopilot (16 recipes + cache.db)",
        engine: "desync",
        args: "preset=auto",
        description: "Built-in tachyon-core 16-recipe autopilot with RST origin forensics, AutoTTL calibration, hedged probing, and UDP ladder."
    },
    {
        id: "ds_preset_fake_split",
        name: "Native Desync Preset: Fake + Split (midsld, TCP MD5, UDP Fake)",
        engine: "desync",
        args: "preset=fake_split",
        description: "Built-in tachyon-core default preset: RAW Fake ClientHello + mid-SLD TCP split + UDP QUIC/STUN fake."
    },
    {
        id: "ds_preset_fake_disorder",
        name: "Native Desync Preset: Fake + Disorder (Out-of-order MidSLD)",
        engine: "desync",
        args: "preset=fake_disorder",
        description: "Built-in tachyon-core RAW Fake ClientHello + out-of-order TCP segment delivery."
    },
    {
        id: "ds_preset_multi_disorder",
        name: "Native Desync Preset: Multi-Disorder (TLSRec + Fake + Multi-cut)",
        engine: "desync",
        args: "preset=multi_disorder",
        description: "Built-in tachyon-core TLS record pre-split + RAW Fake + reverse multi-segment disorder."
    },
    {
        id: "ds_preset_multi_split",
        name: "Native Desync Preset: Multi-Split (TLSRec + SNI + MidSLD)",
        engine: "desync",
        args: "preset=multi_split",
        description: "Built-in tachyon-core multi-point TCP segmentation without fake packets."
    },
    {
        id: "ds_preset_tlsrec",
        name: "Native Desync Preset: TLS Record Split (pos=sni)",
        engine: "desync",
        args: "preset=tlsrec",
        description: "Built-in tachyon-core RFC-compliant outer TLS Record splitting at SNI extension."
    },
    {
        id: "ds_preset_disorder",
        name: "Native Desync Preset: Out-of-order Disorder (pos=midsld)",
        engine: "desync",
        args: "preset=disorder",
        description: "Built-in tachyon-core out-of-order TCP segment delivery."
    },
    {
        id: "ds_preset_split",
        name: "Native Desync Preset: Mid-SLD Split",
        engine: "desync",
        args: "preset=split",
        description: "Built-in tachyon-core clean TCP segment split at middle of second-level domain."
    },
    {
        id: "ds_preset_fake",
        name: "Native Desync Preset: Low-TTL Fake Only (TTL=6, UDP Fake)",
        engine: "desync",
        args: "preset=fake",
        description: "Built-in tachyon-core fake ClientHello + UDP QUIC/STUN fake injection without splitting."
    },
    {
        id: "ds_preset_oob",
        name: "Native Desync Preset: TCP Out-Of-Band URG (pos=1)",
        engine: "desync",
        args: "preset=oob",
        description: "Built-in tachyon-core TCP MSG_OOB urgent byte injection + 1-byte split."
    },

    // ── 2. TUNED MODE & PARAMETER STRATEGIES ───────────────────────────────────
    {
        id: "ds_hostfakesplit_md5_badack_rzd",
        name: "HostFakeSplit + Disorder (sni,endhost-1, md5_badack, rzd.ru, seqovl=4)",
        engine: "desync",
        args: "mode=fake_disorder split_pos=sni,endhost-1 fooling=md5_badack fake_sni=rzd.ru seqovl=4 repeats=2",
        description: "In-band exact-length hostname replacement with valid-checksum TCP MD5 + BadAck + TS-Up combo."
    },
    {
        id: "ds_multidisorder_7point_md5_badack",
        name: "7-Point Multi-Disorder (md5_badack, rndsni, tlsrec_first)",
        engine: "desync",
        args: "mode=multi_disorder split_pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1 fooling=md5_badack fake_sni=rndsni tlsrec_first=true repeats=2",
        description: "Deep 7-point reverse disorder with TLS record pre-split and randomized same-length SNI."
    },
    {
        id: "ds_fakedisorder_badack_padencap",
        name: "Fake + Disorder (midsld+2, badack, padencap, seqovl=8)",
        engine: "desync",
        args: "mode=fake_disorder split_pos=midsld+2 fooling=badack fake_sni=padencap tlsrec_first=true seqovl=8 repeats=2",
        description: "Exact-length TLS padding encapsulation (padencap) with BadAck + TS-Up and 8-byte sequence overlap."
    },
    {
        id: "ds_fakesplit_datanoack_seqovl12",
        name: "Fake + Split (sniext+1, datanoack, gosuslugi.ru, seqovl=12)",
        engine: "desync",
        args: "mode=fake_split split_pos=sniext+1 fooling=datanoack fake_sni=gosuslugi.ru tlsrec_first=true seqovl=12 repeats=2",
        description: "Clears TCP ACK flag on decoy segments (datanoack) with 12-byte sequence overlap."
    },
    {
        id: "ds_multidisorder_combo_7point",
        name: "7-Point Multi-Disorder (badseq_badack_badsum, ozon.ru)",
        engine: "desync",
        args: "mode=multi_disorder split_pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1 fooling=badseq_badack_badsum fake_sni=ozon.ru tlsrec_first=true seqovl=4 repeats=2",
        description: "Compound BadSeq + BadAck + TS-Up + BadSum 7-point reverse disorder."
    },
    {
        id: "ds_fakedisorder_autottl_max",
        name: "HostFakeSplit + AutoTTL (sni,endhost-1, autottl, max.ru)",
        engine: "desync",
        args: "mode=fake_disorder split_pos=sni,endhost-1 fooling=autottl fake_sni=max.ru tlsrec_first=true repeats=2",
        description: "Calibrated hop-distance AutoTTL decoy injection with in-band HostFakeSplit."
    },
    {
        id: "ds_fake_split_midsld_ttl4_max",
        name: "Fake + Split (midsld, TTL=4, max.ru, repeats=6)",
        engine: "desync",
        args: "mode=fake_split split_pos=midsld fake_ttl=4 fake_sni=max.ru repeats=6",
        description: "Low-TTL max.ru fake ClientHello burst followed by mid-SLD split."
    },
    {
        id: "ds_fake_split_midsld_ttl6_google",
        name: "Fake + Split (midsld, TTL=6, www.google.com, repeats=6)",
        engine: "desync",
        args: "mode=fake_split split_pos=midsld fake_ttl=6 fake_sni=www.google.com repeats=6",
        description: "TTL=6 Google fake ClientHello burst followed by mid-SLD split."
    },
    {
        id: "ds_fake_split_sni_ttl5_gosuslugi",
        name: "Fake + Split (sni, TTL=5, gosuslugi.ru, repeats=6)",
        engine: "desync",
        args: "mode=fake_split split_pos=sni fake_ttl=5 fake_sni=gosuslugi.ru repeats=6",
        description: "Gosuslugi fake ClientHello with SNI extension boundary split."
    },
    {
        id: "ds_fake_split_pos1_ttl4_sber",
        name: "Fake + Split (pos=1, TTL=4, sberbank.ru, repeats=6)",
        engine: "desync",
        args: "mode=fake_split split_pos=1 fake_ttl=4 fake_sni=sberbank.ru repeats=6",
        description: "1-byte ClientHello split preceded by Sberbank low-TTL fake burst."
    },
    {
        id: "ds_fake_split_pos2_ttl8_max",
        name: "Fake + Split (pos=2, TTL=8, max.ru, repeats=8)",
        engine: "desync",
        args: "mode=fake_split split_pos=2 fake_ttl=8 fake_sni=max.ru repeats=8",
        description: "Higher TTL=8 fake burst for distant ISP transit middlebox hops + 2-byte split."
    },
    {
        id: "ds_tlsrec_midsld",
        name: "TLS Record Split (pos=midsld, delay=2ms)",
        engine: "desync",
        args: "mode=tlsrec split_pos=midsld split_delay_ms=2",
        description: "Splits outer TLS record header right at middle of domain name."
    },
    {
        id: "ds_tlsrec_pos2",
        name: "TLS Record Split (pos=2, delay=1ms)",
        engine: "desync",
        args: "mode=tlsrec split_pos=2 split_delay_ms=1",
        description: "2-byte TLS record split for stateless packet parsers."
    },
    {
        id: "ds_disorder_midsld",
        name: "TTL=1 Disorder (pos=midsld)",
        engine: "desync",
        args: "mode=disorder split_pos=midsld",
        description: "Drops initial segment up to mid-SLD at TTL=1 so real second segment arrives first."
    },
    {
        id: "ds_disorder_sni",
        name: "TTL=1 Disorder (pos=sni)",
        engine: "desync",
        args: "mode=disorder split_pos=sni",
        description: "Drops initial segment up to SNI extension at TTL=1 to desynchronize stateful reassembly."
    },
    {
        id: "ds_split_sni_delay2",
        name: "TCP Split (pos=sni, delay=2ms)",
        engine: "desync",
        args: "mode=split split_pos=sni split_delay_ms=2",
        description: "Clean TCP segmentation at SNI extension with 2ms pacing."
    },
    {
        id: "ds_oob_midsld",
        name: "TCP Out-Of-Band URG Desync (pos=midsld)",
        engine: "desync",
        args: "mode=oob split_pos=midsld",
        description: "Injects TCP URG out-of-band byte and splits at mid-SLD."
    },
    {
        id: "ds_discord_voice_combo",
        name: "Discord TCP + UDP Voice Fake Burst (midsld, TTL=6, UDP=8x)",
        engine: "desync",
        args: "mode=fake_split split_pos=midsld fake_ttl=6 fake_sni=www.google.com repeats=4 udp_fake=true udp_repeats=8 udp_fake_ttl=6",
        description: "Combined TCP Fake+Split and 8x UDP STUN/QUIC fake burst for Discord & WebRTC."
    },
    {
        id: "ds_cs2_faceit_udp_fake_6x",
        name: "CS2 / Faceit / Cybershoke: TCP Fake+Split + UDP Fake (6x, TTL=5, udplen=64)",
        engine: "desync",
        args: "mode=fake_split split_pos=midsld fake_ttl=5 fake_sni=www.google.com repeats=6 udp_fake=true udp_repeats=6 udp_fake_ttl=5 udplen=64",
        description: "Combined TCP SNI split and 6x UDP fake burst with 64-byte UDP padding for CS2, Faceit, and Cybershoke."
    },
    {
        id: "ds_cs2_faceit_udp_fake_8x_ttl6",
        name: "CS2 / Faceit / Cybershoke: TCP Fake+Split + UDP Fake (8x, TTL=6, udplen=128)",
        engine: "desync",
        args: "mode=fake_split split_pos=sni fake_ttl=6 fake_sni=max.ru repeats=6 udp_fake=true udp_repeats=8 udp_fake_ttl=6 udplen=128",
        description: "High-intensity 8x UDP fake burst with 128-byte UDP padding and SNI boundary split for game servers."
    },
    {
        id: "ds_cs2_faceit_syndata_udp",
        name: "CS2 / Faceit / Cybershoke: SYN Data + Disorder + UDP Fake (6x, TTL=4)",
        engine: "desync",
        args: "mode=disorder split_pos=midsld fake_ttl=4 syndata=true udp_fake=true udp_repeats=6 udp_fake_ttl=4 udplen=64",
        description: "TCP SYN payload injection with TTL=1 disorder and low-TTL UDP fake packets for stateful middleboxes."
    },
    {
        id: "ds_gaming_udp_only_ttl5",
        name: "Gaming & Voice UDP: Low-TTL UDP Fake Burst (8x, TTL=5, udplen=64)",
        engine: "desync",
        args: "mode=fake fake_ttl=5 repeats=4 udp_fake=true udp_repeats=8 udp_fake_ttl=5 udplen=64",
        description: "Dedicated UDP fake packet injection with length padding without TCP stream splitting."
    }
];

const PRESETS_MIRRORS = [
    "https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json",
    "https://gh-proxy.com/https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json",
    "https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/dpi-presets.json"
];

function validate_strategy_args(engine, args_val) {
    return fuzzer_runner.validate_strategy_args(engine, args_val);
}

function presets_file_candidates() {
    let list = [];
    if (getenv("TACHYON_PRESETS_FILE"))
        push(list, getenv("TACHYON_PRESETS_FILE"));
    push(list, "/usr/share/tachyon/dpi-presets.json");
    push(list, LIB_DIR + "/../share/tachyon/dpi-presets.json");
    return list;
}

function load_presets_file(path) {
    if (!path)
        return null;
    let data = read_json_file(path);
    if (!data || type(data) != "object")
        return null;
    return data;
}

function normalize_preset_entry(entry, engine) {
    if (!entry || type(entry) != "object")
        return null;
    let args = trim(as_string(entry.args));
    if (args == "")
        return null;
    let id = trim(as_string(entry.id));
    if (id == "") {
        _preset_autoid++;
        id = sprintf("preset_%s_%d", engine, _preset_autoid);
    }
    return {
        id: id,
        name: trim(as_string(entry.name)) || id,
        engine: engine,
        args: args,
        description: trim(as_string(entry.description)),
        source: trim(as_string(entry.source)) || "builtin",
        tags: type(entry.tags) == "array" ? entry.tags : []
    };
}

function load_builtin_presets() {
    if (_builtin_presets_cache != null)
        return _builtin_presets_cache;

    let result = { desync: [] };
    let sources = [];
    for (let p in presets_file_candidates()) {
        let data = load_presets_file(p);
        if (data) {
            push(sources, data);
            break;
        }
    }
    let user_data = load_presets_file(USER_PRESETS_FILE);
    if (user_data)
        push(sources, user_data);

    let seen = {};
    for (let data in sources) {
        let list = data.desync;
        if (type(list) != "array")
            continue;
        for (let raw in list) {
            let entry = normalize_preset_entry(raw, "desync");
            if (entry == null)
                continue;
            if (!fuzzer_runner.validate_strategy_args("desync", entry.args))
                continue;
            if (seen[entry.id])
                continue;
            seen[entry.id] = true;
            push(result.desync, entry);
        }
    }

    _builtin_presets_cache = result;
    return result;
}

function reset_presets_cache() {
    _builtin_presets_cache = null;
}

function get_patterns_config() {
    let custom = read_json_file(PATTERNS_FILE);
    if (custom && type(custom) == "object") {
        return {
            desync: custom.desync || DEFAULT_PATTERNS.desync,
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
    try { fs.unlink(PATTERNS_FILE); } catch (e) {}
    print(sprintf("%J\n", { success: true, message: "Patterns configuration reset to factory defaults", patterns: DEFAULT_PATTERNS }));
}

function generate_combinatorial_desync() {
    let cfg = get_patterns_config();
    let p = cfg.desync || DEFAULT_PATTERNS.desync;
    let list = [];
    let seen = {};

    let add = function(name, args, desc) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args("desync", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("ds_gen_%d", length(list) + 1),
            name: name,
            engine: "desync",
            args: args,
            description: desc
        });
    };

    for (let s in STRATEGIES_DESYNC) add(s.name, s.args, s.description);

    if (cfg.custom_strategies && length(cfg.custom_strategies) > 0) {
        for (let cs in cfg.custom_strategies) {
            if (cs && (cs.engine == "desync" || !cs.engine) && cs.args) {
                add(cs.name || "Custom Desync", cs.args, cs.description || "User custom strategy");
            }
        }
    }

    let presets = p.presets || DEFAULT_PATTERNS.desync.presets;
    for (let pr in presets) {
        add(sprintf("Preset: %s", pr), sprintf("preset=%s", pr), "Built-in tachyon-core desync preset");
    }

    let modes = p.modes || DEFAULT_PATTERNS.desync.modes;
    let splits = p.splits || p.split_poses || [ "1", "2", "midsld", "sni" ];
    let ttls = p.ttls || p.fake_ttls || [ 3, 4, 5, 6, 8 ];
    let fake_snis = p.fake_snis || [ "www.google.com", "max.ru", "gosuslugi.ru" ];

    for (let mode in modes) {
        for (let pos in splits) {
            if (index(mode, "fake") >= 0 || mode == "disorder") {
                for (let ttl in ttls) {
                    for (let fsni in fake_snis) {
                        add(sprintf("%s (pos=%s, TTL=%d, sni=%s)", mode, pos, ttl, fsni),
                            sprintf("mode=%s split_pos=%s fake_ttl=%d fake_sni=%s repeats=6", mode, pos, ttl, fsni),
                            "Combinatorial native desync fake + split/disorder");
                        add(sprintf("%s + UDP Fake (pos=%s, TTL=%d, sni=%s, udplen=64)", mode, pos, ttl, fsni),
                            sprintf("mode=%s split_pos=%s fake_ttl=%d fake_sni=%s repeats=6 udp_fake=true udp_repeats=6 udp_fake_ttl=%d udplen=64", mode, pos, ttl, fsni, ttl),
                            "Combinatorial native desync TCP + UDP game/voice fake burst");
                    }
                }
            } else {
                add(sprintf("%s (pos=%s)", mode, pos),
                    sprintf("mode=%s split_pos=%s", mode, pos),
                    "Combinatorial native desync segmentation");
                add(sprintf("%s (pos=%s, delay=2ms)", mode, pos),
                    sprintf("mode=%s split_pos=%s split_delay_ms=2", mode, pos),
                    "Combinatorial native desync segmentation with 2ms delay");
            }
        }
    }

    return list;
}

const TARGET_PORT_PROFILES = {
    discord: {
        key: "discord",
        label: "Discord",
        match: [ "discord" ]
    },
    cs2_faceit: {
        key: "cs2_faceit",
        label: "CS2 / Faceit",
        match: [ "cs2", "faceit", "cybershoke", "gaming_udp" ]
    }
};

function target_port_profile(target) {
    let name = lc(as_string(target || ""));
    for (let id in TARGET_PORT_PROFILES) {
        for (let needle in TARGET_PORT_PROFILES[id].match) {
            if (index(name, needle) >= 0)
                return TARGET_PORT_PROFILES[id];
        }
    }
    return null;
}

function target_port_profiles_list(target) {
    let name = lc(as_string(target || ""));
    let matched = [];
    for (let id in TARGET_PORT_PROFILES) {
        for (let needle in TARGET_PORT_PROFILES[id].match) {
            if (index(name, needle) >= 0) {
                push(matched, TARGET_PORT_PROFILES[id]);
                break;
            }
        }
    }
    return matched;
}

function target_port_strategies(engine, target) {
    engine = lc(as_string(engine || "desync"));
    if (engine != "desync")
        return [];

    let profiles = target_port_profiles_list(target);
    if (length(profiles) == 0)
        return [];

    let list = [];
    let seen = {};
    for (let profile in profiles) {
        let lbl = profile.label || "Discord";
        let add = function(name, args, desc) {
            args = trim(as_string(args));
            if (args == "" || seen[args]) return;
            if (!fuzzer_runner.validate_strategy_args("desync", args)) return;
            seen[args] = true;
            push(list, {
                id: sprintf("port_desync_%s_%d", profile.key, length(list) + 1),
                name: name,
                engine: "desync",
                args: args,
                description: desc,
                rationale: "Target-tuned TCP+UDP native desync profile",
                target_ports: true
            });
        };

        add(sprintf("%s TCP+UDP Fake Burst (TTL=5, UDP=6x, udplen=64)", lbl),
            "mode=fake_split split_pos=midsld fake_ttl=5 fake_sni=www.google.com repeats=6 udp_fake=true udp_repeats=6 udp_fake_ttl=5 udplen=64",
            "Combined TCP SNI split + UDP fake packet burst with 64B UDP padding");
        add(sprintf("%s TCP+UDP Fake Burst (TTL=6, UDP=8x, udplen=128)", lbl),
            "mode=fake_split split_pos=sni fake_ttl=6 fake_sni=max.ru repeats=6 udp_fake=true udp_repeats=8 udp_fake_ttl=6 udplen=128",
            "Combined TCP SNI split + 8x UDP fake packet burst with 128B UDP padding");
    }

    return list;
}

function generate_adaptive_strategies(engine, target) {
    engine = lc(as_string(engine || "desync"));
    if (engine != "desync")
        return [];

    let list = [];
    let seen = {};

    let add_ds = function(name, args, desc, rationale) {
        args = trim(as_string(args));
        if (args == "" || seen[args]) return;
        if (!fuzzer_runner.validate_strategy_args("desync", args)) return;
        seen[args] = true;
        push(list, {
            id: sprintf("adapt_desync_%d", length(list) + 1),
            name: name,
            engine: "desync",
            args: args,
            description: desc || "Adaptive native desync strategy",
            rationale: rationale || "Synthesized from target profile for tachyon-core desync"
        });
    };

    // 1. Seed from Prior History: inject historic winning strategies for this target
    let history_res = history.get_history(20);
    if (history_res && length(history_res) > 0) {
        for (let h in history_res) {
            if (h && h.target == target && h.best_strategy && h.engine == "desync") {
                let bs = h.best_strategy;
                if (bs.args && !seen[bs.args]) {
                    add_ds("Prior Winner: " + (bs.name || "Historical Best"), bs.args, "Previously verified effective on this target", "Historical success seed");
                }
            }
        }
    }

    // 2. Native desync strategies
    for (let s in STRATEGIES_DESYNC) {
        add_ds(s.name, s.args, s.description, "Built-in tachyon-core desync seed");
    }

    // 3. Target-scoped TCP+UDP profiles
    for (let ps in target_port_strategies("desync", target)) {
        if (!seen[ps.args]) {
            seen[ps.args] = true;
            push(list, ps);
        }
    }

    // Check memory budget: if low RAM (<32MB), cap to 20 strategies
    let avail_kb = fuzzer_runner.get_system_memory_kb();
    if (avail_kb < 32768 && length(list) > 20) {
        let capped = [];
        for (let i = 0; i < 20; i++) push(capped, list[i]);
        return capped;
    }

    return list;
}

function target_includes_udp(target) {
    let t = lc(trim(as_string(target || "")));
    if (t == "")
        return true;
    return index(t, "quic_http3") >= 0 ||
        index(t, "gaming_udp") >= 0 ||
        index(t, "discord") >= 0 ||
        index(t, "cs2") >= 0 ||
        index(t, "faceit") >= 0 ||
        index(t, "udp://") >= 0;
}

function is_pure_udp_strategy(s) {
    if (!s) return false;
    let a = lc(as_string(s.args || ""));
    if (lc(as_string(s.engine || "")) == "desync" &&
        index(a, "udp_fake=true") >= 0 &&
        index(a, "mode=") < 0 &&
        index(a, "preset=") < 0)
        return true;
    return false;
}

function filter_strategies_for_target(list, target) {
    if (!target || trim(as_string(target)) == "" || target_includes_udp(target))
        return list;
    let filtered = [];
    for (let s in list) {
        if (!is_pure_udp_strategy(s))
            push(filtered, s);
    }
    return filtered;
}

function get_strategies_for_engine(engine, mode, target) {
    engine = lc(as_string(engine || "desync"));
    if (engine != "desync")
        return [];
    mode = lc(trim(as_string(mode || "presets")));
    let cfg = get_patterns_config();

    if (mode == "custom" || mode == "user") {
        let custom_list = [];
        for (let cs in cfg.custom_strategies) {
            if (cs && (cs.engine == "desync" || !cs.engine) && cs.args) {
                push(custom_list, {
                    id: cs.id || sprintf("custom_%d", length(custom_list) + 1),
                    name: cs.name || "Custom Strategy",
                    engine: "desync",
                    args: cs.args,
                    description: cs.description || ""
                });
            }
        }
        return filter_strategies_for_target(custom_list, target);
    }

    if (mode == "adaptive" || mode == "smart") {
        return filter_strategies_for_target(generate_adaptive_strategies("desync", target || "youtube_suite"), target);
    }

    if (mode == "combinatorial" || mode == "deep_fuzz" || mode == "deep") {
        let combo = generate_combinatorial_desync();
        combo = filter_strategies_for_target(combo, target);
        let avail_kb = fuzzer_runner.get_system_memory_kb();
        if (avail_kb < 32768 && length(combo) > 30) {
            let capped = [];
            for (let i = 0; i < 30; i++) push(capped, combo[i]);
            return capped;
        }
        return combo;
    }

    let result = [];
    let seen_args = {};

    // Seed prior winners from history if available
    let history_res = history.get_history(10);
    if (history_res && length(history_res) > 0) {
        for (let h in history_res) {
            if (h && target && h.target == target && h.best_strategy && h.engine == "desync") {
                let bs = h.best_strategy;
                if (bs.args && !seen_args[bs.args]) {
                    seen_args[bs.args] = true;
                    push(result, {
                        id: "hist_desync_1",
                        name: bs.name || "Historical Best",
                        engine: "desync",
                        args: bs.args,
                        description: "Previously verified winner on this target"
                    });
                }
            }
        }
    }

    for (let s in STRATEGIES_DESYNC) {
        if (!seen_args[s.args]) {
            seen_args[s.args] = true;
            push(result, s);
        }
    }

    // Curated presets from dpi-presets.json and user presets file
    let presets = load_builtin_presets();
    let list = presets.desync;
    if (type(list) == "array") {
        for (let p in list) {
            if (p.args == "" || seen_args[p.args])
                continue;
            if (!fuzzer_runner.validate_strategy_args("desync", p.args))
                continue;
            seen_args[p.args] = true;
            push(result, {
                id: p.id,
                name: p.name,
                engine: "desync",
                args: p.args,
                description: p.description,
                source: p.source,
                tags: p.tags
            });
        }
    }

    for (let cs in cfg.custom_strategies) {
        if (cs && (cs.engine == "desync" || !cs.engine) && cs.args && !seen_args[cs.args]) {
            seen_args[cs.args] = true;
            push(result, {
                id: cs.id || sprintf("custom_%d", length(result) + 1),
                name: cs.name || "Custom Strategy",
                engine: "desync",
                args: cs.args,
                description: cs.description || "User custom strategy"
            });
        }
    }

    for (let ps in target_port_strategies("desync", target)) {
        if (seen_args[ps.args]) continue;
        seen_args[ps.args] = true;
        push(result, ps);
    }

    return filter_strategies_for_target(result, target);
}

function get_presets_info() {
    reset_presets_cache();
    let presets = load_builtin_presets();
    let sources = {};
    let tags = {};
    let counts = { desync: 0 };
    let list = presets.desync;
    if (type(list) == "array") {
        for (let p in list) {
            counts.desync++;
            sources[p.source] = true;
            for (let t in p.tags)
                tags[t] = true;
        }
    }
    let source_list = [];
    for (let s, _v in sources)
        push(source_list, s);
    let tag_list = [];
    for (let t, _v in tags)
        push(tag_list, t);
    return {
        success: true,
        counts: counts,
        sources: source_list,
        tags: tag_list,
        user_presets_file: USER_PRESETS_FILE,
        builtin_presets_file: BUILTIN_PRESETS_FILE
    };
}

function update_presets() {
    let tmp = "/tmp/tachyon-presets-download.json";
    let downloaded = false;
    let last_err = "";
    for (let url in PRESETS_MIRRORS) {
        try { fs.unlink(tmp); } catch (e) {}
        let rc = system(sprintf("curl -fsSL --connect-timeout 10 --max-time 30 -o %s %s >/dev/null 2>&1",
            common.shell_quote(tmp), common.shell_quote(url)));
        if (rc == 0 && fs.stat(tmp) != null) {
            let parsed = read_json_file(tmp);
            if (parsed && type(parsed) == "object") {
                downloaded = true;
                break;
            }
            last_err = "Downloaded presets file is not valid JSON";
        } else {
            last_err = "Failed to download presets from mirror";
        }
    }
    try { fs.unlink(tmp); } catch (e) {}
    if (!downloaded) {
        print(sprintf("%J\n", { success: false, error: last_err || "All preset mirrors failed" }));
        return;
    }
    print(sprintf("%J\n", {
        success: true,
        message: "Built-in presets are shipped with the package; update the tachyon package to refresh them",
        user_presets_file: USER_PRESETS_FILE
    }));
}

function module_exports() {
    return {
        DEFAULT_PATTERNS,
        STRATEGIES_DESYNC,
        PATTERNS_FILE,
        BUILTIN_PRESETS_FILE,
        USER_PRESETS_FILE,
        PRESETS_MIRRORS,
        TARGET_PORT_PROFILES,
        target_port_profile,
        target_port_strategies,
        validate_strategy_args,
        presets_file_candidates,
        load_presets_file,
        normalize_preset_entry,
        load_builtin_presets,
        reset_presets_cache,
        get_patterns_config,
        save_patterns_config,
        reset_patterns_config,
        generate_combinatorial_desync,
        generate_adaptive_strategies,
        get_strategies_for_engine,
        get_presets_info,
        update_presets
    };
}

return module_exports();
