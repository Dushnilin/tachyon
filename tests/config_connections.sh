#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi

# Create mock uci module
cat >"$WORK_DIR/uci.uc" <<'UCODE'
let state = {
    tachyon: {
        sub1: {
            ".name": "sub1",
            ".type": "subscription_url",
            url: "https://example.com/sub.txt"
        },
        group1: {
            ".name": "group1",
            ".type": "urltest",
            ports: [ "80", "443" ]
        }
    }
};

function cursor() {
    return {
        load: function(_package_name) {
            return true;
        },
        foreach: function(package_name, type_name, callback) {
            let pkg = state["" + package_name] || {};
            for (let name in pkg) {
                let section = pkg[name];
                if (section && section[".type"] == type_name) {
                    callback(section);
                }
            }
        }
    };
}

return { cursor };
UCODE

ucode -L "$WORK_DIR" -L "$TACHYON_LIB" -e '
let connections = require("config.connections");
let cursor = require("uci").cursor();

function assert(val, msg) {
    if (!val) {
        warn("Assertion failed: " + msg + "\n");
        exit(1);
    }
}

let index = connections.item_index_from_cursor(cursor, "tachyon");
assert(index.subscription_url.by_name.sub1.url == "https://example.com/sub.txt", "parse subscription URL");
assert(index.urltest.by_name.group1.ports[0] == "80", "parse urltest group ports");

// Exercise owner lookups through the fixture and cursor indexes.
let a = { ".name": "a" };
let b = { ".name": "b" };
let children = [
    { ".name": "missing", section: "a" },
    { ".name": "second", section: "a", order: "5" },
    { ".name": "first", section: "a", order: "1" },
    { ".name": "tied", section: "a", order: "5" },
    { ".name": "unowned" }
];
let levels = [
    { ".name": "z", group: "pg", order: "1" },
    { ".name": "y", group: "pg", order: "1" }
];
connections.set_item_sections_from_data({ urltest: children, priority_level: levels });
let expected = slice(children, 0, 4);
sort(expected, (left, right) => int(left.order || "99") - int(right.order || "99"));
assert(join(",", connections.urltests(a)) == join(",", map(expected, (child) => child[".name"])),
    "numeric, tied and missing order");
assert(join(",", connections.urltests({})) == "unowned", "empty owner");
assert(length(connections.urltests(b)) == 0, "owner without children");
assert(join(",", connections.priority_levels("pg")) == "y,z", "priority tie sorts by name");

children[1].section = "b";
children[2].order = "9";
splice(children, 0, 1);
push(children, { ".name": "added", section: "a", order: "0" });
connections.set_item_sections_from_cursor({
    foreach: function(config, type_name, callback) {
        if (type_name == "urltest")
            for (let child in children)
                callback(child);
    }
}, "tachyon");
assert(join(",", connections.urltests(a)) == "added,tied,first", "index rebuild after edit, add and delete");
assert(join(",", connections.urltests(b)) == "second", "index rebuild after changing owner");
connections.set_item_sections(null);
assert(length(connections.urltests(a)) == 0, "null invalidates cursor owner lookups");

// geoip_country_list and geoip_country_mode tests
let geo_res = connections.geoip_country_list({ geoip_country: [ "ru", "de", "ru" ] });
assert(geo_res[0] == "ru" && geo_res[1] == "de" && length(geo_res) == 2, "geoip list de-duplicate");
assert(connections.geoip_country_list({ geoip_country: "non-ru" })[0] == "ru", "geoip non-ru alias");
assert(connections.geoip_country_mode({ geoip_country: "non-ru" }) == "exclude", "geoip mode for non-ru");
assert(connections.geoip_country_mode({}) == "exclude", "geoip mode default empty");
assert(connections.geoip_country_mode({ geoip_country: "ru" }) == "exclude", "geoip mode default country without mode");
// packet_encoding tests
assert(connections.packet_encoding({}) == "", "packet encoding default empty");
assert(connections.packet_encoding({ packet_encoding: "xudp" }) == "xudp", "packet encoding xudp");
assert(connections.packet_encoding({ packet_encoding: "XUDP" }) == "xudp", "packet encoding XUDP uppercase");
assert(connections.packet_encoding({ packet_encoding: "packetaddr" }) == "packetaddr", "packet encoding packetaddr");
assert(connections.packet_encoding({ packet_encoding: "disabled" }) == "disabled", "packet encoding disabled");
assert(connections.packet_encoding({ packet_encoding: "invalid" }) == "", "packet encoding invalid fallback");
'

printf 'config/connections checks passed\n'
