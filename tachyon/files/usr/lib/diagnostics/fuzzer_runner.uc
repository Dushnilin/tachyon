#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
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
    // URL must start with http:// or https://, no shell metacharacters
    return match(url, /^https?:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*(:[0-9]{1,5})?(\/[^\s;`$&|<>'"\\]*)?$/) != null;
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

function validate_strategy_args(engine, args_val) {
    engine = lc(as_string(engine));
    if (engine != "zapret" && engine != "zapret2" && engine != "byedpi")
        return false;

    let tok_res = tokenize_strategy_args(args_val);
    if (!tok_res.valid)
        return false;

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

function kill_pid_file(path) {
    let pid_str = fs.readfile(path);
    if (pid_str) {
        let pid = trim(as_string(pid_str));
        if (pid != "" && match(pid, /^[0-9]+$/) != null) {
            system(sprintf("kill %s >/dev/null 2>&1 || kill -9 %s >/dev/null 2>&1", pid, pid));
            for (let k = 0; k < 3; k++) {
                if (system(sprintf("kill -0 %s >/dev/null 2>&1", pid)) != 0) break;
                system("sleep 0.1");
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
    is_valid_hostname,
    is_valid_url,
    tokenize_strategy_args,
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
