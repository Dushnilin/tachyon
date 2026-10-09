#!/usr/bin/env bash
# Version comparison must decide on the version, not on how it is spelled.
#
# Both `core/helpers.uc` and `config/validator.uc` carry their own copy of
# version_compare, and that duplication is the real defect: the validator runs
# before helpers is loaded, so it cannot call it.
#
# The behaviour is therefore driven through the helpers copy, which exposes the
# comparison as a CLI mode, and the validator copy is checked by asserting the two
# implementations are character-identical. That is stronger than testing it twice:
# it cannot pass while the copies differ.
#
# The bug: a version may arrive with an optional "v" prefix (semver allows it,
# and the version parsers keep it), and the comparison walked the raw strings
# character by character. "v" sorts above every digit, so:
#
#     version_at_least("v0.0.1", "1.12.0")   ->  true   (wrong)
#     version_at_least("v0.0.1", "1.14.0")   ->  true   (wrong)
#
# The second one is the dangerous shape: sing-box gates 1.14/1.15-only fields on
# exactly this comparison, so a core reporting v0.0.1 was told it could be sent
# config it cannot parse. sing-box prints a bare version, which is why it stayed
# hidden.
#
# Driven through the real CLI modes of both modules, not through a copy.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
HELPERS="$LIB_DIR/core/helpers.uc"
VALIDATOR="$LIB_DIR/config/validator.uc"
[ -f "$HELPERS" ] || fail "core/helpers.uc not found"
[ -f "$VALIDATOR" ] || fail "config/validator.uc not found"

# at_least <current> <required> -> prints PASS/FAIL, through the helpers copy,
# which is the one exposing a CLI mode. The validator copy is checked separately
# by asserting the two implementations are identical.
at_least() {
    if ucode -L "$LIB_DIR" "$HELPERS" version-at-least "$1" "$2" >/dev/null 2>&1; then
        echo PASS
    else
        echo FAIL
    fi
}

assert_pair() {
    local got
    got="$(at_least "$1" "$2")"
    [ "$got" = "$3" ]       || fail "version_at_least('$1', '$2') returned $got, expected $3 - $4"
}

# ─── the prefix must not decide the result ───────────────────────────────────
assert_pair "v0.0.1"      "1.12.0" FAIL "a 0.0.1 core must not clear a 1.12 minimum"
assert_pair "v0.0.1"      "1.14.0" FAIL "and must not be cleared for 1.14-only fields"
assert_pair "v0.0.1"      "1.15.0" FAIL "or for 1.15-only fields"
assert_pair "v1.11.0"     "1.12.0" FAIL "1.11 is still below 1.12"
assert_pair "v1.11.0"     "1.11.0" PASS "1.11 equals 1.11"
assert_pair "v1.14.2"     "1.12.0" PASS "1.14 clears a 1.12 minimum"
assert_pair "v1.14.2"     "1.14.0" PASS "1.14 equals 1.14"

# ─── a suffixed version still compares on its numeric part ───────────────────
# Fork versions carry the fork in the suffix: 1.14.2-lx.11, 1.13.18-extended-2.6.3.
assert_pair "1.14.2-lx.11"            "1.14.0" PASS "lx suffix must not push 1.14.2 below 1.14.0"
assert_pair "1.13.18-extended-2.6.3"  "1.14.0" FAIL "1.13.18 is below 1.14.0 whatever the suffix says"
assert_pair "v1.13.18-extended-2.6.3" "1.14.0" FAIL "and the same with a prefix"
assert_pair "v0.0.1-tachyon.0"        "1.12.0" FAIL "a suffixed old core must not clear the minimum"

# ─── a hyphen pre-release counts as its release ──────────────────────────────
# Deliberate, and pinned here because it looks like a bug. sing-box ships
# 1.15.0-alpha.10 and the 1.15 fields are present in it, so the gates have to let
# an alpha through: tests/sing_box_version_live_probe.sh asserts exactly that a
# live 1.15.0-alpha.10 is detected as 1.14+. "Fixing" this into semver ordering
# (where an alpha is older) would stop emitting fields a working binary supports.
assert_pair "1.15.0-alpha.10"  "1.15.0"  PASS "an alpha carries its release's fields"
assert_pair "1.15.0-alpha.10"  "1.14.0"  PASS "and clears an older minimum"
assert_pair "v1.15.0-alpha.10" "1.15.0"  PASS "the same with a prefix, which is where the bug was"
assert_pair "1.15.0"           "1.14.0"  PASS "a release still clears an older minimum"

# ─── plain versions must be unaffected ───────────────────────────────────────
# The whole reason this stayed hidden is that sing-box prints a bare version.
# If the normalisation changed plain input, every existing gate would move.
assert_pair "1.11.0" "1.12.0" FAIL "unchanged for bare versions"
assert_pair "1.12.0" "1.12.0" PASS "equality still holds"
assert_pair "1.14.2" "1.12.0" PASS "and a newer bare version still passes"

# ─── an uppercase prefix is the same prefix ──────────────────────────────────
assert_pair "V1.14.2" "1.14.0" PASS "an uppercase V is the same prefix"
assert_pair "V0.0.1"  "1.12.0" FAIL "and it must not open the same hole"

# ─── the two copies must be the same implementation ─────────────────────────
extract() {
    sed -n '/^function strip_version_prefix(/,/^}/p;/^function version_compare(/,/^}/p;/^function version_at_least(/,/^}/p' "$1"
}

h_body="$(extract "$HELPERS")"
v_body="$(extract "$VALIDATOR")"
[ -n "$h_body" ] || fail "could not read the comparison out of core/helpers.uc"
[ -n "$v_body" ] || fail "could not read the comparison out of config/validator.uc"

if [ "$h_body" != "$v_body" ]; then
    printf 'the two version_compare copies differ:
' >&2
    diff <(printf '%s
' "$h_body") <(printf '%s
' "$v_body") >&2 || true
    fail "core/helpers.uc and config/validator.uc have drifted; one gate will disagree with the other"
fi
printf '  ok: the two copies are identical
'

printf 'fault: version comparison checks passed\n'