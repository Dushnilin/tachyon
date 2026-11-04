#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Execute the real lifecycle functions with named sections that are deliberately
# different from their types. No network or live UCI writes are involved.
cat >"$WORK_DIR/test.uc" <<'UCODE'
let CONFIG_NAME = "tachyon";
let TMP_RULESET_FOLDER = "/unused";
let needed = [];
let writes = [];
let fs = {};
let common = {};
let write_file = function(path, content) { return true; };
let uci_core = {
    get_all: function(pkg, name) {
        if (name != "settings") die("get_all used as a type filter\n");
        return {};
    },
    section_objects: function(pkg, kind) {
        if (kind == "condition") return [
            { ".name": "country_filter", geoip_country: "ru" },
            { ".name": "disabled_filter", enabled: "0", community_lists: ["disabled"] }
        ];
        return [
            { ".name": "main", action: "awg", awg_server_address: "example.test", community_lists: ["youtube"] },
            { ".name": "off", enabled: "0", action: "awg", awg_server_address: "off.test", community_lists: ["disabled"] },
            { ".name": "fixed", action: "awg", awg_server_address: "fixed.test", awg_mtu: "1280" }
        ];
    }
};
let modules = {
    "tachyon_core.rulesets": {
        is_community: function(name) { return true; },
        supports_trs: function() { return true; },
        is_referenceable_trs_file: function(path) { push(needed, path); return true; }
    },
    "core.url": {},
    "config.connections": {
        community_lists: function(s) { return []; },
        rule_sets: function(s) { return []; },
        rule_sets_with_subnets: function(s) { return []; },
        geoip_country_list: function(s) { return s.geoip_country ? [s.geoip_country] : []; }
    },
    "service.smart_detect_exclusions": { selected_lists: function(s) { return []; } }
};
let require = function(name) { return modules[name]; };
let as_string = function(v) { return "" + v; };
let command_success_from_args = function(args) { return true; };
let command_status = function(cmd) { return 0; };
let command_from_args = function(args) { push(writes, args); return ""; };
let remove_file = function(path) {};
let log_message = function(msg, level) {};
let mark_internal_config_guard = function() {};
UCODE
sed -n '/^function discover_awg_mtu(/,/^}/p' "$TACHYON_LIB/service/lifecycle.uc" >>"$WORK_DIR/test.uc"
sed -n '/^function prepare_community_rulesets(/,/^}/p' "$TACHYON_LIB/service/lifecycle.uc" >>"$WORK_DIR/test.uc"
cat >>"$WORK_DIR/test.uc" <<'UCODE'
discover_awg_mtu();
if (length(writes) != 2 || writes[0][length(writes[0])-1] != "example.test" ||
    writes[1][2] != "tachyon.main.awg_mtu=1500")
    die("AWG enumeration or enabled/explicit-MTU filtering failed\n");
prepare_community_rulesets();
if (length(needed) != 3 ||
    !("/unused/community-youtube.trs" in needed) ||
    !("/unused/community-geoip_ru.trs" in needed) ||
    !("/unused/community-geosite_ru.trs" in needed))
    die("named sections/conditions were not prepared\n");
print("service UCI enumeration passed\n");
UCODE
ucode -S "$WORK_DIR/test.uc"
