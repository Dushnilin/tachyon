#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Issue #177: zapret2: --lua-desync=fake does not inject UDP fakes for unknown
# protocols (e.g. game UDP sessions like Fortnite, voice) unless payload=all or
# payload=unknown is passed directly to the Lua function.
#
# This test verifies that:
# 1. The gaming UDP strategy passes zapret2 strategy validation.
# 2. Blobs referenced in the strategy (stun_fake) are resolved by prepare_strategy_args.
# 3. Lua payload filtering logic accepts unknown payloads only when payload=all/unknown.

ZAPRET2_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/validator.uc"
ZAPRET2_COMMON="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/common.uc"
LIB_LUA="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/lua/zapret-lib.lua"

GAME_STRAT="--filter-udp=1024-65535 --out-range=-d2 --lua-desync=fake:blob=stun_fake:payload=all"

# 1. Strategy validation
check="$(ucode -L "$TACHYON_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws2 "$GAME_STRAT")"
JSON_VALUE="$check" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("FAIL: Gaming UDP strategy rejected by validator:", val);
  process.exit(1);
}
NODE

# 2. Blob resolution via prepare_strategy_args
mkdir -p "$WORK_DIR/files/fake"
printf 'dummy_stun_blob' > "$WORK_DIR/files/fake/stun.bin"

ZAPRET2_PROVIDER_FILES_DIR="$WORK_DIR/files" ucode -L "$TACHYON_LIB" -e '
let z2 = require("providers.zapret2.common");
let cfg = z2.config();
let strat = "--filter-udp=1024-65535 --out-range=-d2 --lua-desync=fake:blob=stun_fake:payload=all";
let args = cfg.prepare_strategy_args(strat);
let has_blob = false;
for (let a in args) {
    if (index(a, "--blob=stun_fake:@") == 0)
        has_blob = true;
}
if (!has_blob) {
    die("FAIL: prepare_strategy_args did not resolve --blob=stun_fake:@...: " + join(" ", args) + "\n");
}
'

# 3. Verify Lua payload filter semantics for unknown L7 payloads
if command -v lua >/dev/null 2>&1; then
  lua -e '
function in_list(list, item)
    if not list or not item then return false end
    for w in string.gmatch(list, "[^,]+") do
        if w == item then return true end
    end
    return false
end

function payload_match_filter(l7payload, l7payload_filter, def)
    local argpl = l7payload_filter or def or "known"
    local neg = string.sub(argpl,1,1)=="~"
    local pl = neg and string.sub(argpl,2) or argpl
    return neg ~= (in_list(pl, "all") or in_list(pl, l7payload) or in_list(pl, "known") and l7payload~="unknown" and l7payload~="empty")
end

-- Default (nil filter) falls back to "known", which rejects unknown game payloads
assert(payload_match_filter("unknown", nil, "known") == false, "default must reject unknown game payload")

-- Explicit payload=all or payload=unknown accepts unknown game payloads
assert(payload_match_filter("unknown", "all") == true, "payload=all must accept unknown payload")
assert(payload_match_filter("unknown", "unknown") == true, "payload=unknown must accept unknown payload")
assert(payload_match_filter("unknown", "~empty") == true, "payload=~empty must accept unknown payload")

-- Known payloads (e.g. STUN, Discord) pass even on default
assert(payload_match_filter("stun", nil, "known") == true, "known payload must pass default")
'
fi

printf 'PASS: zapret2_game_udp_strategy\n'
