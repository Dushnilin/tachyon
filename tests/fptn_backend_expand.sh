#!/usr/bin/env bash
# FPTN parity with a connection section: the backend decodes the token itself
# and emits one outbound per server, an auto urltest over them, and the section
# selector on top. The old shape - a single fptn outbound carrying the token
# under the section tag - made the core expand it into a urltest group wearing
# that tag, and every dashboard group switch against it came back as Clash API
# 400 "Must be a Selector".
#
# It also has to degrade gracefully: anything the backend cannot decode (fptnb:
# brotli without a core binary on the box, a malformed payload) keeps the old
# raw-token outbound and lets the core expand the token itself.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

# fptn_transport_mode() reports "native" only on tachyon-core, keyed off the
# variant marker file - never off a version string, both families ship a
# sing-box binary. The test image has no fptn-client component, so with the
# marker in place the mode resolves to native deterministically.
printf 'tachyon-core\n' > "$WORK_DIR/sing-box-variant"
export SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant"
# A saved selector default must not be able to move the assertions.
export TACHYON_PERSISTENT_SELECTOR_STATE_FILE="$WORK_DIR/selector_state.json"

generate_fixture() {
  local fixture="$1" output="$2"
  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1" "0" "1"
}

# ---------------------------------------------------------------------------
# 1. A decodable fptn: token expands into members + auto urltest + selector.
# ---------------------------------------------------------------------------

TOKEN_PAYLOAD='{"version":1,"service_name":"MyVPN","username":"user1","password":"pass1","servers":[{"name":"Alpha","host":"10.0.0.1","port":443,"md5_fingerprint":"00112233445566778899aabbccddeeff"},{"name":"Beta","host":"10.0.0.2","port":8443}]}'
TOKEN="fptn:$(printf '%s' "$TOKEN_PAYLOAD" | base64 | tr -d '\n')"

cat > "$WORK_DIR/fixture_plain.json" <<EOF_JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "FptnSec",
      ".type": "section",
      "enabled": "1",
      "action": "fptn",
      "match_all": "1",
      "access_token": "$TOKEN"
    }
  ]
}
EOF_JSON

output="$WORK_DIR/out_plain.json"
generate_fixture "$WORK_DIR/fixture_plain.json" "$output" ||
  fail "generate-config-fixture rejected the decodable fptn fixture"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
if (type(cfg) != "object") { warn("config is not JSON\n"); exit(1); }

let by_tag = {};
for (let o in cfg.outbounds || []) {
    if (type(o) == "object" && o.tag != null)
        by_tag[o.tag] = o;
}

let alpha = by_tag["FptnSec-out/Alpha"];
let beta = by_tag["FptnSec-out/Beta"];
if (alpha == null || beta == null) {
    warn("per-server fptn outbounds are missing\n"); exit(1);
}
if (alpha.type != "fptn" || alpha.server != "10.0.0.1" || alpha.server_port != 443 ||
    alpha.username != "user1" || alpha.password != "pass1" ||
    alpha.md5_fingerprint != "00112233445566778899aabbccddeeff") {
    warn("Alpha dial fields mismatch: " + json(alpha) + "\n"); exit(1);
}
if (beta.type != "fptn" || beta.server != "10.0.0.2" || beta.server_port != 8443) {
    warn("Beta dial fields mismatch: " + json(beta) + "\n"); exit(1);
}
if (beta.md5_fingerprint != null && beta.md5_fingerprint != "") {
    warn("Beta must not carry a fingerprint it never had\n"); exit(1);
}

let group = by_tag["FptnSec-urltest-out"];
if (group == null || group.type != "urltest") {
    warn("auto urltest group is missing\n"); exit(1);
}
if (group.outbounds == null || length(group.outbounds) != 2 ||
    group.outbounds[0] != "FptnSec-out/Alpha" || group.outbounds[1] != "FptnSec-out/Beta") {
    warn("auto urltest group members mismatch: " + json(group.outbounds) + "\n"); exit(1);
}
if (group.url != null || group.interval != null || group.tolerance != null) {
    warn("the auto group must stay bare, like the core own expansion\n"); exit(1);
}

