#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

uc() {
  command ucode -L "$TACHYON_LIB" "$@"
}

# Prints the fact types a line classifies into, one per line.
classify() {
  uc "$CONTROLLER_UC" classify "$1" 2>/dev/null || true
}

# Prints the classified types joined by '+' so a multi-fact line is one token.
classify_joined() {
  classify "$1" | tr '\n' '+' | sed 's/+$//'
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- OOM detection: the real thing must be recognised ---
for line in \
  'kernel: sing-box invoked oom-killer: gfp_mask=0x100cca' \
  'kernel: Out of memory: Kill process 1234 (sing-box) score 900' \
  'daemon.err sing-box[123]: fatal error: out of memory'
do
  assert_eq "$(classify_joined "$line")" "oom.detected" "OOM line: $line"
done

# --- OOM discrimination: netlink/nlbwmon noise must NOT read as OOM ---
# This is the guard at watchdog.uc:1509. Misreading it would shrink
# GOMEMLIMIT for nothing, degrading throughput on every router that logs it.
assert_eq "$(classify_joined 'nlbwmon: netlink: out of memory allocating buffer')" \
  "" "netlink out-of-memory warning is not an OOM event"
assert_eq "$(classify_joined 'kernel: netlink: 12 bytes leftover after parsing, out of memory')" \
  "" "kernel netlink warning is not an OOM event"

# --- OOM is terminal: no further facts from the same line ---
# The original returned immediately after handling OOM.
assert_eq "$(classify_joined 'kernel: sing-box invoked oom-killer, URLTest switch proxy')" \
  "oom.detected" "OOM short-circuits URLTest classification"

# --- keyword pre-filter: unrelated lines cost nothing and yield nothing ---
assert_eq "$(classify_joined 'daemon.info dnsmasq[1]: reading /tmp/resolv.conf')" \
  "" "unrelated line yields no fact"
assert_eq "$(classify_joined '')" "" "empty line yields no fact"

# --- smart detect: a direct-connection failure carries the domain ---
assert_eq "$(classify_joined 'outbound/direct: failed to connect to "blocked.example.com:443"')" \
  "smartdetect.candidate" "direct failure classifies as smart-detect candidate"
assert_eq "$(uc "$CONTROLLER_UC" classify-domain \
  'outbound/direct: failed to connect to "blocked.example.com:443"' 2>/dev/null)" \
  "blocked.example.com" "smart-detect fact carries the extracted domain"

# A direct line with no usable host is not a candidate.
assert_eq "$(classify_joined 'outbound/direct: failed to connect to 192.168.1.1:443')" \
  "" "direct failure without a domain yields no candidate"

# A direct line that did not fail is not a candidate.
assert_eq "$(classify_joined 'outbound/direct: connected to "example.com:443"')" \
  "" "successful direct connection yields no candidate"

# --- URLTest switches ---
assert_eq "$(classify_joined 'URLTest: selected proxy outbound-2')" \
  "urltest.switched" "URLTest line classifies as a switch"
assert_eq "$(classify_joined 'group: switch proxy to node-tokyo')" \
  "urltest.switched" "switch proxy line classifies as a switch"

# --- smart detect and URLTest are not exclusive ---
# handle_log_line() fell through from one branch to the other, so a line that
# satisfies both must still produce both facts.
assert_eq "$(classify_joined 'URLTest: direct failed "blocked.example.com:443", switch proxy')" \
  "smartdetect.candidate+urltest.switched" "one line can yield both facts, in order"

# --- extractor parity: the controller must match watchdog byte for byte ---
# tests/smart_detect_domain_extraction.sh pins the watchdog CLI; this pins the
# controller against it, so the two cannot drift apart silently.
for line in \
  'outbound/direct: failed to connect to "example.com:443"' \
  'direct connection failed: "sub.domain.example.org"' \
  'DIRECT timeout "xn--80ak6aa92e.com:443"' \
  'direct reset "a-b-c.example.co.uk:8443"' \
  'direct failed target=blocked.example.net' \
  'direct failed target blocked2.example.net' \
  'direct failed to connect to 192.168.1.1:443' \
  'direct connection failed, no host in line' \
  'direct failed "localhost"' \
  'direct failed "a.co"' \
  'direct failed "*.example.com"' \
  'direct failed "example..com"' \
  'direct failed "-example.com"'
do
  from_watchdog="$(uc "$WATCHDOG_UC" smart-detect-extract-domain "$line" 2>/dev/null || true)"
  from_controller="$(uc "$CONTROLLER_UC" extract-domain "$line" 2>/dev/null || true)"
  [ "$from_watchdog" = "$from_controller" ] || \
    fail "extractor drift on '$line': watchdog='$from_watchdog' controller='$from_controller'"
done

# --- event vocabulary is exported and non-empty ---
types="$(uc "$CONTROLLER_UC" event-types)"
for expected in \
  "SINGBOX_STOPPED=singbox.stopped" \
  "DNS_DOWN=dns.down" \
  "PROXY_DOWN=proxy.down" \
  "OOM_DETECTED=oom.detected" \
  "SMARTDETECT_CANDIDATE=smartdetect.candidate"
do
  printf '%s\n' "$types" | grep -qx "$expected" || fail "event vocabulary missing $expected"
done

# --- publication layer: the OOM replay guard ---
# logread -f replays the historical buffer on start. Facts derived from that
# replay describe the past, not the present, and must not be published.
run_case() {
  local body="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tachyon_ec_case_XXXXXX")"
  {
    printf '%s\n' 'let events = require("core.events");'
    printf '%s\n' 'let ec = require("service.event_controller");'
    printf '%s\n' "$body"
  } >"$tmp"
  uc "$tmp"
  rm -f "$tmp"
}

