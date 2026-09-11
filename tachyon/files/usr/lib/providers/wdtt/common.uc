let constants = require("core.constants");

function config(ctx) {
    let env_get = function(key, fallback) {
        let val = getenv(key);
        return val != null ? val : fallback;
    };

    return {
        kind: "wdtt",
        action: "wdtt",
        config_path: env_get("TACHYON_WDTT_CONFIG", "/etc/config/wdtt"),
        qwdtt_config_path: env_get("TACHYON_QWDTT_CONFIG", "/etc/qwdtt/config.json"),
        service_init: env_get("TACHYON_WDTT_SERVICE_INIT", "/etc/init.d/wdtt-client"),
        qwdtt_service_init: env_get("TACHYON_QWDTT_SERVICE_INIT", "/etc/init.d/qwdtt"),
        binary: env_get("TACHYON_QWDTT_BIN", "/usr/bin/qwdtt-client"),
        genlists_bin: env_get("TACHYON_WDTT_GENLISTS_BIN", "/usr/sbin/wdtt-genlists"),
        resolve_bin: env_get("TACHYON_WDTT_RESOLVE_BIN", "/usr/sbin/wdtt-resolve"),
        hashes_dir: env_get("TACHYON_WDTT_HASHES_DIR", "/etc/wdtt"),
        captcha_token_default: "/var/run/qwdtt/captcha.token",
        default_peer: "YOUR_SERVER:56000",
        default_workers_qwdtt: "9",
        default_workers_wdtt: "36",
        default_max_hashes: "4",
        default_mode: "selective",
        default_mtu: "1280",
        default_refresh: "15m",
        default_socks_port_base: 1080,
        package_name: "wdtt",
        runtime_path: ctx.lib_dir + "/providers/wdtt/runtime.uc",
        config_name: "tachyon",
        status_label: "wdtt",
        check_prefix: "wdtt"
    };
}

function validator() {
    return require("providers.wdtt.validator");
}

return { config, validator };
