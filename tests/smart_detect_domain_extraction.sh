#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_UC="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract() {
  ucode "$WATCHDOG_UC" smart-detect-extract-domain "$1" 2>/dev/null || true
}

# Asserts the line yields exactly the expected domain.
assert_extracts() {
  local line="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(extract "$line")"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# Asserts the line yields no domain (exit 1, empty stdout).
assert_rejects() {
  local line="$1"
  local label="$2"
  local actual
  actual="$(extract "$line")"
  [ -z "$actual" ] || fail "$label: expected no domain, got '$actual'"
}

# --- quoted-host form (primary sing-box log shape) ---
assert_extracts 'outbound/direct: failed to connect to "example.com:443"' \
  example.com "quoted host with port"
assert_extracts 'direct connection failed: "sub.domain.example.org"' \
  sub.domain.example.org "quoted host without port, multi-label"
assert_extracts 'DIRECT timeout "xn--80ak6aa92e.com:443"' \
  xn--80ak6aa92e.com "punycode host"
assert_extracts 'direct reset "a-b-c.example.co.uk:8443"' \
  a-b-c.example.co.uk "internal hyphens and multi-part TLD"

# --- target= form (fallback pattern) ---
assert_extracts 'direct failed target=blocked.example.net' \
  blocked.example.net "target= form"
assert_extracts 'direct failed target blocked2.example.net' \
  blocked2.example.net "target<space> form"

# --- unquoted host: the shape sing-box 1.14 actually emits ---
# Captured from a live router running sing-box 1.14.2-lx.2. The quoted-host
# fixtures above never match this format, which is why Smart Detect produced
# zero candidates on a router where smart_detect=1 and the trigger word was
# present in the log.
assert_extracts 'outbound/direct[direct-out]: outbound connection to www.google.com:443' \
  www.google.com "unquoted outbound open line with port"
assert_extracts 'outbound/direct[direct-out]: outbound connection to i.ytimg.com:443' \
  i.ytimg.com "unquoted outbound open line, second label order"
assert_extracts 'outbound/vless[Main-out]: outbound connection to hdrezka.tv:443' \
  hdrezka.tv "unquoted open line on a section outbound"
assert_extracts 'connection: open connection to [1.2.3.4] using outbound/direct[direct-out]: dial tcp blocked.example.com:443: i/o timeout' \
  blocked.example.com "unquoted host in the dial target"

# --- the failure line of a real block carries only the IP: no host to find ---
assert_rejects 'ERROR[5731] [249686047 5.1s] connection: open connection to [173.194.221.84,2a00:1450:4010:c0a::54] using outbound/direct[Zapret2-out]: dial tcp 173.194.221.84:7: i/o timeout' \
  "IP-only failure line yields no domain"
assert_rejects 'inbound/tproxy[tproxy-in]: inbound packet connection to 198.18.2.165:443' \
  "FakeIP inbound line yields no domain"

# --- rejections: nothing usable on the line ---
assert_rejects 'direct failed to connect to 192.168.1.1:443' "bare IPv4 is not a domain"
assert_rejects 'direct connection failed, no host in line' "no host present"
assert_rejects 'direct failed "localhost"' "single-label host has no TLD"
assert_rejects 'direct failed "a.co"' "below 5-char minimum"

# --- rejections: wildcards must never reach the probe ---
assert_rejects 'direct failed "*.example.com"' "wildcard star rejected"
assert_rejects 'direct failed "?.example.com"' "wildcard question mark rejected"

# --- rejections: malformed labels ---
assert_rejects 'direct failed "example..com"' "consecutive dots rejected"
assert_rejects 'direct failed "-example.com"' "leading hyphen rejected"

# --- shell metacharacters must be returned inert, never executed ---
# The extractor is the boundary that keeps log text out of the probe command;
# a hostile log line must either be rejected or come back as a plain string.
SENTINEL="$ROOT_DIR/tmp_smart_detect_injection_sentinel"
rm -f "$SENTINEL"
for hostile in \
  'direct failed "example.com; touch '"$SENTINEL"'"' \
  'direct failed "example.com$(touch '"$SENTINEL"')"' \
  'direct failed "example.com`touch '"$SENTINEL"'`"' \
  'direct failed "example.com | touch '"$SENTINEL"'"'
do
  out="$(extract "$hostile")"
  case "$out" in
    *';'*|*'$('*|*'`'*|*'|'*|*' '*)
      fail "injection: metacharacters survived extraction: '$out'"
      ;;
  esac
  [ ! -e "$SENTINEL" ] || fail "injection: command executed during extraction of '$hostile'"
done
rm -f "$SENTINEL"

# --- smart_detect_get_proxy_sections filtering ---
# Issue #56: zapret, zapret2, byedpi, bypass, block, dns must NEVER be returned as candidate proxy sections.
# Only enabled remote proxy sections (connection, awg, warp, etc.) should be returned.
TMP_DIR="$(mktemp -d /tmp/tachyon_smart_detect_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

UCI_STATE_TEST="$TMP_DIR/uci.state"
cat > "$UCI_STATE_TEST" << 'EOF'
tachyon.sec_bypass=section
tachyon.sec_bypass.enabled=1
tachyon.sec_bypass.action=bypass
tachyon.sec_zapret=section
tachyon.sec_zapret.enabled=1
tachyon.sec_zapret.action=zapret
tachyon.sec_zapret2=section
tachyon.sec_zapret2.enabled=1
tachyon.sec_zapret2.action=zapret2
tachyon.sec_byedpi=section
tachyon.sec_byedpi.enabled=1
tachyon.sec_byedpi.action=byedpi
tachyon.sec_block=section
tachyon.sec_block.enabled=1
tachyon.sec_block.action=block
tachyon.sec_dns=section
tachyon.sec_dns.enabled=1
tachyon.sec_dns.action=dns
tachyon.sec_proxy=section
tachyon.sec_proxy.enabled=1
tachyon.sec_proxy.action=connection
tachyon.sec_awg=section
tachyon.sec_awg.enabled=1
tachyon.sec_awg.action=awg
tachyon.sec_disabled=section
tachyon.sec_disabled.enabled=0
tachyon.sec_disabled.action=connection
EOF

proxy_secs="$(UCI_STATE="$UCI_STATE_TEST" ucode "$WATCHDOG_UC" smart-detect-proxy-sections 2>/dev/null || true)"
[ "$proxy_secs" = "sec_proxy sec_awg" ] || fail "smart_detect_get_proxy_sections: expected 'sec_proxy sec_awg', got '$proxy_secs'"

printf 'smart_detect_domain_extraction checks passed\n'
