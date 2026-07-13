#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
'

printf 'config/connections checks passed\n'
