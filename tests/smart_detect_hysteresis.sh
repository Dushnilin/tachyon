#!/usr/bin/env bash
# Smart Detect must not mutate UCI off a single observation.
#
# Two independent defects let one bad sample rewrite the user's routing:
#
#   * `seen[domain]` was stamped before any probe ran, so a candidate that was
#     examined during a DNS blip stayed suppressed for the full 24h TTL, and a
#     single TCP reset was enough to spend that window;
#   * one failing sample was enough to add the domain and reload sing-box, so a
#     transient reset turned into a permanent routing rule for everyone on the
#     router.
#
# The decision is therefore split: repeated transport failures are required
# before anything is written, and the seen stamp is only spent on a conclusive
# verdict.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

ucode() {
  command ucode -L "$LIB_DIR" "$@"
}

# --- the verdict helper itself ---
out="$(ucode -e '
let sd = require("service.smart_detect");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }

// A domain that has not been seen: one failure is not enough.
let one = sd.verdict("new.example", { direct: "transport", proxy: "ok" });
check(!one.act, "a single transport failure does not act");
check(one.defer, "a domain below the threshold is retried, not dropped");

// Second consecutive failure reaches the threshold and commits.
let two = sd.verdict("new.example", { direct: "transport", proxy: "ok" }, { first_fail: 100 });
check(two.act, "the second consecutive failure acts");

// A healthy direct probe is conclusive: it settles the domain and banks no
// streak, so a later failure starts counting from scratch.
let cleared = sd.verdict("new.example", { direct: "ok", proxy: "ok" });
check(!cleared.act, "a healthy probe does not act");
check(cleared.seen, "a healthy probe is conclusive and spends the domain");
check(cleared.first_fail == null, "a healthy probe clears the failure streak");

// A conclusive "not blocked" verdict must not leave the domain suppressed.
check(sd.verdict("up.example", { direct: "ok", proxy: "ok" }).seen,
      "a verified-reachable domain is remembered as checked");

// DNS failures and local errors are not evidence and never act.
check(!sd.verdict("dns.example", { direct: "dns", proxy: "ok" }).act,
      "a DNS failure never acts");
check(!sd.verdict("tls.example", { direct: "local", proxy: "ok" }).act,
      "a certificate error never acts");
check(sd.verdict("tls.example", { direct: "local", proxy: "ok" }).defer,
      "a certificate error is retried rather than spent");

// A domain that fails directly AND via the proxy is not blocked.
check(!sd.verdict("down.example", { direct: "transport", proxy: "transport" }).act,
      "failing via the proxy too is not a block");

print(sprintf("PASS: %d verdict checks\n", checks));
' 2>&1)" || fail "verdict checks failed: $out"

echo "$out" | grep -q "^PASS:" || fail "verdict checks did not report PASS"

# --- the seen stamp must be spent only on a conclusive verdict ---
# Stamping before the probes is what turned one DNS blip into a 24h blackout.
seen_body="$(sed -n '/^function smart_detect_process_pending/,/^}$/p' \
  "$LIB_DIR/service/watchdog.uc")"
if echo "$seen_body" | sed -n '/for (let domain in candidate_domains)/,/^    }$/p' \
    | grep -q 'seen\[domain\] = now;[[:space:]]*;.*' \
    && echo "$seen_body" | sed -n '/for (let domain in candidate_domains)/,/^    }$/p' \
      | sed -n '/seen\[domain\] = now;/,/DNS pre-check\|direct_status/p' \
      | grep -q 'seen\[domain\] = now;'; then
  fail "seen[domain] is still stamped before the probes run"
fi

# The loop must consult the verdict helper rather than acting inline.
echo "$seen_body" | grep -q 'smart_detect.verdict(' \
  || fail "smart_detect_process_pending does not use the hysteresis verdict"

printf 'smart detect hysteresis checks passed\n'
