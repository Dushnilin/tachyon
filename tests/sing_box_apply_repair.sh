#!/usr/bin/env bash
# The apply path's out-of-field repair must not be able to crash the start.
#
# init_config() in singbox/runtime.uc carries its own copy of the
# "drop the field sing-box rejected on the outbound it named" repair. That copy
# logged the outbound index with to_string(), which is not a ucode function: the
# first config the installed binary rejected therefore killed init_config with
#
#   Type error: left-hand side is not a function
#   at runtime.uc:1077, byte 77
#
# and tachyon never came up on 192.168.1.205. The pre-flight's copy
# (components/verifier.repair_unknown_outbound_field) stayed tested and healthy
# the whole time - the two copies had drifted apart.
#
# The repair is now driven through the runtime's own fixture mode, i.e. through
# the same function init_config calls, so a reintroduced undefined helper crashes
# this test instead of a router. The unrepairable cases are checked too: they have
# to report no change, or the bounded retry loop rewrites a file it cannot fix.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

RUNTIME="$TACHYON_LIB/singbox/runtime.uc"
[ -f "$RUNTIME" ] || fail "missing $RUNTIME"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

write_config() {
  cat >"$WORK_DIR/cfg.json" <<'JSON'
{
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "selector", "tag": "Main-out", "outbounds": ["direct"], "default": "direct" },
    { "type": "urltest", "tag": "ut", "outbounds": ["direct"], "url": "https://www.gstatic.com/generate_204" },
    { "type": "selector", "tag": "Secondary-out", "outbounds": ["direct"], "default": "direct" }
  ]
}
JSON
}

repair_fixture() {
  ucode "$RUNTIME" outbound-repair-fixture "$1" "$2" 2>&1
}

# The reported case: the candidate names outbound 1 and field "default". This is
# the exact call init_config makes after the binary rejects the config - it used
# to die here, before ever printing anything.
write_config
if out="$(repair_fixture "$WORK_DIR/cfg.json" \
  'outbounds[1].default: json: unknown field "default"')"; then ok; else
  fail "the apply path must repair instead of crashing: $out"
fi
[ "$out" = "repaired" ] || fail "expected 'repaired', got: $out"

# ...and only the named outbound loses it: Secondary-out (outbounds[3]) carries
# the same field and must keep it. Stripping every occurrence is the original
# bug - one rejected urltest silently cost every selector its starting node.
remaining="$(grep -c '"default"' "$WORK_DIR/cfg.json" || true)"
[ "$remaining" = "1" ] ||
  fail "expected exactly one surviving \"default\" (outbounds[3] keeps it), got $remaining:
$(cat "$WORK_DIR/cfg.json")"
grep -q 'Secondary-out' "$WORK_DIR/cfg.json" || fail "unrelated outbound vanished"
ok

for keep in "Main-out" "ut" "generate_204" '"type": "selector"'; do
  if ! grep -q "$keep" "$WORK_DIR/cfg.json"; then
    fail "the repair dropped unrelated content ($keep is gone):
$(cat "$WORK_DIR/cfg.json")"
  fi
  ok
done

# A second pass reports no change - that is what ends the retry loop.
if out="$(repair_fixture "$WORK_DIR/cfg.json" \
  'outbounds[1].default: json: unknown field "default"')"; then ok; else
  fail "an already repaired config must report no further change: $out"
fi
[ "$out" = "not-repaired" ] || fail "expected 'not-repaired' on the second pass, got: $out"

# A reason that names no field must be left alone, file untouched.
write_config
if out="$(repair_fixture "$WORK_DIR/cfg.json" \
  'Out of memory (OOM killed, exit status 137)')"; then ok; else
  fail "a reason with no unknown field must not count as repaired: $out"
fi
[ "$out" = "not-repaired" ] || fail "expected 'not-repaired', got: $out"
if ! grep -q '"default"' "$WORK_DIR/cfg.json"; then
  fail "an unrepairable reason must leave the config exactly as it was:
$(cat "$WORK_DIR/cfg.json")"
fi
ok

# The repair has to be reachable from init_config, not merely present in the file.
body="$(sed -n '/^function init_config(/,/^}/p' "$RUNTIME")"
[ -n "$body" ] || fail "init_config not found"
if ! grep -q 'repair_outbound_field' <<<"$body"; then
  fail "init_config does not call the repair, so a rejected field still kills the start"
fi
ok

# The helper init_config calls must sit above it, or the call resolves to nothing
# at runtime even though the file parses (ucode resolves callees when defined).
helper_line="$(grep -n '^function repair_outbound_field' "$RUNTIME" | head -1 | cut -d: -f1)"
init_line="$(grep -n '^function init_config' "$RUNTIME" | head -1 | cut -d: -f1)"
[ -n "$helper_line" ] && [ -n "$init_line" ] || fail "could not locate functions"
if [ "$helper_line" -ge "$init_line" ]; then
  fail "repair_outbound_field (line $helper_line) must be defined before init_config (line $init_line)"
fi
ok

# to_string() does not exist in ucode. One bare call anywhere in the shipped
# library is one crash waiting for a branch nobody exercised on a router.
# Names that merely contain the word (value_to_string) and comment lines that
# explain the history are not calls.
if grep -rnE '(^|[^[:alnum:]_])to_string\(' "$ROOT_DIR/tachyon/files/usr/lib" \
    --include='*.uc' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -q .; then
  fail "to_string( is not a ucode function:
$(grep -rnE '(^|[^[:alnum:]_])to_string\(' "$ROOT_DIR/tachyon/files/usr/lib" --include='*.uc' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//')"
fi
ok

printf 'sing-box apply repair: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_apply_repair\n'
