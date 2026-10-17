#!/usr/bin/env bash
# Manual xhttp share link with extra (xmux and friends): the hand-added path
# must produce the same transport the subscription parser produces, including
# what travels inside extra (issues about lost xmux settings).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_OUTBOUNDS="$TACHYON_LIB/tachyon_core/generator_outbounds.uc"

cat >"$WORK_DIR/repro.uc" <<'UC'
let gen = require("tachyon_core.generator_outbounds");

let extra = '{"xmux":{"maxConcurrency":"16-32","maxConnections":"0","cMaxReuseTimes":"0","hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":0}}';
let link = "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&security=tls&sni=front.example.com&alpn=h2%2Chttp%2F1.1&type=xhttp&mode=auto&path=%2Ffoo&extra=" + extra + "#manual-xhttp";

let outbound = gen.manual_link_outbound(link, "t1");
let transport = outbound.transport;
if (transport == null || transport.type != "xhttp")
    die("expected xhttp transport, got " + (transport == null ? "null" : transport.type) + "\n");
if (transport.xmux == null)
    die("xmux from extra was dropped by the manual link path\n");
if (transport.xmux.max_concurrency != "16-32")
    die("xmux.max_concurrency lost, got " + transport.xmux.max_concurrency + "\n");

// a link without extra must keep working and simply have no xmux
let plain = gen.manual_link_outbound(
    "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&security=tls&sni=front.example.com&type=xhttp&mode=auto&path=%2Ffoo",
    "t2");
if (plain.transport.xmux != null)
    die("a link without extra must not grow an xmux section\n");

// percent-encoded extra must survive the query split: an encoded brace or
// quote inside extra must not be mistaken for a new query parameter
let enc = gen.manual_link_outbound(
    "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&security=tls&sni=front.example.com&type=xhttp&mode=auto&path=%2Ffoo&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%224%22%7D%7D",
    "t3");
if (enc.transport.xmux == null || enc.transport.xmux.max_concurrency != "4")
    die("percent-encoded extra must parse to the same xmux, got " +
        (enc.transport.xmux == null ? "null" : enc.transport.xmux.max_concurrency) + "\n");

print("manual xhttp extra checks passed\n");
UC

output="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$WORK_DIR/repro.uc" 2>&1)" ||
  fail "manual xhttp extra handling: $output"
grep -Fq "manual xhttp extra checks passed" <<<"$output" ||
  fail "unexpected output: $output"

printf '%s\n' "PASS: manual xhttp share link keeps extra (xmux) settings"