let selector = by_tag["FptnSec-out"];
if (selector == null || selector.type != "selector") {
    warn("the section tag must be a selector - the Clash API rejects a group switch against a urltest group\n");
    exit(1);
}
if (selector.default != "FptnSec-urltest-out") {
    warn("selector must default to the auto urltest group, got " + json(selector.default) + "\n");
    exit(1);
}
if (selector.outbounds == null || index(selector.outbounds, "FptnSec-out/Alpha") < 0 ||
    index(selector.outbounds, "FptnSec-out/Beta") < 0 ||
    index(selector.outbounds, "FptnSec-urltest-out") < 0) {
    warn("selector outbounds mismatch: " + json(selector.outbounds) + "\n"); exit(1);
}

for (let o in cfg.outbounds || []) {
    if (type(o) == "object" && o.token != null) {
        warn("a raw-token fptn outbound survived a successful decode\n"); exit(1);
    }
}

let cache = json(fs.readfile(ARGV[0] + ".section-cache/FptnSec.json"));
if (type(cache) != "object") { warn("section cache is missing\n"); exit(1); }
let names = type(cache.outboundMetadata) == "object" ? cache.outboundMetadata.names : null;
if (type(names) != "object" || names["FptnSec-out/Alpha"] != "Alpha") {
    warn("section cache must record member display names\n"); exit(1);
}
let cached_group = type(cache.urltestGroups) == "object" ? cache.urltestGroups["FptnSec-urltest-out"] : null;
if (type(cached_group) != "object") {
    warn("section cache must record the auto urltest group\n"); exit(1);
}
if (cached_group.displayName != "MyVPN") {
    warn("auto group displayName must come from the token service_name\n"); exit(1);
}
if (length(cached_group.outbounds || []) != 2) {
    warn("cached auto group must list both members\n"); exit(1);
}
' "$output" || fail "fptn section did not expand into members, urltest and selector"

# ---------------------------------------------------------------------------
# 2. Undecodable tokens keep the raw-token fallback (core expands instead).
# ---------------------------------------------------------------------------

EMPTY_PAYLOAD='{"version":1,"service_name":"X","username":"u","password":"p","servers":[]}'
EMPTY_TOKEN="fptn:$(printf '%s' "$EMPTY_PAYLOAD" | base64 | tr -d '\n')"

cat > "$WORK_DIR/fixture_fallback.json" <<EOF_JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "FptnSecB",
      ".type": "section",
      "enabled": "1",
      "action": "fptn",
      "match_all": "1",
      "access_token": "fptnb:AAAA"
    },
    {
      ".name": "FptnSecC",
      ".type": "section",
      "enabled": "1",
      "action": "fptn",
      "match_all": "1",
      "access_token": "$EMPTY_TOKEN"
    }
  ]
}
EOF_JSON

output_b="$WORK_DIR/out_fallback.json"
generate_fixture "$WORK_DIR/fixture_fallback.json" "$output_b" ||
  fail "generate-config-fixture rejected the fallback fixtures"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let tags = [];
for (let o in cfg.outbounds || []) {
    if (type(o) == "object" && o.tag != null)
        push(tags, o.tag);
}

// fptnb: brotli cannot be decoded here, and an empty server list is not a
// usable payload: both must hand the raw token to the core unchanged.
let raw_b = null;
let raw_c = null;
for (let o in cfg.outbounds || []) {
    if (type(o) != "object")
        continue;
    if (o.tag == "FptnSecB-out") raw_b = o;
    if (o.tag == "FptnSecC-out") raw_c = o;
}
if (raw_b == null || raw_b.type != "fptn" || raw_b.token != "fptnb:AAAA") {
    warn("fptnb: token must fall back to the raw-token outbound: " + json(raw_b) + "\n"); exit(1);
}
if (raw_c == null || raw_c.type != "fptn" || raw_c.token == null) {
    warn("an undecodable payload must fall back to the raw-token outbound: " + json(raw_c) + "\n"); exit(1);
}
if (index(tags, "FptnSecB-out/Alpha") >= 0 || index(tags, "FptnSecC-out/solo") >= 0) {
    warn("no member outbounds may appear on the fallback path\n"); exit(1);
}
// The fallback sections keep their old shape: the section tag itself is the
// fptn outbound, not a selector.
if (index(tags, "FptnSecB-out") < 0 || index(tags, "FptnSecC-out") < 0) {
    warn("fallback section tags are missing\n"); exit(1);
}
' "$output_b" || fail "undecodable fptn tokens did not keep the raw-token fallback"

