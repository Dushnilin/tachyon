#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Create a mock uci state with 3 subscriptions in a section, where UCI file order is sub1, sub2, sub3,
# but order options specify: sub2 (order 0), sub3 (order 1), sub1 (order 2)
cat >"$WORK_DIR/uci.uc" <<'UCODE'
let state = {
    tachyon: {
        sec1: {
            ".name": "sec1",
            ".type": "section",
            action: "connection",
            enabled: "1"
        },
        sub1: {
            ".name": "sub1",
            ".type": "subscription_url",
            section: "sec1",
            url: "https://example.com/third.txt",
            order: "2"
        },
        sub2: {
            ".name": "sub2",
            ".type": "subscription_url",
            section: "sec1",
            url: "https://example.com/first.txt",
            order: "0"
        },
        sub3: {
            ".name": "sub3",
            ".type": "subscription_url",
            section: "sec1",
            url: "https://example.com/second.txt",
            order: "1"
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
connections.set_item_sections_from_cursor(cursor, "tachyon");

let sec = { ".name": "sec1", action: "connection" };
let urls = connections.subscription_urls(sec);

assert(length(urls) == 3, "expected 3 subscription urls, got " + length(urls));
assert(urls[0] == "https://example.com/first.txt", "expected first url at index 0, got " + urls[0]);
assert(urls[1] == "https://example.com/second.txt", "expected second url at index 1, got " + urls[1]);
assert(urls[2] == "https://example.com/third.txt", "expected third url at index 2, got " + urls[2]);
'

# 2. Test fallback when items do not have order option: they should maintain their original order
cat >"$WORK_DIR/uci_no_order.uc" <<'UCODE'
let state = {
    tachyon: {
        sec1: {
            ".name": "sec1",
            ".type": "section",
            action: "connection",
            enabled: "1"
        },
        subA: {
            ".name": "subA",
            ".type": "subscription_url",
            section: "sec1",
            url: "https://example.com/alpha.txt"
        },
        subB: {
            ".name": "subB",
            ".type": "subscription_url",
            section: "sec1",
            url: "https://example.com/beta.txt"
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
let cursor = require("uci_no_order").cursor();

function assert(val, msg) {
    if (!val) {
        warn("Assertion failed: " + msg + "\n");
        exit(1);
    }
}

connections.set_item_sections_from_cursor(cursor, "tachyon");

let sec = { ".name": "sec1", action: "connection" };
let urls = connections.subscription_urls(sec);

assert(length(urls) == 2, "expected 2 subscription urls");
assert(urls[0] == "https://example.com/alpha.txt", "expected alpha first");
assert(urls[1] == "https://example.com/beta.txt", "expected beta second");
'

echo "PASS: subscription_section_order"
