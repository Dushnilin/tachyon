#!/usr/bin/env bash
set -eo pipefail

# The watchdog used to report what it was about to do. ai_heal_report() was
# called before the repair, its fourth parameter was dead, and the recovery
# facts the controller published (PROXY_UP / DNS_UP) had no subscriber — so a
# rate-limited restart that never ran still announced itself as a repair, and a
# restart that ran and did not help was indistinguishable from one that did.
#
# This pins the outcome path: act, then report what actually happened.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# --- the outcome parameter is alive ---
# It was declared as `status_code` and never read; all call sites passed a
# literal into nothing.
grep -q 'function ai_heal_report(event_type, description, resolution, outcome)' "$WATCHDOG_UC" \
  || fail "ai_heal_report no longer takes an outcome parameter"
grep -q 'let status_code = as_string(outcome || "fixed");' "$WATCHDOG_UC" \
  || fail "ai_heal_report ignores its outcome argument again"
grep -q 'outcome: status_code,' "$WATCHDOG_UC" \
  || fail "the incident record carries no outcome field"

# The two fields telegram.uc:1823 reads must stay in the incident record.
for field in 'description: description,' 'resolution: resolution,'; do
  grep -q "$field" "$WATCHDOG_UC" \
    || fail "last_incident lost '$field'; telegram.uc reads it"
done

# --- a repair in flight does not notify ---
# Otherwise every asynchronous repair sends two messages: one on the attempt and
# one on the outcome.
grep -q 'if (status_code != "pending" &&' "$WATCHDOG_UC" \
  || fail "a pending outcome would send a Telegram notification of its own"

# --- the recovery watch exists and is settled from both sides ---
grep -q 'function watch_recovery(key, incident, reason)' "$WATCHDOG_UC" \
  || fail "watch_recovery() is gone; asynchronous repairs cannot report an outcome"
# The recovery_event parameter was removed: settle_recovery() settles on whatever
# fact caused it, not on a specific EV.* value stored at registration time. The
# reason field (used to escalate or reset the ladder) must still be stored.
grep -q 'reason: reason,' "$WATCHDOG_UC" \
  || fail "watch_recovery() no longer records the reason behind the repair"
grep -q 'function settle_recovery(key, outcome)' "$WATCHDOG_UC" \
  || fail "settle_recovery() is gone"
grep -q 'function settle_expired_recoveries()' "$WATCHDOG_UC" \
  || fail "nothing expires an unclosed watch; a failed repair would report nothing"
grep -q 'settle_recovery(key, "failed");' "$WATCHDOG_UC" \
  || fail "an expired watch no longer settles as failed"
grep -q 'settle_recovery("proxy", "fixed");' "$WATCHDOG_UC" \
  || fail "PROXY_UP no longer settles the proxy watch as fixed"
grep -q 'settle_recovery("dns", "fixed");' "$WATCHDOG_UC" \
  || fail "DNS_UP no longer settles the dns watch as fixed"

# --- the recovery facts have subscribers ---
# They were published from the very first version of event_controller.uc and
# subscribed by nobody, which is the whole reason outcomes were unmeasurable.
for pair in 'PROXY_UP:note_proxy_recovered' 'DNS_UP:note_dns_recovered'; do
  ev="${pair%%:*}"; handler="${pair##*:}"
  grep -q "bus.emit(EV.$ev" "$CONTROLLER_UC" \
    || fail "event_controller no longer publishes EV.$ev"
  grep -qE "subscribe\(EV\.$ev, $handler," "$WATCHDOG_UC" \
    || fail "EV.$ev has no subscriber; a successful repair would expire as failed"
done

# --- expiry is swept on a tier that actually runs ---
# A watch nobody sweeps stays open forever and reports neither outcome.
grep -q 'safe_call(settle_expired_recoveries, "settle_expired_recoveries");' "$WATCHDOG_UC" \
  || fail "settle_expired_recoveries() is never called from a tick"
grep -A6 'function perform_fast_checks()' "$WATCHDOG_UC" \
  | grep -q 'settle_expired_recoveries' \
  || fail "the fast tier does not sweep expired watches"
# Order matters: probing first lets a recovery observed on this tick close its
# watch before the deadline is tested against it.
grep -A6 'function perform_fast_checks()' "$WATCHDOG_UC" \
  | grep -nE 'probe_fast|settle_expired_recoveries' \
  | awk -F: '/probe_fast/{p=$1} /settle_expired/{s=$1} END{exit !(p && s && p < s)}' \
  || fail "expiries are swept before the probes run; a same-tick recovery would report failed"

# --- no repair reports before it acts ---
# Every healer that goes through safe_proxy_restart() must branch on its return
# value: a rate-limited or locked attempt did not restart anything.
for healer in heal_dns_stall heal_proxy_connectivity heal_proxy_health; do
  body="$(awk -v fn="function $healer(ev) {" '
    index($0, fn) { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$WATCHDOG_UC")"
  [ -n "$body" ] || fail "$healer not found"

  printf '%s\n' "$body" | grep -q 'if (!safe_proxy_restart(' \
    || fail "$healer does not check the safe_proxy_restart() return value; a skipped restart would report as a repair"
  printf '%s\n' "$body" | grep -q '"skipped");' \
    || fail "$healer does not report a skipped outcome when the restart never ran"
  printf '%s\n' "$body" | grep -q 'watch_recovery(' \
    || fail "$healer restarts without registering a recovery watch; its outcome is unknowable"

  # The literal "fixed" is what the old code passed unconditionally. An
  # asynchronous healer cannot know that at call time.
  if printf '%s\n' "$body" | grep -q '"fixed"'; then
    fail "$healer still claims a fixed outcome for an asynchronous restart"
  fi
done

# --- synchronous repairs report their real exit status ---
# These do not need a watch: the command returns before the healer does.
for healer in heal_dns_continuous heal_rpcd; do
  body="$(awk -v fn="function $healer(ev) {" '
    index($0, fn) { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$WATCHDOG_UC")"
  [ -n "$body" ] || fail "$healer not found"
  printf '%s\n' "$body" | grep -q 'rc == 0 ? "fixed" : "failed"' \
    || fail "$healer reports a fixed outcome without checking the command's exit status"
done

# --- the CLI contract is unchanged ---
# diagnostics/status.uc:1178 and telegram.uc:1823 read this file; ai-status must
# keep answering with the same shape whether or not an incident exists.
status_json="$(ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" ai-status)"
printf '%s' "$status_json" | grep -q '"ai_active"' \
  || fail "ai-status no longer reports ai_active: $status_json"

full_json="$(ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" ai-status-full)"
for key in '"status"' '"ai_active"' '"last_incident"' '"incidents_total"'; do
  printf '%s' "$full_json" | grep -q "$key" \
    || fail "ai-status-full lost $key from its contract"
done

printf 'heal outcome checks passed\n'
