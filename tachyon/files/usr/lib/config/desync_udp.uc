#!/usr/bin/env ucode

let common = require("core.common");

const KEYS = [ "udp_fake_payload", "udp_out_range", "udp_keep_socket" ];

function strategy_value(key, value) {
    if (key == "udp_keep_socket") {
        let normalized = lc(value);
        if (normalized in [ "1", "true", "yes", "on" ])
            return true;
        if (normalized in [ "0", "false", "no", "off" ])
            return false;
    }
    if (key == "udp_out_range" && match(value, /^[0-9]{1,3}$/))
        return int(value, 10);

    // Pass invalid explicit values to Core check as well. In particular an
    // unknown boolean must not be coerced to false.
    return value;
}

function apply(outbound, section, is_custom) {
    let values = {};
    for (let key in KEYS) {
        let value = trim(common.as_string(common.option(section, "desync_" + key, "")));
        if (value != "")
            values[key] = value;
    }

    if (is_custom) {
        let opts = trim(common.as_string(common.option(section, "desync_opts", "")));
        for (let token in split(opts, /\s+/)) {
            let eq = index(token, "=");
            if (eq <= 0)
                continue;
            let key = lc(substr(token, 0, eq));
            if (substr(key, 0, 2) == "--")
                key = replace(substr(key, 2), /-/g, "_");
            if (substr(key, 0, 11) == "dpi_desync_")
                key = substr(key, 11);
            if (key in KEYS)
                values[key] = trim(substr(token, eq + 1));
        }
    }

    for (let key, value in values)
        outbound[key] = strategy_value(key, value);
}

function configured(outbound) {
    for (let key in KEYS) {
        if (outbound[key] != null)
            return true;
    }
    return false;
}

return { apply, configured };
