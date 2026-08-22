#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARP="$ROOT_DIR/tachyon/files/usr/lib/service/warp_generator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$WARP" ] || fail "warp_generator.uc not found"

# 1. Pre-flight probe: when the Cloudflare API is unreachable the generator
#    must fail fast with an actionable message instead of burning its whole
#    time budget and tripping the LuCI XHR timeout.
grep -Fq 'Cloudflare API недоступен с этого роутера' "$WARP" ||
  fail "generator must report an unreachable Cloudflare API explicitly"
grep -Fq "connect-timeout 4 -m 6" "$WARP" ||
  fail "pre-flight probe must be bounded to a few seconds"

# 2. Time budgets must stay under the LuCI XHR timeout (~30 s): per-call 20s,
#    whole registration 20s, so worst case fits inside one browser request.
grep -Fq 'let deadline = now_ms() + 20000;' "$WARP" ||
  fail "call_api budget must be 20s"
grep -Fq 'let registration_deadline = now_ms() + 20000;' "$WARP" ||
  fail "registration budget must be 20s"

# 3. Error paths print the JSON envelope and exit 0: the frontend parses
#    stdout (data.success/message) and shows the real reason; a nonzero exit
#    makes it discard stdout for "Unknown error".
[ "$(grep -c 'exit(1);' "$WARP")" -eq 0 ] ||
  fail "error paths must exit(0) after printing the JSON error envelope"

# 4. Clash API calls stay bounded.
grep -Fq 'curl -s -m 5 ' "$WARP" ||
  fail "local Clash API curls must carry -m 5"

printf 'warp preflight checks passed\n'