actual="$(run_case '
let b = events.bus();
let c = ec.controller(b, {});
let seen = 0;
b.on("oom.detected", function(ev) { seen++; });
// syslog_start_time still 0: we are inside the historical replay window.
print(length(c.handle_log_line("kernel: sing-box invoked oom-killer")) + "," + seen);
')"
assert_eq "$actual" "0,0" "OOM from the log replay window is not published"

actual="$(run_case '
let b = events.bus();
let c = ec.controller(b, {});
let seen = 0;
b.on("oom.detected", function(ev) { seen++; });
// Started well in the past: live lines, not replay.
c.set_syslog_start(time() - 3600);
c.handle_log_line("kernel: sing-box invoked oom-killer");
c.handle_log_line("kernel: sing-box invoked oom-killer");
print(seen);
')"
assert_eq "$actual" "1" "an OOM storm collapses into one published fact"

# --- publication layer: URLTest throttle ---
actual="$(run_case '
let b = events.bus();
let c = ec.controller(b, {});
let seen = 0;
b.on("urltest.switched", function(ev) { seen++; });
c.handle_log_line("URLTest: selected proxy a");
c.handle_log_line("URLTest: selected proxy b");
c.handle_log_line("URLTest: selected proxy c");
print(seen);
')"
assert_eq "$actual" "1" "URLTest facts are throttled to one per window"

# --- publication layer: ubus service stop is scoped to sing-box ---
actual="$(run_case '
let b = events.bus();
let c = ec.controller(b, {});
let seen = [];
b.on("singbox.stopped", function(ev) { push(seen, ev.payload.reason); });
let ours = c.handle_ubus_service_stop("sing-box", "procd");
let theirs = c.handle_ubus_service_stop("dnsmasq", "procd");
print(ours + "," + theirs + "," + join(",", seen));
')"
assert_eq "$actual" "true,false,procd" "only sing-box stops publish singbox.stopped"

# --- publication layer: honeypot input is validated before publishing ---
# The FIFO is world-writable by design; a malformed line must not become a fact
# that a subscriber later interpolates into an nft or iptables command.
actual="$(run_case '
let b = events.bus();
let c = ec.controller(b, {});
let seen = [];
b.on("honeypot.hit", function(ev) { push(seen, ev.payload.ip); });
let ok4 = c.handle_honeypot_line("203.0.113.7\n");
let ok6 = c.handle_honeypot_line("2001:db8::1");
let bad = c.handle_honeypot_line("203.0.113.7; nft flush ruleset");
let empty = c.handle_honeypot_line("");
print(ok4 + "," + ok6 + "," + bad + "," + empty + "|" + join(",", seen));
')"
assert_eq "$actual" "true,true,false,false|203.0.113.7,2001:db8::1" \
  "honeypot publishes only well-formed addresses"

printf 'event_controller checks passed\n'
