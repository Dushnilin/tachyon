#!/usr/bin/env ucode

let common = require("core.common");
let constants = require("core.constants");
let fs = require("fs");
let validator_module = null;

let as_string = common.as_string;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";

function validator() {
    if (validator_module == null)
        validator_module = require("providers.zapret2.validator");
    return validator_module;
}

const KNOWN_BLOB_FILES = {
    tls_max: { file: "tls_clienthello_max_ru.bin", size: 654 },
    tls_google: { file: "tls_clienthello_www_google_com.bin", size: 681 },
    tls_gosuslugi: { file: "tls_clienthello_gosuslugi_ru.bin", size: 517 },
    tls_sber: { file: "tls_clienthello_sberbank_ru.bin", size: 517 },
    tls_iana: { file: "tls_clienthello_iana_org.bin", size: 517 },
    tls_vk: { file: "tls_clienthello_vk_com.bin", size: 517 },
    tls_onetrust: { file: "tls_clienthello_www_onetrust_com.bin", size: 664 },
    quic_google: { file: "quic_initial_www_google_com.bin", size: 1200 },
    quic_yt1: { file: "quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_1.bin", size: 1230 },
    quic_vk: { file: "quic_initial_vk_com.bin", size: 1357 },
    stun_fake: { file: "stun.bin", size: 100 },
    discord_udp: { file: "stun.bin", size: 100 }
};

