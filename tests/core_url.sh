#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

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

// normalize_github_raw
assert(url.normalize_github_raw("https://github.com/owner/repo/blob/main/path/to/hosts") == "https://raw.githubusercontent.com/owner/repo/main/path/to/hosts", "normalize blob url");
assert(url.normalize_github_raw("https://github.com/owner/repo/raw/main/path/to/hosts") == "https://raw.githubusercontent.com/owner/repo/main/path/to/hosts", "normalize raw url");
assert(url.normalize_github_raw("https://raw.githubusercontent.com/owner/repo/main/path/to/hosts") == "https://raw.githubusercontent.com/owner/repo/main/path/to/hosts", "keep raw url");
assert(url.normalize_github_raw("https://example.com/hosts.txt") == "https://example.com/hosts.txt", "keep non-github url");

// github_to_jsdelivr
assert(url.github_to_jsdelivr("https://github.com/owner/repo/blob/main/path/to/hosts") == "https://cdn.jsdelivr.net/gh/owner/repo@main/path/to/hosts", "jsdelivr from blob");
assert(url.github_to_jsdelivr("https://raw.githubusercontent.com/owner/repo/main/path/to/hosts") == "https://cdn.jsdelivr.net/gh/owner/repo@main/path/to/hosts", "jsdelivr from raw");

// download_candidates
let candidates = url.download_candidates("https://github.com/owner/repo/blob/main/hosts");
assert(candidates[0] == "https://raw.githubusercontent.com/owner/repo/main/hosts", "download_candidates first entry normalized");
'

printf 'core/url checks passed\n'
