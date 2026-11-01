#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

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

let twitch_candidates = url.download_candidates("https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs");
assert(twitch_candidates[0] == "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/twitch.srs", "twitch candidate 0 is raw github");
assert(twitch_candidates[1] == "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/twitch.srs", "twitch candidate 1 is jsdelivr cdn");
for (let c in twitch_candidates) {
    assert(index(c, "forkop") < 0, "no forkop mirrors allowed");
}

for (let original in [
    "https://provider.example/sub/private-token",
    "https://ghfast.top/https://github.com/owner/repo/raw/main/file",
    "https://provider.example/github.com/owner/repo/blob/main/file",
    "https://provider.example/sub?url=https://github.com/owner/repo/blob/main/file",
    "https://github.com.provider.example/sub",
    "https://raw.githubusercontent.com@provider.example/sub",
    "https://provider.example/sub#github.com",
    "file:///tmp/github.com/owner/repo/blob/main/file"
]) {
    let direct = url.download_candidates(original);
    assert(length(direct) == 1 && direct[0] == original, "non-GitHub URL must stay unchanged: " + original);
}
assert(length(url.download_candidates("https://api.github.com/repos/owner/repo/releases/latest")) > 1, "GitHub API keeps mirrors");
assert(length(url.download_candidates("https://release-assets.githubusercontent.com/asset")) > 1, "GitHub release assets keep mirrors");

// authority, host, port, userinfo with @ in query parameters
let complex = "vless://user-uuid@example.com:8443?authority=name@channel&mode=gun#my-fragment";
assert(url.authority(complex) == "example.com:8443", "authority strips userinfo and query with @");
assert(url.host(complex) == "example.com", "host with @ in query parameters");
assert(url.port(complex) == "8443", "port with @ in query parameters");
assert(url.userinfo(complex) == "user-uuid", "userinfo with @ in query parameters");
'

printf 'core/url checks passed\n'
