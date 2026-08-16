#!/usr/bin/env bash
set -eo pipefail

# ucode captures a closure's upvalues when the closure is CREATED. A local
# declared later in the same scope was never captured, so the name resolves as a
# global and evaluates to null — "left-hand side is not a function" at call time.
#
# Neither `ucode -c` nor `ucode -S -c` catches this, and a unit test only catches
# it if it actually calls the offending path. Both halves are needed:
#   1. a static scan for declaration-after-use across every module
#   2. a runtime invocation of the push handlers, which are pure closures over
#      probes declared elsewhere in the same scope

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ── 1. static scan ──────────────────────────────────────────────────────────
# Comments and string literals are stripped first so that prose mentioning a
# function name is not mistaken for a call.
scan_forward_refs() {
  local file="$1" stripped
  stripped="$(mktemp)"
  sed -E 's://.*::; s:"[^"]*":"":g' "$file" > "$stripped"

  grep -nE '^[[:space:]]+function [a-z_0-9]+\(' "$stripped" \
    | sed -E 's/^([0-9]+):[[:space:]]*function ([a-z_0-9]+).*/\1 \2/' \
    | while read -r decl name; do
        local first
        first="$(grep -nE "(^|[^a-zA-Z0-9_.])$name([^a-zA-Z0-9_]|$)" "$stripped" \
          | grep -vE "function $name" | head -1 | cut -d: -f1)"
        if [ -n "$first" ] && [ "$first" -lt "$decl" ]; then
          printf '%s used at line %s but declared at line %s\n' "$name" "$first" "$decl"
        fi
      done

  rm -f "$stripped"
}

found=0
while IFS= read -r uc; do
  hits="$(scan_forward_refs "$uc")"
  if [ -n "$hits" ]; then
    printf 'FAIL: forward reference in %s:\n%s\n' "${uc#"$ROOT_DIR/"}" "$hits" >&2
    found=1
  fi
done < <(find "$TACHYON_LIB" -name '*.uc' | sort)
[ "$found" -eq 0 ] || fail "nested functions are used before their declaration (ucode does not hoist them)"

# The scan is only worth trusting if it fires on a known-bad file.
canary="$(mktemp "${TMPDIR:-/tmp}/tachyon_fwd_canary_XXXXXX")"
trap 'rm -f "$canary"' EXIT
cat > "$canary" <<'EOF'
function outer() {
    let self = {};
    self.go = function() { return later(); };
    function later() { return 1; }
    return self;
}
EOF
[ -n "$(scan_forward_refs "$canary")" ] \
  || { rm -f "$canary"; fail "the forward-reference scan does not detect a known-bad file"; }

# ── 2. runtime invocation ───────────────────────────────────────────────────
# Calling the handlers is what actually proves the bindings resolve. The probes
# they drive touch nft and /proc, which do not exist in the test container, so
# run_probe's isolation absorbs the failures — a null binding would still raise
# "left-hand side is not a function" before any probe body runs.
driver="$(mktemp "${TMPDIR:-/tmp}/tachyon_fwd_XXXXXX")"
cat > "$driver" <<'EOF'
let events = require("core.events");
let ec = require("service.event_controller");

let b = events.bus();
let seen = [];
for (let t in ["singbox.stopped", "firewall.reloaded", "honeypot.hit"])
    b.on(t, function(ev) { push(seen, ev.type); }, { name: "collect" });

let c = ec.controller(b, {});
c.handle_ubus_service_stop("sing-box", "test");
c.handle_ubus_firewall_reload();
c.handle_honeypot_line("10.0.0.1");
print(join(",", seen) + "\n");
EOF

out="$(ucode -L "$TACHYON_LIB" "$driver" 2>&1)" || {
  rm -f "$driver"
  fail "invoking the push handlers raised an error:
$out"
}
rm -f "$driver"

grep -q 'singbox.stopped' <<< "$out" \
  || fail "handle_ubus_service_stop published nothing (got: $out)"
grep -q 'firewall.reloaded' <<< "$out" \
  || fail "handle_ubus_firewall_reload published nothing (got: $out)"
grep -q 'honeypot.hit' <<< "$out" \
  || fail "handle_honeypot_line published nothing (got: $out)"

printf 'forward reference checks passed\n'
