#!/usr/bin/env bash
# The frontend calls the router as `tachyon <method> <args>`, and the list of
# methods it may call is a hand-maintained TypeScript enum. The backend has its
# own dispatcher table. Nothing connects the two, so renaming a method on one
# side leaves a frontend call that compiles, type-checks and fails only at
# runtime on a user's router.
#
# BRANCH 20's generated contract does not cover this path: 60 of the 78 methods
# the frontend actually calls are absent from contracts/tachyon-rpc.json, so it
# cannot be used to check the surface that exists.
#
# A test in the frontend cannot see tachyon/files/usr/bin/tachyon, so the check
# lives here, where the backend tree is already available.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

TYPES_TS="$ROOT_DIR/fe-app-tachyon/src/tachyon/types.ts"
DISPATCHER="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

[ -f "$TYPES_TS" ] || fail "frontend types missing: $TYPES_TS"
[ -f "$DISPATCHER" ] || fail "backend dispatcher missing: $DISPATCHER"

# Enum members of AvailableMethods: NAME = 'cli_command'
sed -n '/enum AvailableMethods/,/^  }/p' "$TYPES_TS" \
  | grep -oE "= '[^']+'" \
  | sed "s/= '//; s/'$//" \
  | sort -u > /tmp/fm_enum.txt

# Dispatcher table entries: eight spaces then key, colon, bracketed value
grep -oE '^ {8}[a-z0-9_]+: \[' "$DISPATCHER" \
  | sed -E 's/^ {8}([a-z0-9_]+): \[/\1/' \
  | sort -u > /tmp/fm_dispatch.txt

enum_count=$(wc -l < /tmp/fm_enum.txt)
dispatch_count=$(wc -l < /tmp/fm_dispatch.txt)

[ "$enum_count" -gt 0 ] || fail "no enum members parsed, the check would be vacuous"
[ "$dispatch_count" -gt 0 ] || fail "no dispatcher entries parsed, the check would be vacuous"

missing=$(comm -23 /tmp/fm_enum.txt /tmp/fm_dispatch.txt)
if [ -n "$missing" ]; then
  fail "frontend calls methods the backend dispatcher does not define: $(echo "$missing" | tr '\n' ' ')"
fi

rm -f /tmp/fm_enum.txt /tmp/fm_dispatch.txt

printf 'PASS: all %s frontend RPC methods exist in the backend dispatcher (%s total)\n' \
  "$enum_count" "$dispatch_count"
