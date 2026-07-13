#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

ucode -L "$TACHYON_LIB" -e '
let url = require("core.url");

function assert(val, msg) {
    if (!val) {
        warn("Assertion failed: " + msg + "\n");
        exit(1);
    }
}

// scheme
assert(url.scheme("http://example.com") == "http", "scheme of http");
assert(url.scheme("HTTPS://example.com") == "https", "scheme of HTTPS should be lowercase");
assert(url.scheme("example.com") == "", "no scheme");

// fragment
assert(url.fragment("http://example.com#test") == "test", "fragment of url");
assert(url.fragment("http://example.com#test+space") == "test space", "fragment space decoding");
assert(url.fragment("http://example.com") == "", "no fragment");

// strip_fragment
assert(url.strip_fragment("http://example.com#test") == "http://example.com", "strip fragment");
assert(url.strip_fragment("http://example.com") == "http://example.com", "strip no fragment");

// strip_anchored_scheme
assert(url.strip_anchored_scheme("http://example.com") == "example.com", "strip anchored http");
assert(url.strip_anchored_scheme("example.com") == "example.com", "strip no scheme");
'

printf 'core/url checks passed\n'