function get_blob_dir() {
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

function resolve_blobs(args_str) {
    if (!args_str || args_str == "") return [];
    let bdir = get_blob_dir();
    let result = [];
    for (let name, info in KNOWN_BLOB_FILES) {
        if ((index(args_str, "blob=" + name) >= 0 || index(args_str, "seqovl_pattern=" + name) >= 0) &&
            index(args_str, "--blob=" + name + ":") < 0) {
            let blob_path = bdir + "/" + info.file;
            if (fs.stat(blob_path) != null || fs.stat("/opt/zapret2/files/fake/" + info.file) != null) {
                let actual_path = fs.stat(blob_path) != null ? blob_path : ("/opt/zapret2/files/fake/" + info.file);
                push(result, sprintf("--blob=%s:@%s", name, actual_path));
            }
        }
    }
    return result;
}

function safe_str(val) {
    if (type(as_string) == "function")
        return as_string(val);
    if (val == null)
        return "";
    return "" + val;
}

function prepare_strategy_args(raw_opt) {
    let raw_str = safe_str(raw_opt);
    let extra_args = resolve_blobs(raw_str);
    let filter_prefix = [];
    if (index(raw_str, "--filter-tcp") < 0 && index(raw_str, "--filter-l7") < 0 && index(raw_str, "--filter-udp") < 0) {
        push(filter_prefix, "--filter-tcp=443");
        push(filter_prefix, "--filter-l7=tls");
        push(filter_prefix, "--payload=tls_client_hello");
    }
    let words = [];
    for (let arg in extra_args) push(words, arg);
    for (let f in filter_prefix) push(words, f);
    return words;
}

function config(ctx) {
    let runtime_constants = (ctx && ctx.constants) || constants;
    let lib_dir = (ctx && ctx.lib_dir) || LIB_DIR;
    let desync_mark = getenv("ZAPRET2_DESYNC_MARK") || runtime_constants.ZAPRET2_DESYNC_MARK;
    let provider_lua_dir = getenv("ZAPRET2_PROVIDER_LUA_DIR") || runtime_constants.ZAPRET2_PROVIDER_LUA_DIR;

    let candidate_dirs = [
        provider_lua_dir,
        "/opt/zapret2/lua",
        "/opt/zapret/lua",
        "/usr/share/zapret2/lua",
        "/usr/share/zapret/lua",
        "/etc/zapret2/lua",
        "/etc/zapret/lua",
        "/usr/lib/zapret2/lua",
        "/usr/lib/zapret/lua",
        lib_dir + "/providers/zapret2/lua"
    ];

    let base_args = [
        "--fwmark=" + desync_mark
    ];
    let lua_scripts = [
        "zapret-lib.lua",
        "zapret-antidpi.lua",
        "zapret-auto.lua"
    ];
    for (let script in lua_scripts) {
        let found = null;
        for (let dir in candidate_dirs) {
            if (!dir)
                continue;
            let p = dir + "/" + script;
            if (fs.stat(p) != null) {
                found = p;
                break;
            }
            if (fs.stat(p + ".gz") != null) {
                found = p + ".gz";
                break;
            }
        }
        if (found != null)
            push(base_args, "--lua-init=@" + found);
    }

    let candidate_bins = [
        getenv("ZAPRET2_NFQWS2_BIN"),
        getenv("ZAPRET2_PROVIDER_NFQWS2_BIN"),
        runtime_constants.ZAPRET2_PROVIDER_NFQWS2_BIN,
        "/opt/zapret2/nfq2/nfqws2",
        "/opt/zapret2/nfq/nfqws2",
        "/opt/zapret2/nfqws2",
        "/usr/bin/nfqws2"
    ];
    let resolved_bin = runtime_constants.ZAPRET2_PROVIDER_NFQWS2_BIN;
    for (let b in candidate_bins) {
        if (b && fs.stat(b) != null) {
            resolved_bin = b;
            break;
        }
    }

    return {
        kind: "zapret2",
        action: "zapret2",
        binary_name: "nfqws2",
        binary: resolved_bin,
        provider_bin: resolved_bin,
        provider_files_dir: getenv("ZAPRET2_PROVIDER_FILES_DIR") || runtime_constants.ZAPRET2_PROVIDER_FILES_DIR,
        provider_ipset_dir: getenv("ZAPRET2_PROVIDER_IPSET_DIR") || runtime_constants.ZAPRET2_PROVIDER_IPSET_DIR,
        provider_lua_dir,
        state_dir: getenv("ZAPRET2_STATE_DIR") || runtime_constants.ZAPRET2_STATE_DIR,
        pid_dir: getenv("ZAPRET2_PID_DIR") || runtime_constants.ZAPRET2_PID_DIR,
        child_pid_dir: getenv("ZAPRET2_CHILD_PID_DIR") || runtime_constants.ZAPRET2_CHILD_PID_DIR,
        log_dir: getenv("ZAPRET2_LOG_DIR") || runtime_constants.ZAPRET2_LOG_DIR,
        route_mark_base: getenv("ZAPRET2_ROUTE_MARK_BASE") || runtime_constants.ZAPRET2_ROUTE_MARK_BASE,
        queue_base: getenv("ZAPRET2_QUEUE_BASE") || runtime_constants.ZAPRET2_QUEUE_BASE,
        queue_range_size: getenv("ZAPRET2_QUEUE_RANGE_SIZE") || runtime_constants.ZAPRET2_QUEUE_RANGE_SIZE,
        respawn_delay: getenv("ZAPRET2_NFQWS2_RESPAWN_DELAY") || runtime_constants.ZAPRET2_NFQWS2_RESPAWN_DELAY,
        desync_mark,
        desync_mark_postnat: getenv("ZAPRET2_DESYNC_MARK_POSTNAT") || runtime_constants.ZAPRET2_DESYNC_MARK_POSTNAT,
        default_strategy: getenv("ZAPRET2_DEFAULT_NFQWS2_OPT") || runtime_constants.ZAPRET2_DEFAULT_NFQWS2_OPT,
        legacy_default_strategy: "",
        strategy_option: "nfqws2_opt",
        validator_kind: "nfqws2",
        validator,
        package_name: "zapret2",
        runtime_path: lib_dir + "/providers/zapret2/runtime.uc",
        check_path: lib_dir + "/providers/zapret2/check.uc",
        luci_package: "luci-app-zapret2",
        luci_menu: "/usr/share/luci/menu.d/luci-app-zapret2.json",
        luci_acl: "/usr/share/rpcd/acl.d/luci-app-zapret2.json",
        service_init: "/etc/init.d/zapret2",
        config_name: "zapret2",
        legacy_runtime_base: "",
        hostlist_dir: "",
        status_label: "zapret2",
        check_prefix: "zapret2",
        base_args,
        prepare_strategy_args
    };
}

return {
    config,
    validator
};