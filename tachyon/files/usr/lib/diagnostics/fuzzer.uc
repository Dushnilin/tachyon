#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

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

// Target definitions
const TARGET_URLS = {
    youtube: "https://rr1---sn-4g5edn6r.googlevideo.com/generate_204",
    youtube_web: "https://www.youtube.com",
    discord: "https://discord.com/api/v9/gateway",
    instagram: "https://www.instagram.com",
    rutracker: "https://rutracker.org",
    telegram: "https://web.telegram.org"
};

// Strategy Matrices
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
        name: "Fake Packet + MidSLD Disorder",
        engine: "zapret2",
        args: "--lua-desync=fake:ttl=8 --lua-desync=multisplit:pos=midsld:fooling=badseq",
        description: "Injects low-TTL fake ClientHello before segmented payload."
    },
    {
        id: "z2_wsize_multisplit",
        name: "Window Size Clamp (wsize=1)",
        engine: "zapret2",
        args: "--lua-desync=multisplit:pos=1,midsld:wsize=1:fooling=badseq",
        description: "Forces single-byte TCP window segments to evade reassembly."
    },
    {
        id: "z2_aggressive_combo",
        name: "Aggressive Triple-Split + SeqOvl",
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
        id: "z2_discord_udp",
        name: "Discord Voice UDP Desync",
        engine: "zapret2",
        args: "--filter-udp=50000-65535 --lua-desync=fake:ttl=8",
        description: "UDP fake packet desync for Discord RTC and Voice channels."
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
        id: "z1_disorder2_badseq",
        name: "Disorder2 + BadSeq",
        engine: "zapret",
        args: "--dpi-desync=disorder2 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq",
        description: "Sends out-of-order packets with invalid TCP sequence fooling."
    },
    {
        id: "z1_fake_split2_ttl",
        name: "Fake SNI + Split2 (TTL=8)",
        engine: "zapret",
        args: "--dpi-desync=fake,split2 --dpi-desync-split-pos=1 --dpi-desync-ttl=8 --dpi-desync-fooling=badseq",
        description: "Sends low-TTL fake packet followed by segmented ClientHello."
    },
    {
        id: "z1_seqovl_split2",
        name: "Sequence Overlap (SeqOvl=1)",
        engine: "zapret",
        args: "--dpi-desync=split2 --dpi-desync-split-seqovl=1 --dpi-desync-fooling=badseq",
        description: "Overlapping TCP payload to confuse stateful DPI."
    },
    {
        id: "z1_md5sig_disorder",
        name: "MD5Sig Fooling + Disorder",
        engine: "zapret",
        args: "--dpi-desync=fake,disorder2 --dpi-desync-fooling=md5sig --dpi-desync-ttl=6",
        description: "Injects TCP MD5 signature option to trigger DPI packet drop."
    }
];

const STRATEGIES_BYEDPI = [
    {
        id: "bd_auto_tr_d2",
        name: "ByeDPI Auto (t,r,a,s)",
        engine: "byedpi",
        args: "-o 2 --auto=t,r,a,s -d 2",
        description: "Standard adaptive ByeDPI auto-mode with disorder."
    },
    {
        id: "bd_disorder_fake_ttl8",
        name: "Disorder + Fake (TTL=8)",
        engine: "byedpi",
        args: "--split 1 --disorder 1 --fake -1 --ttl 8",
        description: "1-byte split with reverse disorder and fake handshake packet."
    },
    {
        id: "bd_midsld_fake_frag",
        name: "SNI Extension + Fake (TTL=6)",
        engine: "byedpi",
        args: "-s 1+sniext -f -1 -t 6",
        description: "SNI extension split with low-TTL fake payload."
    },
    {
        id: "bd_tls_sni_split2",
        name: "TLS SNI Split (pos=2)",
        engine: "byedpi",
        args: "--split 2 --disorder 2",
        description: "Direct TLS SNI offset split with out-of-order delivery."
    },
    {
        id: "bd_low_ttl_aggressive",
        name: "Aggressive Fake (TTL=4)",
        engine: "byedpi",
        args: "--fake -1 --ttl 4 --disorder 1 --split 1",
        description: "Low-TTL aggressive fake packet injection."
    }
];

function get_strategies_for_engine(engine) {
    engine = lc(as_string(engine));
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

function run_fuzzer_worker(engine, target, custom_url, rule_section) {
    let target_url = resolve_target_url(target, custom_url);
    let strategies = get_strategies_for_engine(engine);
    let total = length(strategies);
    
    let state = {
        running: true,
        job_id: sprintf("fuzz_%d", clock()[0]),
        engine,
        target,
        target_url,
        rule_section: as_string(rule_section),
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
            
            let probe = run_probe(strat.engine, strat.args, target_url);
            
            let item_result = {
                id: strat.id,
                name: strat.name,
                engine: strat.engine,
                args: strat.args,
                description: strat.description,
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

function start_fuzzer(engine, target, custom_url, rule_section) {
    let current = get_fuzzer_state();
    if (current.running) {
        print(sprintf("%J\n", { success: false, error: "Fuzzer is already running", job_id: current.job_id }));
        return;
    }
    
    ensure_state_dir();
    
    let job_id = sprintf("fuzz_%d", clock()[0]);
    let cmd = sprintf(
        "ucode -L /usr/lib/tachyon /usr/lib/tachyon/diagnostics/fuzzer.uc worker %s %s %s %s",
        shell_quote(engine || "zapret2"),
        shell_quote(target || "youtube"),
        shell_quote(custom_url || ""),
        shell_quote(rule_section || "")
    );
    
    system(common.background_command_with_pid(cmd, ">/dev/null", ">" + shell_quote(PID_FILE)));
    
    print(sprintf("%J\n", { success: true, job_id, engine: engine || "zapret2", target: target || "youtube" }));
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
    start_fuzzer(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
} else if (op == "worker") {
    run_fuzzer_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
} else if (op == "status") {
    print(sprintf("%J\n", get_fuzzer_state()));
} else if (op == "stop") {
    stop_fuzzer();
} else if (op == "apply") {
    apply_strategy(ARGV[1], ARGV[2], ARGV[3]);
} else if (op == "strategies") {
    print(sprintf("%J\n", {
        available_engines: get_available_engines(),
        zapret2: STRATEGIES_ZAPRET2,
        zapret: STRATEGIES_ZAPRET,
        byedpi: STRATEGIES_BYEDPI
    }));
} else {
    warn("Usage: fuzzer.uc [start|status|stop|apply|strategies|worker] ...\n");
    exit(1);
}
