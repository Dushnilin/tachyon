#!/usr/bin/env bash
# FAULT: one unsupported field cost every working outbound its setting.
#
# Reported on 192.168.1.1:
#
#   [warn] Installed sing-box does not support outbound field 'default';
#          retrying without it
#
# The field is not universally unsupported - it depends on the outbound type.
# Checked against the real binaries:
#
#   field    selector          urltest
#   default  accepted (all 3)  REJECTED (all 3)
#
# stock 1.14.2, 1.14.2-lx.8 and 1.14.1-extended-2.7.2 behave identically on both.
#
# The compatibility retry deleted the offending field from *every* outbound rather
# than from the one sing-box named in its error. sing-box says exactly which
# outbound it refused - "outbounds[7].default" - the regex captured the index, and
# the code then ignored it. So one urltest that cannot take `default` silently
# removed it from every selector too, and with it the starting node the user had
# chosen. That repeated on every regenerate, which is why the warning kept coming
# back.
#
# This asserts on the real source file, not on a copy of the logic. An earlier
# draft embedded its own copy of the regex and the stripping, which would have
# passed unchanged against the broken code - the trap that has already produced
# several false greens in this suite. The file itself is the unit under test.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
RUNTIME_UC="$LIB_DIR/singbox/runtime.uc"

[ -f "$RUNTIME_UC" ] || fail "singbox/runtime.uc not found"

# 1. The regex must capture the outbound index, not just the field name. The old
#    one was /outbounds\[\d+\]\.(\w+)/, where the index is present but ungrouped.
regex="$(grep -oE '/outbounds[^/]*/' "$RUNTIME_UC" | head -1)"
[ -n "$regex" ] || fail "could not find the outbound-field regex in singbox/runtime.uc"

case "$regex" in
  *'(\d+)'*) ;;
  *)
    fail "the outbound-field regex does not group the index, so the retry cannot be scoped to the one outbound sing-box named: $regex"
    ;;
esac

# 2. The index and the field must be read out of the match, at the right offsets:
#    group 1 is the index, group 2 the field. The apply path reads them in
#    repair_outbound_field() for its log line; the strip itself was moved to
#    components/verifier so apply and pre-flight cannot drift (its inlined copy
#    had drifted into a to_string() crash that took the whole start down).
#
# The index is read with plain int(m[1]). int(x, base) is a base, not a default:
# int("23", -1) is 0, so the two-argument form silently aimed every repair at
# outbound 0 - the opposite of the narrowing this branch exists for. Asserted
# positively so the form cannot drift back.
grep -qE 'int\(m\[1\]\)' "$RUNTIME_UC" ||
  fail "runtime.uc must read the outbound index with int(m[1]); int(m[1], -1) is a base argument and always yields 0, so the repair would strip the wrong outbound"

if grep -qE 'int\([a-z_]*m\[1\],' "$RUNTIME_UC"; then
  fail "runtime.uc still passes a second argument to int() for the outbound index, which makes it 0"
fi

grep -qE 'm\[2\]' "$RUNTIME_UC" ||
  fail "runtime.uc does not read the field name from the second capture group"

# 3. The strip lives in components/verifier and must still narrow to the
#    outbound sing-box named: a loop over cfg.outbounds is the actual bug
#    (one urltest losing `default` removed it from every selector too). The
#    blanket loop must not exist anywhere in the apply path any more.
VERIFIER_UC="$LIB_DIR/components/verifier.uc"
[ -f "$VERIFIER_UC" ] || fail "components/verifier.uc not found"

grep -qE 'target = cfg\.outbounds\[index\]' "$VERIFIER_UC" ||
  fail "the shared repair does not narrow the strip to the reported outbound index"

grep -qE 'index >= length\(cfg\.outbounds\)' "$VERIFIER_UC" ||
  fail "the shared repair does not bounds-check the reported index"

if grep -qE 'for \(let outb in targets\)' "$RUNTIME_UC"; then
  fail "runtime.uc still strips the field inline instead of using the shared, narrowed repair"
fi

# 4. And the apply path has to actually call that shared repair, or the next
#    refactor silently forks the logic again.
grep -q 'repair_unknown_outbound_field' "$RUNTIME_UC" ||
  fail "the apply path does not call components/verifier repair_unknown_outbound_field"

printf 'fault: sing-box field fallback is scoped passed\n'
