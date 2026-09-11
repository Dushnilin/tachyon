let constants = require("core.constants");

function config(ctx) {
    let env_get = function(key, fallback) {
        let val = getenv(key);
        return val != null ? val : fallback;
    };

    return {
        kind: "olcrtc",
        action: "olcrtc",
        config_path: env_get("TACHYON_OLCRTC_CONFIG", "/etc/olcrtc/client.yaml"),
        service_init: env_get("TACHYON_OLCRTC_SERVICE_INIT", "/etc/init.d/olcrtc"),
        binary: env_get("TACHYON_OLCRTC_BIN", "/usr/bin/olcrtc"),
        default_socks_host: "127.0.0.1",
        default_socks_port: "1080",
        default_dns: "8.8.8.8:53",
        default_provider: "jitsi",
        default_transport: "datachannel",
        package_name: "olcrtc",
        runtime_path: ctx.lib_dir + "/providers/olcrtc/runtime.uc",
        config_name: "olcrtc",
        status_label: "olcrtc",
        check_prefix: "olcrtc"
    };
}

function validator() {
    return require("providers.olcrtc.validator");
}

return { config, validator };
