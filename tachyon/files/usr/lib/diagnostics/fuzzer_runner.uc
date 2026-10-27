#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let as_string = common.as_string;
let shell_quote = common.shell_quote;

function is_valid_hostname(host) {
    host = trim(as_string(host));
    if (host == "" || length(host) > 253) return false;
    // Allow IPv4 address
    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return true;
    // RFC 1123 hostname check
    return match(host, /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/) != null;
}

function is_valid_url(url) {
    url = trim(as_string(url));
    if (url == "" || length(url) > 1024) return false;
    // URL must start with http:// or https://, no shell metacharacters. The path
    // class is an explicit list: "\s" inside a character class is not whitespace in
    // this engine, it is the two characters "\" and "s", so "[^\s...]" also rejected
    // every path containing the letter s - /users, /status, /api/v9/users/@me all
    // came back invalid and a custom fuzzer target was refused for no stated reason.
    return match(url, /^https?:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*(:[0-9]{1,5})?(\/[^ \t\r\n;`$&|<>'"\\]*)?$/) != null;
}

function tokenize_strategy_args(raw_args) {
    let str = trim(as_string(raw_args));
    if (str == "")
        return { valid: false, tokens: [], error: "Empty strategy string" };

    if (length(str) > 2048)
        return { valid: false, tokens: [], error: "Strategy string exceeds maximum length (2048)" };

    // Strict rejection of shell metacharacters
    if (match(str, /[;&|`$\r\n<>'\\(){}]/))
        return { valid: false, tokens: [], error: "Strategy contains forbidden shell characters" };

    let raw_tokens = split(str, /[ \t]+/);
    if (length(raw_tokens) == 0)
        return { valid: false, tokens: [], error: "No tokens found" };

    if (length(raw_tokens) > 64)
        return { valid: false, tokens: [], error: "Strategy exceeds maximum token limit (64)" };

    let tokens = [];
    for (let t in raw_tokens) {
        let tok = trim(t);
        if (tok == "") continue;
        if (length(tok) > 256)
            return { valid: false, tokens: [], error: "Token exceeds maximum length (256): " + tok };

        // Whitelist permitted characters: alphanumeric, -, _, ., /, :, =, +, @, ,, #, ~, %
        if (!match(tok, /^[-a-zA-Z0-9_./:=+@,#~%]+$/))
            return { valid: false, tokens: [], error: "Token contains forbidden characters: " + tok };

        push(tokens, tok);
    }

    if (length(tokens) == 0)
        return { valid: false, tokens: [], error: "No valid tokens found" };

    return { valid: true, tokens: tokens };
}

const DESYNC_PRESETS = [
    "fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "auto",
    // Legacy aliases mapped to valid tachyon-core presets/parameters
    "general", "general_alt", "general_alt2", "general_alt3", "general_alt4",
    "general_alt5", "general_alt6", "general_alt7", "general_alt8", "general_alt9",
    "general_alt10", "general_alt11", "general_fake_tls", "general_fake_tls_alt",
    "general_fake_tls_alt2", "general_fake_tls_alt3", "general_simple_fake",
    "general_simple_fake_alt", "general_simple_fake_alt2",
    "youtube", "google_youtube", "discord", "cloudflare", "aggressive", "light"
];

const DESYNC_MODES = [
    "fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "none",
    // Legacy aliases mapped to valid tachyon-core modes
    "fake+split", "fake+disorder", "multisplit", "multidisorder",
    "fake_disorder", "tlsrec_split", "fakedsplit", "fakeddisorder", "syndata"
];

function normalize_desync_preset(lv, outbound) {
    if (lv == "fakesplit" || lv == "fake_split") return "fake_split";
    if (lv == "tls_rec" || lv == "tlsrec") return "tlsrec";
    if (lv == "split" || lv == "disorder" || lv == "fake" || lv == "oob" || lv == "auto") return lv;
    if (lv == "youtube" || lv == "google_youtube") {
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
        if (outbound.fake_ttl == null) outbound.fake_ttl = 6;
        if (outbound.fake_sni == null) outbound.fake_sni = "www.google.com";
        if (outbound.udp_fake == null) outbound.udp_fake = true;
        return "fake_split";
    }
    if (lv == "discord") {
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
        if (outbound.fake_ttl == null) outbound.fake_ttl = 6;
        if (outbound.udp_fake == null) outbound.udp_fake = true;
        if (outbound.udp_repeats == null) outbound.udp_repeats = 6;
        return "fake_split";
    }
    if (lv == "cloudflare" || lv == "light") {
        if (outbound.split_pos == null) outbound.split_pos = "sni";
        return "tlsrec";
    }
    if (lv == "aggressive" || index(lv, "general_alt") == 0) {
        if (outbound.split_pos == null) outbound.split_pos = 1;
        if (outbound.fake_ttl == null) outbound.fake_ttl = 4;
        return "disorder";
    }
    if (index(lv, "general") == 0) {
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
        if (outbound.fake_ttl == null) outbound.fake_ttl = 5;
        if (outbound.fake_sni == null) outbound.fake_sni = "max.ru";
        return "fake_split";
    }
    return "fake_split";
}

function normalize_desync_mode(lv) {
    if (lv == "fake_split" || lv == "fakesplit" || lv == "fake+split" || lv == "fakedsplit")
        return "fake_split";
    if (lv == "disorder" || lv == "fake_disorder" || lv == "fake+disorder" || lv == "fakeddisorder" || lv == "multidisorder")
        return "disorder";
    if (lv == "split" || lv == "multisplit" || lv == "syndata")
        return "split";
    if (lv == "tlsrec" || lv == "tls_rec" || lv == "tlsrec_split")
        return "tlsrec";
    if (lv == "fake" || lv == "oob" || lv == "none")
        return lv;
    return "fake_split";
}

function parse_desync_outbound(args_val, tag_name) {
    let tok_res = tokenize_strategy_args(args_val);
    if (!tok_res.valid)
        return null;

    let outbound = {
        type: "desync",
        tag: as_string(tag_name || "desync-out")
    };
    let recognized = 0;

    for (let tok in tok_res.tokens) {
        let eq = index(tok, "=");
        if (eq <= 0)
            return null;
        let k = lc(trim(substr(tok, 0, eq)));
        let v = trim(substr(tok, eq + 1));
        if (v == "")
            return null;

        if (k == "preset") {
            let lv = lc(v);
            if (index(DESYNC_PRESETS, lv) < 0)
                return null;
            outbound.preset = normalize_desync_preset(lv, outbound);
            recognized++;
        } else if (k == "mode") {
            let lv = lc(v);
            if (index(DESYNC_MODES, lv) < 0)
                return null;
            outbound.mode = normalize_desync_mode(lv);
            recognized++;
        } else if (k == "split_pos") {
            let lv = lc(v);
            if (lv == "midsld" || lv == "sld" || lv == "host") {
                outbound.split_pos = "midsld";
            } else if (lv == "sni" || lv == "sniext") {
                outbound.split_pos = "sni";
            } else if (match(v, /^[0-9]+$/)) {
                let n = int(v);
                if (n < 1 || n > 1400) return null;
                outbound.split_pos = n;
            } else {
                return null;
            }
            recognized++;
        } else if (k == "fake_ttl" || k == "ttl") {
            if (!match(v, /^[0-9]+$/)) return null;
            let n = int(v);
            if (n < 1 || n > 128) return null;
            outbound.fake_ttl = n;
            recognized++;
        } else if (k == "fake_sni") {
            if (!is_valid_hostname(v)) return null;
            outbound.fake_sni = v;
            recognized++;
        } else if (k == "repeats") {
            if (!match(v, /^[0-9]+$/)) return null;
            let n = int(v);
            if (n < 1 || n > 100) return null;
            outbound.repeats = n;
            recognized++;
        } else if (k == "split_delay_ms") {
            if (!match(v, /^[0-9]+$/)) return null;
            let n = int(v);
            if (n < 0 || n > 1000) return null;
            outbound.split_delay_ms = n;
            recognized++;
        } else if (k == "udp_fake") {
            let lv = lc(v);
            if (lv == "true" || lv == "1") outbound.udp_fake = true;
            else if (lv == "false" || lv == "0") outbound.udp_fake = false;
            else return null;
            recognized++;
        } else if (k == "udp_repeats") {
            if (!match(v, /^[0-9]+$/)) return null;
            let n = int(v);
            if (n < 1 || n > 50) return null;
            outbound.udp_repeats = n;
            recognized++;
        } else if (k == "udp_fake_ttl") {
            if (!match(v, /^[0-9]+$/)) return null;
            let n = int(v);
            if (n < 1 || n > 128) return null;
            outbound.udp_fake_ttl = n;
            recognized++;
        } else {
            return null;
        }
    }

    if (recognized <= 0 || (outbound.preset == null && outbound.mode == null))
        return null;

    // In tachyon-core <= 0.1.7, DesyncMode::FakeSplit and DesyncMode::Fake write
    // fake_payload directly into the connected TcpStream before the real ClientHello,
    // which advances SND.NXT and causes the kernel TCP stack to retransmit fake_payload
    // to the origin server with normal TTL. Using "disorder" (low-TTL first segment +
    // out-of-order retransmission) or "tlsrec" preserves a valid TCP sequence stream
    // while keeping all split_pos, fake_ttl, repeats and udp_fake parameters active.
    if (outbound.preset == "fake_split" || outbound.preset == "auto") {
        outbound.preset = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
        if (outbound.udp_fake == null) outbound.udp_fake = true;
    } else if (outbound.preset == "fake") {
        outbound.preset = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = 1;
        if (outbound.udp_fake == null) outbound.udp_fake = true;
    }
    if (outbound.mode == "fake_split") {
        outbound.mode = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
    } else if (outbound.mode == "fake") {
        outbound.mode = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = 1;
    }

    return outbound;
}

function validate_strategy_args(engine, args_val) {
    engine = lc(as_string(engine));
    if (engine != "zapret" && engine != "zapret2" && engine != "byedpi" && engine != "desync")
        return false;

    let tok_res = tokenize_strategy_args(args_val);
    if (!tok_res.valid)
        return false;

    if (engine == "desync")
        return parse_desync_outbound(args_val, "desync-out") != null;

    try {
        if (engine == "zapret2") {
            let val = require("providers.zapret2.validator");
            let res = val.validate_strategy("nfqws2", args_val, "");
            return (res && res.valid === true) ? true : false;
        } else if (engine == "zapret") {
            let val = require("providers.zapret.validator");
            let res = val.validate_strategy("nfqws", args_val, "");
            return (res && res.valid === true) ? true : false;
        } else if (engine == "byedpi") {
            let val = require("providers.byedpi.validator");
            let fn = val.validate_byedpi_strategy || val.validate_strategy;
            let res = fn ? fn(args_val) : null;
            return (res && res.valid === true) ? true : false;
        }
    } catch (e) {
        return false;
    }
    return false;
}

function build_byedpi_argv(bin, port, tokens) {
    let argv = [ bin, "-i", "127.0.0.1", "-p", sprintf("%d", port) ];
    for (let tok in tokens)
        push(argv, tok);
    return argv;
}

function build_zapret_argv(bin, qnum, fwmark_flag, lua_init_flags, blob_flags, filter_prefix, tokens) {
    let argv = [ bin, sprintf("--qnum=%d", qnum) ];

    let append_flags = function(flag_str) {
        if (!flag_str || flag_str == "") return;
        let parts = split(trim(flag_str), /[ \t]+/);
        for (let p in parts) {
            if (p != "") push(argv, p);
        }
    };

    append_flags(fwmark_flag);
    append_flags(lua_init_flags);
    append_flags(blob_flags);
    append_flags(filter_prefix);

    let has_bind_fix4 = false;
    let has_bind_fix6 = false;
    for (let a in argv) {
        if (a == "--bind-fix4") has_bind_fix4 = true;
        if (a == "--bind-fix6") has_bind_fix6 = true;
    }

    for (let tok in tokens) {
        if (tok == "--daemon" || index(tok, "--pidfile") == 0)
            continue;
        if (tok == "--bind-fix4") has_bind_fix4 = true;
        if (tok == "--bind-fix6") has_bind_fix6 = true;
        let m_lua = match(tok, /^--lua-init=@(.+)$/);
        if (m_lua && m_lua[1]) {
            let lp = m_lua[1];
            if (fs.stat(lp) == null && fs.stat(lp + ".gz") != null) {
                tok = "--lua-init=@" + lp + ".gz";
            }
        }
        push(argv, tok);
    }

    if (!has_bind_fix4) push(argv, "--bind-fix4");
    if (!has_bind_fix6) push(argv, "--bind-fix6");

    return argv;
}

function find_child_pids(parent_pid) {
    let children = [];
    let p_int = int(parent_pid);
    if (p_int <= 1) return children;
    let procs = fs.glob("/proc/[0-9]*/stat");
    if (!procs) return children;
    for (let st_path in procs) {
        let data = fs.readfile(st_path);
        if (!data) continue;
        let rparen = rindex(data, ")");
        if (rparen < 0) continue;
        let m_pid = match(substr(data, 0, rparen), /^([0-9]+)[ \t]+\(/);
        let rest = trim(substr(data, rparen + 1));
        let fields = split(rest, /[ \t]+/);
        if (m_pid && m_pid[1] && length(fields) >= 2 && int(fields[1]) == p_int) {
            push(children, m_pid[1]);
        }
    }
    return children;
}

function kill_pid_file(path) {
    let pid_str = fs.readfile(path);
    if (pid_str) {
        let pid = trim(as_string(pid_str));
        if (pid != "" && match(pid, /^[0-9]+$/) != null) {
            let children = find_child_pids(pid);
            for (let c in children) {
                for (let gc in find_child_pids(c)) {
                    if (fs.stat("/proc/" + gc) != null)
                        exec.command_status_from_args([ "kill", "-9", "" + gc ]);
                }
                if (fs.stat("/proc/" + c) != null)
                    exec.command_status_from_args([ "kill", "-9", "" + c ]);
            }
            if (fs.stat("/proc/" + pid) != null)
                exec.command_status_from_args([ "kill", "" + pid ]);
            for (let k = 0; k < 3; k++) {
                if (fs.stat("/proc/" + pid) == null) break;
                exec.command_status_from_args([ "sleep", "0.1" ]);
            }
            if (fs.stat("/proc/" + pid) != null) {
                exec.command_status_from_args([ "kill", "-9", "" + pid ]);
                exec.command_status_from_args([ "sleep", "0.1" ]);
            }
        }
        try { fs.unlink(path); } catch (e) {}
    }
}

function get_system_capabilities() {
    let caps = {
        http2: false,
        http3: false,
        doh: false
    };
    let p = fs.popen("curl -V 2>/dev/null", "r");
    if (!p) return caps;
    let out = p.read("all");
    p.close();
    if (!out || out == "") return caps;

    let lout = lc(out);
    if (index(lout, "http2") >= 0) caps.http2 = true;
    if (index(lout, "http3") >= 0 || index(lout, "nghttp3") >= 0 || index(lout, "quiche") >= 0 || index(lout, "msh3") >= 0) caps.http3 = true;
    if (index(lout, "doh") >= 0) caps.doh = true;
    return caps;
}

function get_system_memory_kb() {
    let data = fs.readfile("/proc/meminfo");
    if (!data) return 999999;
    let m = match(data, /MemAvailable:[ \t]+([0-9]+)[ \t]+kB/);
    if (m && m[1]) return int(m[1]);
    let mf = match(data, /MemFree:[ \t]+([0-9]+)[ \t]+kB/);
    if (mf && mf[1]) return int(mf[1]);
    return 999999;
}

function calculate_median(values) {
    if (!values || length(values) == 0) return 0;
    let copy = [];
    for (let v in values) push(copy, 1.0 * v);
    sort(copy, function(a, b) { return a - b; });
    let n = length(copy);
    let mid = int(n / 2);
    if (n % 2 == 1) return int(copy[mid]);
    return int((copy[mid - 1] + copy[mid]) / 2.0);
}

function calculate_p25(values) {
    if (!values || length(values) == 0) return 0;
    let copy = [];
    for (let v in values) push(copy, 1.0 * v);
    sort(copy, function(a, b) { return a - b; });
    let idx = int(length(copy) * 0.25);
    return int(copy[idx]);
}

function calculate_jitter(values, median_val) {
    if (!values || length(values) <= 1) return 0;
    let sum_dev = 0.0;
    for (let v in values) {
        let diff = (1.0 * v) - (1.0 * median_val);
        if (diff < 0) diff = -diff;
        sum_dev += diff;
    }
    return int(sum_dev / (1.0 * length(values)));
}

return {
    DESYNC_PRESETS,
    DESYNC_MODES,
    is_valid_hostname,
    is_valid_url,
    tokenize_strategy_args,
    parse_desync_outbound,
    validate_strategy_args,
    build_byedpi_argv,
    build_zapret_argv,
    kill_pid_file,
    get_system_capabilities,
    get_system_memory_kb,
    calculate_median,
    calculate_p25,
    calculate_jitter
};
