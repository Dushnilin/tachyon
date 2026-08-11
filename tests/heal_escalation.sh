#!/usr/bin/env bash
set -eo pipefail

# Pins the escalation ladder: a reason's first repair attempt restarts only the
# sing-box service, and only a demonstrated failure earns the full
# `/etc/init.d/tachyon restart` that drops every live TCP/RDP session.
#
# Before this, four different diagnoses — stalled DNS, unresponsive proxy, a
# failed health check, a dead sing-box — all ended in that same full restart.
# Losing the light rung would silently restore that behaviour: the repair still
# "works", it just costs every connection through the router. No other test
# would notice.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ── the two rungs exist and are distinct ──────────────────────────────────────
grep -q 'const ESCALATION_LIGHT = "light";' "$WATCHDOG_UC" \
  || fail "ESCALATION_LIGHT is gone"
grep -q 'const ESCALATION_HEAVY = "heavy";' "$WATCHDOG_UC" \
  || fail "ESCALATION_HEAVY is gone"

# The light rung must drive the sing-box init script, not the tachyon one.
grep -q '/etc/init.d/sing-box stop' "$WATCHDOG_UC" \
  || fail "the light rung no longer stops the sing-box service"
grep -q '/etc/init.d/sing-box start' "$WATCHDOG_UC" \
  || fail "the light rung no longer starts the sing-box service"

# ── the ladder is consulted, not hardcoded ────────────────────────────────────
grep -q 'function next_escalation(reason)' "$WATCHDOG_UC" \
  || fail "next_escalation() is gone; the rung can no longer depend on history"
grep -q 'function note_escalation_outcome(reason, outcome)' "$WATCHDOG_UC" \
  || fail "note_escalation_outcome() is gone; outcomes no longer feed the ladder"

# The outcome path has to reach the ladder, or every attempt stays light forever
# and a genuinely broken stack is never fully restarted.
grep -q 'note_escalation_outcome(watch.reason, outcome);' "$WATCHDOG_UC" \
  || fail "settle_recovery() no longer feeds the outcome back into the ladder"

# A watch has to carry its reason, otherwise settling cannot tell the ladder
# which reason failed.
grep -q 'function watch_recovery(key, incident, reason)' "$WATCHDOG_UC" \
  || fail "watch_recovery() no longer records the reason behind the repair"

# ── the rate limit still gates both rungs ─────────────────────────────────────
# A light restart is cheaper, not free. The limit must be checked before the
# rung is chosen, so three light attempts still stop the fourth.
limit_line="$(grep -n 'if (proxy_restart_count >= 3)' "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$limit_line" ] || fail "the 3-per-10-minutes proxy restart rate limit is gone"
level_line="$(grep -n 'let level = (force_level != null' "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$level_line" ] || fail "safe_proxy_restart() no longer resolves an escalation level"
[ "$limit_line" -lt "$level_line" ] \
  || fail "the rate limit is checked after the rung is chosen; light restarts would escape it"

# The lock, likewise, is taken before the rung is chosen.
lock_line="$(grep -n 'write_state_file(PROXY_RESTART_LOCK, as_string(now)' "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$lock_line" ] || fail "the proxy restart lock is no longer written"
[ "$lock_line" -lt "$level_line" ] \
  || fail "the lock is taken after the rung is chosen; light restarts would bypass it"

# ── a stopped sing-box is started, never escalated over ───────────────────────
# There is no stack to tear down when the process simply is not running.
grep -q 'safe_proxy_restart("singbox_stopped", ESCALATION_LIGHT)' "$WATCHDOG_UC" \
  || fail "heal_singbox_stopped no longer pins the light rung; a missing process would trigger a full restart"

# ── repairs that rewrote config on disk stay pinned heavy ─────────────────────
# `tachyon reload` exits early when the config hash is unchanged
# (lifecycle.uc:1220), so a config rewrite genuinely needs the full restart.
for pinned in uci_config_restore dns_loop_recovery dns_loop_disable; do
  grep -q "safe_proxy_restart(\"$pinned\", ESCALATION_HEAVY)" "$WATCHDOG_UC" \
    || fail "$pinned is no longer pinned to the heavy rung; its config rewrite would not take effect"
done

# ── the ladder's state machine actually behaves ───────────────────────────────
# The checks above pin structure; this one runs the real code. watchdog.uc is a
# CLI module with no exports, so the ladder block is lifted out of the source
# verbatim — extracted, not copied, so a change to the logic changes the test's
# subject too.
LADDER_UC="$(mktemp "${TMPDIR:-/tmp}/tachyon_ladder_XXXXXX")"
trap 'rm -f "$LADDER_UC"' EXIT

sed -n '/^const ESCALATION_LIGHT/,/^}$/p;' "$WATCHDOG_UC" > "$LADDER_UC"
# sed stops at the first `}` at column 0, which closes next_escalation(); take
# note_escalation_outcome() as its own range.
sed -n '/^function note_escalation_outcome/,/^}$/p' "$WATCHDOG_UC" >> "$LADDER_UC"

grep -q 'function note_escalation_outcome' "$LADDER_UC" \
  || fail "could not extract the ladder from watchdog.uc"

cat >> "$LADDER_UC" <<'DRIVER'

let out = [];
// A reason nobody has attempted starts light.
push(out, "initial=" + next_escalation("proxy_health"));
// A repair that ran but did not restore service escalates the next attempt.
note_escalation_outcome("proxy_health", "failed");
push(out, "after_failed=" + next_escalation("proxy_health"));
// Escalation is per reason: an unrelated fault is still met with the light rung.
push(out, "other_reason=" + next_escalation("dns_stalled"));
// A repair that worked drops the reason back down, so a later unrelated fault
// does not inherit a full restart.
note_escalation_outcome("proxy_health", "fixed");
push(out, "after_fixed=" + next_escalation("proxy_health"));
// `skipped` means the repair never ran — it is evidence of nothing and must not
// move the ladder in either direction. Tested from a light state, where a
// wrongly-escalating `skipped` is visible, and again from a heavy one, where a
// wrongly-resetting one is.
note_escalation_outcome("skip_probe", "skipped");
push(out, "skipped_from_light=" + next_escalation("skip_probe"));
note_escalation_outcome("skip_probe", "failed");
note_escalation_outcome("skip_probe", "skipped");
push(out, "skipped_from_heavy=" + next_escalation("skip_probe"));
print(join(" ", out) + "\n");
DRIVER

actual="$(ucode "$LADDER_UC")"
expected="initial=light after_failed=heavy other_reason=light after_fixed=light skipped_from_light=light skipped_from_heavy=heavy"
[ "$actual" = "$expected" ] \
  || fail "the escalation ladder misbehaves
  expected: $expected
  actual:   $actual"

printf 'heal escalation checks passed\n'
