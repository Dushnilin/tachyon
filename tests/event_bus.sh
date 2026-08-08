#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Runs a ucode snippet with the event bus already required as `events`.
run_case() {
  local body="$1"
  {
    printf '%s\n' 'let events = require("core.events");'
    printf '%s\n' "$body"
  } >"$WORK_DIR/case.uc"
  ucode -L "$TACHYON_LIB" "$WORK_DIR/case.uc"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- delivery: a subscriber sees the fact it subscribed to ---
actual="$(run_case '
let b = events.bus();
let got = [];
b.on("dns.down", function(ev) { push(got, ev.type + ":" + ev.payload.streak); });
b.emit("dns.down", { streak: 3 });
print(join(",", got));
')"
assert_eq "$actual" "dns.down:3" "handler receives type and payload"

# --- isolation: an unrelated type is not delivered ---
actual="$(run_case '
let b = events.bus();
let n = 0;
b.on("dns.down", function(ev) { n++; });
b.emit("proxy.down", {});
print(n);
')"
assert_eq "$actual" "0" "unrelated event type is not delivered"

# --- priority: lower priority number runs first ---
actual="$(run_case '
let b = events.bus();
let order = [];
b.on("x", function(ev) { push(order, "late"); }, { priority: 90 });
b.on("x", function(ev) { push(order, "early"); }, { priority: 10 });
b.on("x", function(ev) { push(order, "mid"); }, { priority: 50 });
b.emit("x", {});
print(join(",", order));
')"
assert_eq "$actual" "early,mid,late" "handlers run in priority order"

# --- priority ties keep registration order (stable sort) ---
actual="$(run_case '
let b = events.bus();
let order = [];
b.on("x", function(ev) { push(order, "first"); }, { priority: 50 });
b.on("x", function(ev) { push(order, "second"); }, { priority: 50 });
b.on("x", function(ev) { push(order, "third"); }, { priority: 50 });
b.emit("x", {});
print(join(",", order));
')"
assert_eq "$actual" "first,second,third" "equal priorities keep registration order"

# --- error isolation: a throwing handler must not abort the rest ---
# This is the property safe_call() used to give each individual check; losing
# it would mean one broken healer silences every healer after it.
actual="$(run_case '
let b = events.bus();
let survived = 0;
b.on("x", function(ev) { die("boom"); }, { priority: 10, name: "exploder" });
b.on("x", function(ev) { survived++; }, { priority: 20 });
b.emit("x", {});
print(survived + "," + b.stats().failed);
')"
assert_eq "$actual" "1,1" "throwing handler is isolated and counted"

# --- error sink receives the failing handler name ---
actual="$(run_case '
let b = events.bus();
let reported = "";
b.on_error(function(name, event_type, err) { reported = name + "@" + event_type; });
b.on("x", function(ev) { die("boom"); }, { name: "heal_dns" });
b.emit("x", {});
print(reported);
')"
assert_eq "$actual" "heal_dns@x" "error sink gets handler name and event type"

# --- cooldown: second invocation inside the window is skipped ---
# Replaces the hand-rolled `now - last_*_time < N` guards. The window is
# generous (60s) so the two emits are unambiguously inside it.
actual="$(run_case '
let b = events.bus();
let n = 0;
b.on("x", function(ev) { n++; }, { cooldown: 60 });
b.emit("x", {});
b.emit("x", {});
b.emit("x", {});
print(n + "," + b.stats().skipped);
')"
assert_eq "$actual" "1,2" "cooldown suppresses repeat invocations"

# --- cooldown is per subscriber, not per event type ---
actual="$(run_case '
let b = events.bus();
let cooled = 0;
let eager = 0;
b.on("x", function(ev) { cooled++; }, { cooldown: 60 });
b.on("x", function(ev) { eager++; }, { cooldown: 0 });
b.emit("x", {});
b.emit("x", {});
print(cooled + "," + eager);
')"
assert_eq "$actual" "1,2" "cooldown applies per subscriber"

# --- emit_once: duplicate inside the window is suppressed at publish time ---
actual="$(run_case '
let b = events.bus();
let n = 0;
b.on("oom.detected", function(ev) { n++; });
b.emit_once("oom.detected", {}, 60);
b.emit_once("oom.detected", {}, 60);
print(n + "," + b.stats().suppressed);
')"
assert_eq "$actual" "1,1" "emit_once suppresses duplicate within window"

# --- emit_once with a zero window never suppresses ---
actual="$(run_case '
let b = events.bus();
let n = 0;
b.on("x", function(ev) { n++; });
b.emit_once("x", {}, 0);
b.emit_once("x", {}, 0);
print(n);
')"
assert_eq "$actual" "2" "zero window disables deduplication"

# --- emit_once dedup key discriminates distinct subjects ---
# One blocked domain must not mask a different blocked domain.
actual="$(run_case '
let b = events.bus();
let seen = [];
b.on("smartdetect.candidate", function(ev) { push(seen, ev.payload.domain); });
b.emit_once("smartdetect.candidate", { domain: "a.example.com" }, 600, "a.example.com");
b.emit_once("smartdetect.candidate", { domain: "a.example.com" }, 600, "a.example.com");
b.emit_once("smartdetect.candidate", { domain: "b.example.com" }, 600, "b.example.com");
print(join(",", seen));
')"
assert_eq "$actual" "a.example.com,b.example.com" "dedup key separates distinct subjects"

# --- has(): sources can skip probes nobody listens to ---
actual="$(run_case '
let b = events.bus();
b.on("x", function(ev) {});
print(b.has("x") + "," + b.has("y"));
')"
assert_eq "$actual" "true,false" "has() reports subscriber presence"

# --- reset_timers clears cooldown and dedup state ---
actual="$(run_case '
let b = events.bus();
let n = 0;
b.on("x", function(ev) { n++; }, { cooldown: 60 });
b.emit("x", {});
b.emit("x", {});
b.reset_timers();
b.emit("x", {});
print(n);
')"
assert_eq "$actual" "2" "reset_timers clears cooldown state"

# --- stats and subscriber_runs report real activity ---
actual="$(run_case '
let b = events.bus();
b.on("x", function(ev) {}, { name: "alpha" });
b.on("y", function(ev) {}, { name: "beta" });
b.emit("x", {});
b.emit("x", {});
b.emit("y", {});
let s = b.stats();
let r = b.subscriber_runs();
print(s.emitted + "," + s.delivered + "," + s.types + "," + s.subscribers + "," + r.alpha + "," + r.beta);
')"
assert_eq "$actual" "3,3,2,2,2,1" "stats and subscriber_runs track activity"

# --- malformed registrations are rejected, not crashed on ---
actual="$(run_case '
let b = events.bus();
let ok_empty_type = b.on("", function(ev) {});
let ok_no_handler = b.on("x", null);
print(ok_empty_type + "," + ok_no_handler + "," + b.stats().subscribers);
')"
assert_eq "$actual" "false,false,0" "invalid subscriptions are rejected"

# --- emitting an unknown type is a no-op, not an error ---
actual="$(run_case '
let b = events.bus();
print(b.emit("nobody.listens", {}) + "," + b.emit("", {}));
')"
assert_eq "$actual" "0,0" "emit without subscribers is a safe no-op"

# --- non-object payload is normalised so handlers can always index it ---
actual="$(run_case '
let b = events.bus();
let t = "";
b.on("x", function(ev) { t = type(ev.payload); });
b.emit("x", null);
print(t);
')"
assert_eq "$actual" "object" "payload is always an object"

# --- events carry both wall-clock and monotonic stamps ---
actual="$(run_case '
let b = events.bus();
let ok = false;
b.on("x", function(ev) { ok = (ev.ts > 0 && ev.ms >= 0); });
b.emit("x", {});
print(ok);
')"
assert_eq "$actual" "true" "events carry ts and monotonic ms"

# --- module CLI selftest stays wired ---
actual="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/core/events.uc" selftest)"
assert_eq "$actual" "ok" "module selftest passes"

printf 'event bus checks passed\n'
