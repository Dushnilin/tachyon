#!/usr/bin/env bash
# A binary that rejects one config field is not "incompatible with the configuration".
#
# The pre-flight repair is driven here directly against real config files (outbounds,
# endpoints, inbounds), and the cases that must NOT be repaired are checked too: a
# wrong field name, an out-of-range index and a reason that names no field all have
# to leave the file untouched, or the loop would rewrite a config for a problem it
# cannot fix.
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

VERIFIER="$TACHYON_LIB/components/verifier.uc"
[ -f "$VERIFIER" ] || fail "missing $VERIFIER"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

write_config() {
  cat >"$WORK_DIR/cfg.json" <<'JSON'
{
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "selector", "tag": "Main-out", "outbounds": ["direct"], "default": "direct" },
    { "type": "urltest", "tag": "ut", "outbounds": ["direct"], "url": "https://www.gstatic.com/generate_204" }
  ]
}
JSON
}

cat >"$WORK_DIR/repair.uc" <<'UCODE'
let fs = require("fs");
let v = require("components.verifier");

let file = ARGV[0];
let reason = ARGV[1];
let expected = ARGV[2] == "true";

let changed = v.repair_unknown_outbound_field(file, reason);
if (changed !== expected) {
    printf("repair(%s) returned %s, expected %s\n", reason, changed, expected);
    exit(1);
}
UCODE

# The reported case: the candidate names outbound 1 and field "default".
write_config
if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/cfg.json" \
  'outbounds[1].default: json: unknown field "default"' true 2>&1)"; then ok; else
  fail "the named field on the named outbound must be repairable: $out"
fi

# ...and it must actually be gone, with everything else intact.
if grep -q '"default"' "$WORK_DIR/cfg.json"; then
  fail "the field was reported as removed but is still in the config:
$(cat "$WORK_DIR/cfg.json")"
fi
ok

for keep in "Main-out" "ut" "generate_204" '"type": "selector"'; do
  if ! grep -q "$keep" "$WORK_DIR/cfg.json"; then
    fail "the repair dropped unrelated content ($keep is gone):
$(cat "$WORK_DIR/cfg.json")"
  fi
  ok
done

# A second pass over the already repaired file reports no change, and that is what
# ends the loop in the caller.
if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/cfg.json" \
  'outbounds[1].default: json: unknown field "default"' false 2>&1)"; then ok; else
  fail "an already repaired config must report no further change: $out"
fi

# A field the outbound does not have must not be reported as repaired, otherwise the
# caller loops forever on a message it cannot act on.
write_config
if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/cfg.json" \
  'outbounds[0].nonexistent: json: unknown field "nonexistent"' false 2>&1)"; then ok; else
  fail "a field the outbound does not have must not count as repaired: $out"
fi

# An index past the end of the list is not repairable either.
write_config
if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/cfg.json" \
  'outbounds[99].default: json: unknown field "default"' false 2>&1)"; then ok; else
  fail "an out-of-range index must not count as repaired: $out"
fi

# A reason that names no field - an OOM, a missing library - must be left alone.
write_config
if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/cfg.json" \
  'Out of memory (OOM killed, exit status 137)' false 2>&1)"; then ok; else
  fail "a reason with no unknown field must not count as repaired: $out"
fi

# Untouched means untouched: the field is still there, because nothing was applied.
if ! grep -q '"default"' "$WORK_DIR/cfg.json"; then
  fail "an unrepairable reason must leave the config exactly as it was:
$(cat "$WORK_DIR/cfg.json")"
fi
ok

# repair_unknown_outbound_field on endpoints[0].amnezia (flattens inner AWG props)
cat >"$WORK_DIR/endpoint_cfg.json" <<'JSON'
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "awg-ep",
      "amnezia": {
        "jc": 4,
        "jmin": 40,
        "jmax": 70,
        "s1": 20
      }
    }
  ]
}
JSON

if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/endpoint_cfg.json" \
  'endpoints[0].amnezia: json: unknown field "amnezia"' true 2>&1)"; then ok; else
  fail "endpoints[0].amnezia must be repairable: $out"
fi

if grep -q '"amnezia"' "$WORK_DIR/endpoint_cfg.json"; then
  fail "amnezia field was reported as removed but is still in config"
fi
ok

for prop in '"jc": 4' '"jmin": 40' '"jmax": 70' '"s1": 20'; do
  if ! grep -q "$prop" "$WORK_DIR/endpoint_cfg.json"; then
    fail "flattened property $prop missing from repaired endpoint: $(cat "$WORK_DIR/endpoint_cfg.json")"
  fi
  ok
done

if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/endpoint_cfg.json" \
  'endpoints[0].amnezia: json: unknown field "amnezia"' false 2>&1)"; then ok; else
  fail "already repaired endpoint must return false: $out"
fi

# Inbounds unknown field repair
cat >"$WORK_DIR/inbound_cfg.json" <<'JSON'
{
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "unknown_prop": "val"
    }
  ]
}
JSON

if out="$(ucode "$WORK_DIR/repair.uc" "$WORK_DIR/inbound_cfg.json" \
  'inbounds[0].unknown_prop: json: unknown field "unknown_prop"' true 2>&1)"; then ok; else
  fail "inbounds[0].unknown_prop must be repairable: $out"
fi

if grep -q '"unknown_prop"' "$WORK_DIR/inbound_cfg.json"; then
  fail "inbound unknown_prop was reported as removed but is still present"
fi
ok

# The repair has to be reachable from the pre-flight, not only present in the file.
body="$(sed -n '/^function check_core_config_with_binary/,/^}/p' "$VERIFIER")"
[ -n "$body" ] || fail "check_core_config_with_binary not found"
if ! grep -q 'repair_unknown_outbound_field' <<<"$body"; then
  fail "the pre-flight does not use the repair, so a single unsupported field still refuses the install"
fi
ok

# ...and it has to run inside a bounded loop rather than once.
if ! grep -qE 'for \(let attempt = 0; attempt < [0-9]+' <<<"$body"; then
  fail "the pre-flight must retry a bounded number of times; one field is not always the only one"
fi
ok

printf 'tachyon-core preflight repair: %d checks passed\n' "$pass_count"
printf 'PASS: tachyon_core_preflight_repair\n'
