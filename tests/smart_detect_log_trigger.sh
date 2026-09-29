#!/usr/bin/env bash
# Smart Detect candidate trigger: which sing-box log lines are evidence that a
# destination is blocked, and which are just a section's own outbound failing.
#
# The discriminator is the outbound TAG, not the word "direct": in sing-box
# 1.14 `outbound/direct[Zapret2-out]` is a direct-TYPE outbound owned by the
# Zapret2 section. Reading it as "the bypass path failed" inverted the meaning
# and produced VPN rules for every site whenever a section broke.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

uc() {
  command ucode -L "$TACHYON_LIB" "$@"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

# Feeds a log excerpt to the classifier in arrival order, one candidate domain
# per line of stdout. Order matters: the hostname only ever appears on the
# connection's open line, the failure line carries the resolved IP alone.
stream() {
  printf '%s\n' "$@" > "$TMP_DIR/log"
  uc "$CONTROLLER_UC" classify-stream "$TMP_DIR/log" 2>/dev/null || true
}

assert_candidate() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_no_candidate() {
  local actual="$1" label="$2"
  [ -z "$actual" ] || fail "$label: expected no candidate, got '$actual'"
}

# --- the bypass path failing on a blocked destination IS evidence ---
assert_candidate "$(stream \
  'daemon.err sing-box[3869]: INFO[5799] [3166229034 0ms] outbound/direct[direct-out]: outbound connection to blocked.example.org:443' \
  'daemon.err sing-box[3869]: ERROR[5731] [3166229034 5.1s] connection: open connection to [93.184.216.34] using outbound/direct[direct-out]: dial tcp 93.184.216.34:443: i/o timeout')" \
  blocked.example.org \
  "bypass outbound failure paired with its own open line"

# --- a section's own outbound failing is NOT evidence of a block ---
# This is the regression: Zapret2's outbound times out for every destination it
# touches, and each of those lines used to become a candidate.
assert_no_candidate "$(stream \
  'daemon.err sing-box[3869]: INFO[5799] [3166229034 0ms] outbound/direct[Zapret2-out]: outbound connection to www.google.com:443' \
  'daemon.err sing-box[3869]: ERROR[5731] [3166229034 5.1s] connection: open connection to [173.194.221.84,2a00:1450:4010:c0a::54] using outbound/direct[Zapret2-out]: dial tcp 173.194.221.84:7: i/o timeout')" \
  "section outbound failure must not become a candidate"

# A urltest group inside a section is the section's own path as well.
assert_no_candidate "$(stream \
  'daemon.err sing-box[3869]: INFO[5799] [11 0ms] outbound/direct[Main-urltest-cfg092898-out]: outbound connection to hdrezka.tv:443' \
  'daemon.err sing-box[3869]: ERROR[5731] [11 5.1s] connection: open connection to [1.2.3.4] using outbound/direct[Main-urltest-cfg092898-out]: dial tcp 1.2.3.4:443: i/o timeout')" \
  "urltest group failure must not become a candidate"

# --- a failure with no hostname anywhere must stay silent, not guess ---
assert_no_candidate "$(stream \
  'daemon.err sing-box[3869]: ERROR[5731] [249686047 5.1s] connection: open connection to [173.194.221.84] using outbound/direct[direct-out]: dial tcp 173.194.221.84:7: i/o timeout')" \
  "failure line with no open line and no host must not guess"

# --- the legacy quoted form still works, on the bypass path ---
assert_candidate "$(stream \
  'outbound/direct: failed to connect to "legacy.example.com:443"')" \
  legacy.example.com \
  "legacy quoted-host form on the bypass outbound"

# --- the same legacy line on a section outbound is still not evidence ---
assert_no_candidate "$(stream \
  'outbound/direct[Zapret2-out]: failed to connect to "legacy.example.com:443"')" \
  "legacy quoted-host form on a section outbound"

# --- an unparseable open line must not poison a later lookup ---
# trace 7 is remembered with a FakeIP-only open line; a later bypass failure
# reusing that trace must not emit the IP as a domain.
assert_no_candidate "$(stream \
  'daemon.err sing-box[3869]: INFO[5798] [7 0ms] inbound/tproxy[tproxy-in]: inbound packet connection to 198.18.2.165:443' \
  'daemon.err sing-box[3869]: ERROR[5731] [7 5.1s] connection: open connection to [198.18.2.165] using outbound/direct[direct-out]: dial tcp 198.18.2.165:443: i/o timeout')" \
  "FakeIP-only open line must not become the candidate"

printf 'smart detect log trigger checks passed\n'