# ---------------------------------------------------------------------------
# 3. The same token pasted as a plain connection link expands too.
#
# A Connection section takes share links, and fptn: is a share link whose
# payload carries the whole server list. Before this, such a link became one
# outbound wearing the token, the core expanded it into a group behind that
# tag, and the dashboard showed a single card instead of the servers.
# ---------------------------------------------------------------------------

cat > "$WORK_DIR/fixture_manual.json" <<EOF_JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "ManualSec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "match_all": "1",
      "selector_proxy_links": [ "$TOKEN", "fptnb:AAAA" ]
    }
  ]
}
EOF_JSON

output_m="$WORK_DIR/out_manual.json"
generate_fixture "$WORK_DIR/fixture_manual.json" "$output_m" ||
  fail "generate-config-fixture rejected the fptn manual-link fixture"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let by_tag = {};
for (let o in cfg.outbounds || []) {
    if (type(o) == "object" && o.tag != null)
        by_tag[o.tag] = o;
}

// The decodable token must surface its servers as members of the section
// selector, named exactly like the fptn action expansion names them.
for (let tag in [ "ManualSec-1-out/Alpha", "ManualSec-1-out/Beta" ]) {
    if (by_tag[tag] == null) {
        warn("manual fptn link did not expand into " + tag + "\n"); exit(1);
    }
}
let alpha = by_tag["ManualSec-1-out/Alpha"];
if (alpha.type != "fptn" || alpha.server != "10.0.0.1" || alpha.server_port != 443 ||
    alpha.username != "user1" || alpha.password != "pass1") {
    warn("manual member dial fields mismatch: " + json(alpha) + "\n"); exit(1);
}

// The token slot itself must be gone for the decodable link: if it survived,
// the core would re-expand it into a group wearing that tag, which is exactly
// the behaviour this replaces. The undecodable link is allowed to keep one.
if (by_tag["ManualSec-1-out"] != null) {
    warn("the decodable link still emits a raw-token outbound\n"); exit(1);
}

// The undecodable fptnb: link keeps the single raw-token outbound.
let fallback = by_tag["ManualSec-2-out"];
if (fallback == null || fallback.type != "fptn" || fallback.token != "fptnb:AAAA") {
    warn("an undecodable manual link must keep the raw-token fallback: " + json(fallback) + "\n");
    exit(1);
}

// The section selector has to carry the members, not the token slot.
let selector = by_tag["ManualSec-out"];
if (selector == null || selector.type != "selector") {
    warn("manual section tag must be a selector\n"); exit(1);
}
for (let tag in [ "ManualSec-1-out/Alpha", "ManualSec-1-out/Beta", "ManualSec-2-out" ]) {
    if (index(selector.outbounds, tag) < 0) {
        warn(tag + " missing from the section selector\n"); exit(1);
    }
}

let cache = json(fs.readfile(ARGV[0] + ".section-cache/ManualSec.json"));
let names = type(cache) == "object" && type(cache.outboundMetadata) == "object"
    ? cache.outboundMetadata.names : null;
if (type(names) != "object" || names["ManualSec-1-out/Alpha"] != "Alpha") {
    warn("section cache must record manual member display names\n"); exit(1);
}
' "$output_m" || fail "an fptn link pasted into a Connection section did not load its servers"

printf 'fptn backend expansion checks passed\n'
