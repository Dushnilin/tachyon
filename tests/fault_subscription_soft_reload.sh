#!/usr/bin/env bash
# FAULT: recovering a deferred subscription takes the proxy down for minutes.
#
# Issue #119: after a subscription update the router lost connectivity for
# 2-3 minutes, with mass TCP timeouts through outbound/direct[Zapret2-out].
# Two paths did that, and this test pins both halves of the fix.
#
# 1. cache.uc's bootstrap retry escalated to `/etc/init.d/tachyon reload
#    subscription_deferred_recovery` when it managed to download a deferred
#    subscription. That is the *full* reload: validate -> capture reload state
#    -> plan -> zapret -> nft rebuild -> sing-box, plus Tailscale and parental
#    bookkeeping, all to apply one rewritten cache file. It ran from a
#    background worker at an arbitrary moment, so a subscription that only
#    arrived late (deferred at boot, retried by the worker) could restart the
#    proxy while the household was already using it.
#
# 2. Even the soft apply stopped both helper workers around a graceful SIGHUP.
#    DNS failover probes dig @127.0.0.42 - sing-box's own DNS listener - which
#    stays bound across an in-place reload, and it re-normalizes its state every
#    probe cycle, so stopping and restarting it bought nothing but a window
#    where DNS was unmonitored. Priority is different: it reads the section
#    cache once per worker start and the cache is exactly what changed here, so
#    it has to be restarted on both paths.
#
# The graceful path must therefore touch DNS failover zero times, and a failed
# SIGHUP is the only thing that may escalate to workers standing down.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
UPDATES_UC="$LIB_DIR/components/updates.uc"
CACHE_UC="$LIB_DIR/subscription/cache.uc"

[ -f "$UPDATES_UC" ] || fail "components/updates.uc not found"
[ -f "$CACHE_UC" ] || fail "subscription/cache.uc not found"

# --- 1. the recovery trigger must not run a full tachyon reload -------------
grep -q 'subscription-deferred-recovery-apply' "$CACHE_UC" ||
  fail "cache.uc no longer triggers the in-place deferred-recovery apply"

if grep -n 'TACHYON_SERVICE_INIT, "reload", "subscription_deferred_recovery"' "$CACHE_UC" >/dev/null; then
  fail "cache.uc still escalates deferred subscription recovery to a full 'tachyon reload subscription_deferred_recovery' (issue #119)"
fi

# The trigger has to reach the real apply, not just a renamed no-op.
grep -q 'components/updates.uc' "$CACHE_UC" ||
  fail "cache.uc does not invoke components/updates.uc for the recovery apply"

grep -q 'subscription_runtime_apply_changed' "$UPDATES_UC" ||
  fail "components/updates.uc has no shared subscription apply helper"

grep -q '"subscription-deferred-recovery-apply"' "$UPDATES_UC" ||
  fail "components/updates.uc does not dispatch the subscription-deferred-recovery-apply mode"

# The apply has to hold the reload lock, or it races a real reload that is
# already rewriting sing-box's config underneath it.
grep -q 'acquire_runtime_lock(RELOAD_LOCK_DIR' "$UPDATES_UC" ||
  fail "the deferred-recovery apply does not take RELOAD_LOCK_DIR"

# --- 2. the graceful SIGHUP path must not cycle DNS failover ---------------
# Extract the apply helper so the assertions below look at the function the
# subscription update and the recovery both run, not at the whole file.
apply_body="$WORK_DIR/apply.uc"
awk '/^function subscription_runtime_apply_changed\(/,/^}/' "$UPDATES_UC" >"$apply_body"
[ -s "$apply_body" ] ||
  fail "subscription_runtime_apply_changed not found in components/updates.uc"

# Everything up to the SIGHUP attempt, and the SIGHUP line itself, has to be
# free of any worker stop/start. DNS failover probes a listener that survives an
# in-place reload; stopping it there only leaves DNS unwatched.
pre_sighup="$WORK_DIR/pre-sighup.uc"
awk '/^function subscription_runtime_apply_changed\(/{inside=1}
     inside && /sighup-sing-box-runtime/{print; exit}
     inside{print}' "$UPDATES_UC" >"$pre_sighup"

if grep -n 'stop-runtime' "$pre_sighup" >/dev/null; then
  fail "the apply stops a helper worker before the graceful SIGHUP attempt; that window is pure churn on an in-place reload (issue #119)"
fi
if grep -n 'start-runtime' "$pre_sighup" >/dev/null; then
  fail "the apply starts a helper worker before the graceful SIGHUP attempt; nothing should run before the new config is in place"
fi

# --- 3. the restart fallback still stands both workers down ---------------
# DNS failover probes a listener the full restart tears down, so the escalation
# has to keep the stop/start pair. Losing it is the opposite regression: DNS
# failover would mark its upstreams dead during the restart window.
awk '/^function subscription_runtime_apply_changed\(/,/^}/' "$UPDATES_UC" |
  awk '/sighup-sing-box-runtime/{inside=1} inside' >"$WORK_DIR/fallback.uc"

grep -q 'reload-sing-box-runtime' "$WORK_DIR/fallback.uc" ||
  fail "a failed SIGHUP no longer escalates to a full sing-box restart"

grep -q 'DNS_FAILOVER_UC, "stop-runtime"' "$WORK_DIR/fallback.uc" ||
  fail "the full-restart fallback no longer stops DNS failover; its probes would fail during the restart window"

grep -q 'DNS_FAILOVER_UC, "start-runtime"' "$WORK_DIR/fallback.uc" ||
  fail "the full-restart fallback no longer restarts DNS failover"

# --- 4. Priority still restarts on the graceful path ----------------------
# This is the one worker that cannot be skipped: priority_groups_from_cache() is
# read once per worker start, and the subscription apply is precisely the event
# that rewrites the section cache it reads. It has to restart *outside* the
# SIGHUP-fallback block - the start inside that block only runs when the full
# restart already failed, which is the moment the router is broken anyway.
# Brace counting, not a line range: the fallback also contains a Priority
# start-runtime on its failure path, so matching anywhere would pass vacuously.
awk '
  /^function subscription_runtime_apply_changed\(/ { inside = 1; next }
  !inside { next }
  /^}$/ { inside = 0; next }
  index($0, "!sighup_ok") {
    skipping = 1
    skipdepth = gsub(/\{/, "{") - gsub(/\}/, "}")
    next
  }
  skipping {
    skipdepth += gsub(/\{/, "{") - gsub(/\}/, "}")
    if (skipdepth <= 0) skipping = 0
    next
  }
  { print }
' "$UPDATES_UC" >"$WORK_DIR/after-fallback.uc"

[ -s "$WORK_DIR/after-fallback.uc" ] ||
  fail "could not isolate the code after the SIGHUP-fallback block"

if ! grep -q 'PRIORITY_UC, "start-runtime"' "$WORK_DIR/after-fallback.uc"; then
  fail "Priority is not restarted after a successful SIGHUP; it caches the section cache once at worker start, so new subscription proxies would never be picked up"
fi

printf 'PASS: subscription apply is in place and only touches what actually needs touching\n'