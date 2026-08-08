#!/usr/bin/env bash
set -eo pipefail

# Pins that heal_dns_continuous only touches dnsmasq when dnsmasq disagrees
# with it.
#
# The healer sets noresolv to a single fixed value, so from the second failure
# onward it was rewriting a setting that already held that value — and then
# reloading dnsmasq regardless, which drops the resolver's cache and re-reads
# every config file to arrive back where it started. DNS failing three times
# running is exactly when a fourth failure is likely, so that reload landed when
# the resolver could least afford it.
#
# The failure mode is invisible from outside: the repair "works" either way. Only
# counting the commands it issues shows the difference.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ── the current value is read before anything is written ──────────────────────
grep -q 'uci_core.get("dhcp.@dnsmasq\[0\].noresolv")' "$WATCHDOG_UC" \
  || fail "heal_dns_continuous no longer reads noresolv; it would write unconditionally"

read_line="$(grep -n 'uci_core.get("dhcp.@dnsmasq\[0\].noresolv")' "$WATCHDOG_UC" | cut -d: -f1)"
set_line="$(grep -n "uci set dhcp.@dnsmasq\[0\].noresolv" "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$set_line" ] || fail "heal_dns_continuous no longer sets noresolv at all"
[ "$read_line" -lt "$set_line" ] \
  || fail "noresolv is read after it is written; the read could not gate anything"

# ── the healer's real body decides correctly ───────────────────────────────────
# watchdog.uc is a CLI module with no exports, so the function is lifted out of
# the source verbatim — extracted, not copied, so a change to the logic changes
# the test's subject too. The shell and uci calls are replaced by recorders.
DNS_UC="$(mktemp "${TMPDIR:-/tmp}/tachyon_dns_idem.XXXXXX.uc")"
trap 'rm -f "$DNS_UC"' EXIT

# The stubs go in first: ucode captures a closure's upvalues when the closure is
# created, so a helper declared below the extracted function would not be
# captured at all — it would resolve as a global and come back null.
cat > "$DNS_UC" <<'PRELUDE'
let ran = [];
let reports = [];
let resets = 0;
let noresolv = "";

function as_string(v) { return "" + v; }
function system(cmd) { push(ran, cmd); return 0; }
function ai_enabled(key, dflt) { return true; }
function suppressed_by_root_cause(healer, priority) { return false; }
function ai_heal_report(t, d, r, outcome) { push(reports, outcome); }
let uci_core = { get: function(path) { return path == "dhcp.@dnsmasq[0].noresolv" ? noresolv : ""; } };
let controller = { reset_dns_consecutive: function() { resets++; } };
const PRIORITY_DNS = 50;
PRELUDE

awk '
  /^function heal_dns_continuous\(ev\) \{/ { inside = 1 }
  inside { print }
  inside && /^}$/ { exit }
' "$WATCHDOG_UC" >> "$DNS_UC"

grep -q 'function heal_dns_continuous' "$DNS_UC" \
  || fail "could not extract heal_dns_continuous from watchdog.uc"

cat >> "$DNS_UC" <<'DRIVER'

function touched() {
    let n = 0;
    for (let cmd in ran)
        if (index(cmd, "uci commit") >= 0 || index(cmd, "dnsmasq reload") >= 0) n++;
    return n;
}

let out = [];
let ev = { payload: { consecutive: 3 } };

// dnsmasq disagrees: the setting is missing entirely. The repair must run.
noresolv = "";
heal_dns_continuous(ev);
push(out, "unset_touched=" + touched());
push(out, "unset_outcome=" + reports[0]);

// dnsmasq holds the wrong value. Still a divergence, still repaired.
ran = []; reports = []; noresolv = "0";
heal_dns_continuous(ev);
push(out, "zero_touched=" + touched());
push(out, "zero_outcome=" + reports[0]);

// dnsmasq already holds exactly what this healer wants. Nothing to do: no
// commit, no reload.
ran = []; reports = []; resets = 0; noresolv = "1";
heal_dns_continuous(ev);
push(out, "set_touched=" + touched());
push(out, "set_outcome=" + reports[0]);
// The counter resets anyway, or the fact re-arrives on every fast tick and the
// healer is re-entered forever — doing nothing each time, reporting each time.
push(out, "set_reset=" + resets);

// Below the threshold nothing happens at all, in either direction.
ran = []; reports = []; noresolv = "";
heal_dns_continuous({ payload: { consecutive: 2 } });
push(out, "under_threshold=" + touched() + "/" + length(reports));

print(join(" ", out) + "\n");
DRIVER

actual="$(ucode "$DNS_UC")"
expected="unset_touched=2 unset_outcome=fixed zero_touched=2 zero_outcome=fixed set_touched=0 set_outcome=skipped set_reset=1 under_threshold=0/0"
[ "$actual" = "$expected" ] \
  || fail "heal_dns_continuous is not idempotent
  expected: $expected
  actual:   $actual"

printf 'heal dns idempotency checks passed\n'
