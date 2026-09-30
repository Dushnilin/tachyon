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
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
RUNTIME_UC="$LIB_DIR/singbox/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
#    group 1 is the index, group 2 the field.
grep -qE 'int\(out_field_m\[1\],' "$RUNTIME_UC" ||
  fail "runtime.uc does not read the outbound index out of the match, so a captured index would be ignored"

grep -qE 'unknown_field = out_field_m\[2\];' "$RUNTIME_UC" ||
  fail "runtime.uc does not read the field name from the second capture group"

# 3. The blanket delete is the actual bug. A loop over cfg.outbounds still exists
#    in runtime.uc and is legitimate: the unknown-transport branch has to walk
#    every outbound to drop the dead tag from their member lists. So this checks
#    the stripping branch specifically - it must iterate a narrowed list, not
#    cfg.outbounds. Asserting on the loop alone was the wrong test and flagged
#    that correct branch.
grep -qE 'for \(let outb in targets\)' "$RUNTIME_UC" ||
  fail "the field-stripping branch does not iterate a narrowed target list, so it still deletes the field from every outbound"

# 4. And the fix has to actually narrow the target list.
grep -qE 'cfg\.outbounds\[bad_index\]' "$RUNTIME_UC" ||
  fail "runtime.uc does not narrow the strip to the reported outbound index"

printf 'fault: sing-box field fallback is scoped passed\n'
