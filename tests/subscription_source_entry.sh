#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"

assert_tsv() {
  local entry="$1"
  local expected_url="$2"
  local expected_user_agent="$3"
  local parsed tab url user_agent

  parsed="$(ucode "$PARSER" parse-source-entry-tsv "$entry")"
  tab="$(printf '\t')"
  url="${parsed%%"$tab"*}"
  if [ "$url" = "$parsed" ]; then
    user_agent=""
  else
    user_agent="${parsed#*"$tab"}"
  fi

  [ "$url" = "$expected_url" ] || fail "expected url $expected_url, got $url"
  [ "$user_agent" = "$expected_user_agent" ] || fail "expected user-agent $expected_user_agent, got $user_agent"
}

assert_rejects() {
  local entry="$1"
  local expected="$2"
  local output

  if output="$(ucode "$PARSER" parse-source-entry-tsv "$entry" 2>/dev/null)"; then
    fail "entry should be rejected: $entry"
  fi
  grep -q "$expected" <<< "$output" || fail "expected reject message containing $expected"
}

assert_tsv ' https://example.com/sub.txt ' 'https://example.com/sub.txt' ''

assert_rejects 'https://example.com/a | Custom Agent/1.0' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://example.com/a | Agent One | Agent Two' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://example.com/a| Agent' 'Configure User-Agent in the subscription item settings'
assert_rejects 'file:///tmp/sub.txt' 'Subscription URL must start with http://, https:// or a supported Happ crypt link'

cat >"$WORK_DIR/require-subscription-parser.uc" <<'UCODE'
let parser = require("subscription.parser");

let parsed = parser.parse_subscription_source_entry("https://example.com/a");
if (!parsed.valid || parsed.url != "https://example.com/a" || parsed.user_agent != "")
    exit(1);

let legacy = parser.parse_subscription_source_entry("https://example.com/a | Agent");
if (legacy.valid || legacy.error != "Configure User-Agent in the subscription item settings")
    exit(1);

let invalid = parser.parse_subscription_source_entry("file:///tmp/sub.txt");
if (invalid.valid || invalid.error != "Subscription URL must start with http://, https:// or a supported Happ crypt link")
    exit(1);

let url_mod = require("core.url");
let happ = require("subscription.happ");
let fs = require("fs");

if (!url_mod.is_subscription_url("v2raytun://import/https://sub.example.com/1") ||
    !url_mod.is_subscription_url("incy://add/https%3A%2F%2Fsub.example.com%2F2") ||
    !parser.parse_subscription_source_entry("v2raytun://import/https://sub.example.com/1").valid ||
    !parser.parse_subscription_source_entry("incy://add/https%3A%2F%2Fsub.example.com%2F2").valid)
    exit(1);

if (happ.unwrap_link("v2raytun://import/https%3A%2F%2Fsub.example.com%2F1") != "https://sub.example.com/1" ||
    happ.unwrap_link("incy://add/https://sub.example.com/2") != "https://sub.example.com/2" ||
    happ.unwrap_link("happ://import/https://sub.example.com/3") != "https://sub.example.com/3")
    exit(1);

let key = b64enc("0123456789abcdef0123456789abcdef");
let links = join("\n", [
    "trojan-go://pass@tg.example.com:443?sni=tg.example.com&host=cdn.example.com&path=%2Fws#TG-Node",
    "tuic5://11111111-2222-3333-4444-555555555555:secret@tuic.example.com:8443?congestion_control=bbr&alpn=h3#TUIC5-Node",
    "naive+h3://user:pass@naive.example.com:443?uot=1#NaiveH3-Node",
    "stls://spass@stls.example.com:443?version=3&sni=target.example.com#STLS-Node",
    "sudoku://key123@sdk.example.com:9000?aead=chacha20-poly1305&padding_min=10&padding_max=40#Sudoku-Node",
    "ssh://root:secret@ssh.example.com?client_version=SSH-2.0-OpenSSH_9.0#SSH-Node",
    "wg://" + key + "@198.51.100.10:51820?publicKey=" + key + "&address=10.0.0.2/32&mtu=1400#WG-Share-Node"
]) + "\n";

let ext_in = "/tmp/tachyon-test-ext-links.txt";
let ext_out = "/tmp/tachyon-test-ext-out.json";
fs.writefile(ext_in, links);
if (!parser.normalize_content_validated(ext_in, ext_out, "", "ucode"))
    exit(1);
let out = json(fs.readfile(ext_out)).outbounds;
fs.unlink(ext_in);
fs.unlink(ext_out);
if (length(out) != 7 || out[0].type != "trojan" || out[0].transport.type != "ws" ||
    out[1].type != "tuic" || out[2].type != "naive" || out[2].quic != true ||
    out[3].type != "shadowtls" || out[4].type != "sudoku" ||
    out[5].type != "ssh" || out[5].server_port != 22 || out[6].type != "wireguard")
    exit(1);

let raw_conf = "[Interface]\nPrivateKey = " + key + "\nAddress = 10.9.0.2/32\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 101\nH2 = 102\nH3 = 103\nH4 = 104\n";
let headers = "HTTP/1.1 200 OK\r\nX-Peer-Public-Key: " + key + "\r\nX-Peer-Endpoint: 198.51.100.77:51820\r\n\r\n";
let wg_in = "/tmp/tachyon-test-wg-raw.conf";
let wg_hdr = "/tmp/tachyon-test-wg-headers.txt";
let wg_out_path = "/tmp/tachyon-test-wg-out.json";
fs.writefile(wg_in, raw_conf);
fs.writefile(wg_hdr, headers);
if (!parser.normalize_content_validated(wg_in, wg_out_path, wg_hdr, "ucode"))
    exit(1);
let wg_out = json(fs.readfile(wg_out_path)).outbounds;
fs.unlink(wg_in);
fs.unlink(wg_hdr);
fs.unlink(wg_out_path);
if (length(wg_out) != 1 || wg_out[0].type != "wireguard" ||
    wg_out[0].peers[0].address != "198.51.100.77" || wg_out[0].peers[0].port != 51820 || wg_out[0].jc != 4)
    exit(1);
UCODE

ucode -L "$TACHYON_LIB" "$WORK_DIR/require-subscription-parser.uc"

printf 'subscription source entry checks passed\n'
