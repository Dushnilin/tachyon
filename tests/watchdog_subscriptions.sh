#!/usr/bin/env bash
set -eo pipefail

# Pins the wiring between the two halves of the split: event_controller.uc
# observes and emits, watchdog.uc subscribes and repairs. A fact that nobody
# subscribes to is a repair that silently stopped happening — exactly the
# regression this refactor could introduce and that no other test would catch.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Facts that are deliberately published without a repair attached.
# PROXY_UP / DNS_UP are the recovery side of a fault pair, kept so a future
# subscriber can act on recovery; FIREWALL_RELOADED and TICK are informational.
is_informational() {
  case "$1" in
    PROXY_UP|DNS_UP|FIREWALL_RELOADED|TICK) return 0 ;;
    *) return 1 ;;
  esac
}

emitted="$(grep -oE 'bus\.emit(_once)?\(EV\.[A-Z_]+' "$CONTROLLER_UC" \
  | grep -oE 'EV\.[A-Z_]+' | sed 's/^EV\.//' | sort -u)"
[ -n "$emitted" ] || fail "no emit sites found in event_controller.uc"

# Registrations go through subscribe(), a wrapper that turns a bus.on() rejection
# into a startup failure instead of a silently missing repair.
subscribed="$(grep -oE 'subscribe\(EV\.[A-Z_]+' "$WATCHDOG_UC" \
  | grep -oE 'EV\.[A-Z_]+' | sed 's/^EV\.//' | sort -u)"
[ -n "$subscribed" ] || fail "no subscribe() registrations found in watchdog.uc"

# --- every emitted fault has a subscriber ---
for ev in $emitted; do
  is_informational "$ev" && continue
  grep -qxF "$ev" <<< "$subscribed" \
    || fail "event_controller emits EV.$ev but watchdog subscribes to nothing for it"
done

# --- every subscription has a matching emit site ---
# A dead subscription means a repair that can never run.
for ev in $subscribed; do
  grep -qxF "$ev" <<< "$emitted" \
    || fail "watchdog subscribes to EV.$ev but event_controller never emits it"
done

# --- every referenced EV name exists in the vocabulary ---
vocabulary="$(ucode -L "$TACHYON_LIB" "$CONTROLLER_UC" event-types \
  | sed 's/=.*//' | sort -u)"
for ev in $emitted $subscribed; do
  grep -qxF "$ev" <<< "$vocabulary" \
    || fail "EV.$ev is used but missing from the exported event vocabulary"
done

# --- the faults that used to be repaired on a timer are still covered ---
# Each name here was an ai_heal_* function called from a worker() tier before the
# refactor. If one loses its subscription, the router stops self-healing it.
for required in \
  SINGBOX_STOPPED WAN_DOWN CONFIG_CORRUPT NFT_MISSING QOS_MISSING TPROXY_DOWN \
  SUBNETS_EMPTY PROXY_DOWN DNS_DOWN SECTIONS_EMPTY SUBSCRIPTION_UNREACHABLE \
  OOM_DETECTED OOM_RECOVERABLE MEMORY_LOW RPCD_FD_LEAK ANOMALY_RECONNECTS \
  SMARTDETECT_CANDIDATE URLTEST_SWITCHED HONEYPOT_HIT
do
  grep -qxF "$required" <<< "$subscribed" \
    || fail "no subscriber for EV.$required (was repaired on a timer before the refactor)"
done

# --- subscriptions are registered exactly once ---
# register_subscribers() is called from both worker() and the ai-heal CLI mode;
# without the idempotence guard every repair would run twice per fact.
grep -q 'if (subscribers_registered) return;' "$WATCHDOG_UC" \
  || fail "register_subscribers() lost its idempotence guard"

# --- a rejected registration is fatal, not silent ---
# bus.on() returns false for a non-function handler rather than raising, and
# ucode does not hoist function declarations: moving a heal_* below
# register_subscribers() would register nothing, emit nothing and throw nothing.
# subscribe() exists to make that loud. Registering directly through bus.on()
# would reopen the hole.
grep -q 'function subscribe(event_type, handler, opts)' "$WATCHDOG_UC" \
  || fail "the subscribe() wrapper is gone; a lost handler would fail silently"
grep -q 'if (!bus.on(event_type, handler, opts))' "$WATCHDOG_UC" \
  || fail "subscribe() no longer checks the bus.on() return value"
if grep -qE '^\s+bus\.on\(EV\.' "$WATCHDOG_UC"; then
  fail "a subscriber registers via bus.on() directly, bypassing the subscribe() guard"
fi

# --- cooldowns that replaced the old last_*_time globals are still declared ---
# These four were the only per-repair timers in the old code; the bus owns them
# now, so the values have to survive here.
check_cooldown() {
  local handler="$1" seconds="$2"
  grep -A1 -E "subscribe\(EV\.[A-Z_]+, $handler," "$WATCHDOG_UC" \
    | grep -q "cooldown: $seconds" \
    || fail "$handler lost its cooldown of ${seconds}s"
}
check_cooldown heal_wan_and_gateway 300
check_cooldown heal_community_subnet_sets 300
check_cooldown heal_empty_sections 120
check_cooldown heal_anomaly_reconnects 300

# --- the two-tier repairs keep their original pacing ---
# Before the split, proxy and DNS were measured twice at two different rates:
# ai_heal_proxy_health / ai_heal_dns_continuous on the fast tier (15s), and
# ai_heal_proxy_connectivity / ai_heal_dns inside the normal-tier audit (120s+).
# One probe now serves both, at the fast rate. Without these bounds a single
# stall would restart sing-box eight times as often as it used to — the
# aggressive-restart regression fixed in c8052ee6.
check_cooldown heal_proxy_connectivity 120
check_cooldown heal_dns_stall 120

# The DNS stall threshold counts a streak of 3. That streak has to be stepped at
# the old normal-tier rate, or "3 failures" would mean 45 seconds of trouble
# instead of ~6 minutes.
grep -q 'const DNS_STREAK_INTERVAL = 120;' "$CONTROLLER_UC" \
  || fail "DNS_STREAK_INTERVAL is missing or no longer 120s"
grep -q 'now - state.dns_streak_stamp >= DNS_STREAK_INTERVAL' "$CONTROLLER_UC" \
  || fail "the DNS stall streak is no longer paced by DNS_STREAK_INTERVAL"

# The fast-tier counters must NOT be paced — they are the ones the old fast
# healers incremented every 15s, and ai-status-full reports them.
grep -q 'state.dns_consecutive_fails++;' "$CONTROLLER_UC" \
  || fail "dns_consecutive_fails is no longer incremented every probe"
grep -q 'state.proxy_consecutive_fails++;' "$CONTROLLER_UC" \
  || fail "proxy_consecutive_fails is no longer incremented every probe"

# --- the observation layer does not repair ---
# The whole point of the split: no restart, reload or nft mutation may leak back
# into event_controller.uc.
for forbidden in 'safe_proxy_restart' 'safe_reload_firewall' 'ai_heal_report' \
  '/etc/init.d/tachyon' 'service sing-box' 'nft add' 'nft flush'
do
  if grep -q -- "$forbidden" "$CONTROLLER_UC"; then
    fail "event_controller.uc performs a repair action ($forbidden); observation must not heal"
  fi
done

printf 'watchdog subscription checks passed\n'
