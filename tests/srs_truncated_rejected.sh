#!/usr/bin/env bash
# A truncated .srs passes every cheap check Tachyon makes: the "SRS" magic sits at
# the front, and a prefix of a real list is still far larger than the placeholder.
# sing-box then dies on it with "parse rule-set: read rule: unexpected EOF", takes
# the whole generated config down with it, and the router stops applying anything -
# a red check no list update clears. Reported on 1.4.9.
#
# The payload is a zlib stream, so the real length is not in the header and no size
# comparison can tell a whole file from a prefix. The check therefore asks sing-box
# to parse it, which is stubbed here: the test is about which files we adopt, not
# about sing-box's parser.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RULESETS_UC="$TACHYON_LIB/singbox/rulesets.uc"
[ -f "$RULESETS_UC" ] || fail "missing $RULESETS_UC"

STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"

# A stand-in for sing-box that rejects any file the test marked as truncated, by
# name. Anything else it accepts, which is what a whole file does.
cat >"$STUB_BIN/sing-box" <<'STUB'
#!/usr/bin/env bash
set -eo pipefail
for arg in "$@"; do
  case "$arg" in
    *truncated*) echo "FATAL parse rule-set: read rule[0]: unexpected EOF" >&2; exit 1 ;;
  esac
done
exit 0
STUB
chmod 0755 "$STUB_BIN/sing-box"

export TACHYON_SING_BOX_BIN="$STUB_BIN/sing-box"

# Whole file: real magic, and comfortably past the placeholder.
printf 'SRS\001\072\332\102\000\004\000\000\377\377\000\001\000\001payload' \
  >"$WORK_DIR/whole.srs"

# Same file with its tail cut off: still valid magic, still over 100 bytes.
head -c 24 "$WORK_DIR/whole.srs" >"$WORK_DIR/truncated.srs"

# The placeholder itself: a valid SRS, and not a list.
cp "$TACHYON_LIB/../share/tachyon/rulesets/empty.srs" "$WORK_DIR/stub.srs" 2>/dev/null ||
  cp "$ROOT_DIR/tachyon/files/usr/share/tachyon/rulesets/empty.srs" "$WORK_DIR/stub.srs"

# Not an SRS at all.
printf 'not a rule-set at all' >"$WORK_DIR/garbage.bin"

check() { # <mode> <path> <expected: yes|no> <label>
  local out rc
  set +e
  out="$(ucode -S -L "$TACHYON_LIB" "$RULESETS_UC" "$1" "$2" 2>&1)"
  rc=$?
  set -e
  local got=no
  [ "$rc" -eq 0 ] && got=yes
  if [ "$got" != "$3" ]; then
    printf 'FAIL: %s: %s said %s, expected %s\n%s\n' "$4" "$1" "$got" "$3" "$out" >&2
    exit 1
  fi
}

# The old predicate still answers "not corrupt" - it cannot see the truncation, and
# that is exactly why it was not enough. Asserted so the distinction stays honest.
check is-valid-srs-file "$WORK_DIR/truncated.srs" yes "is_valid_srs_file on a truncated file"
check is-valid-srs-file "$WORK_DIR/garbage.bin"  no  "is_valid_srs_file on garbage"

# The new one refuses it, and still accepts everything that was fine before.
check is-usable-srs-file "$WORK_DIR/truncated.srs" no "is_usable_srs_file on a truncated file"
check is-usable-srs-file "$WORK_DIR/whole.srs"     yes "is_usable_srs_file on a whole file"
check is-usable-srs-file "$WORK_DIR/stub.srs"      no  "is_usable_srs_file on the placeholder"
check is-usable-srs-file "$WORK_DIR/garbage.bin"   no  "is_usable_srs_file on garbage"
check is-usable-srs-file "$WORK_DIR/missing.srs"   no  "is_usable_srs_file on a missing file"

# Without sing-box there is nothing to ask, and the cheap checks are all we have:
# the function must degrade to the old answer instead of rejecting every list.
out="$(TACHYON_SRS_VERIFY_DIR="$WORK_DIR/verify-none" TACHYON_SING_BOX_BIN="$WORK_DIR/absent-sing-box" \
  ucode -S -L "$TACHYON_LIB" "$RULESETS_UC" is-usable-srs-file "$WORK_DIR/whole.srs" 2>&1)" ||
  { printf 'FAIL: without sing-box a whole list was rejected: %s\n' "$out" >&2; exit 1; }

# And the adopt paths must ask for the strict predicate, not the cheap one. Both
# call sites matter: a truncated download must not be published, and a truncated
# /etc copy must not be promoted after a failed download.
for f in "$TACHYON_LIB/components/updates.uc" "$TACHYON_LIB/service/lifecycle.uc"; do
  [ -f "$f" ] || fail "missing $f"
  if ! grep -q 'is_usable_srs_file\|is_adoptable_srs_file' "$f"; then
    fail "$f adopts .srs files without asking sing-box whether they parse"
  fi
done

# The /tmp copy has to be validated too. It used to be trusted outright, and that is
# what left the reported router stuck: the file an older Tachyon downloaded passed
# the cheap test, sing-box died on it, and the copy that was broken was the copy
# believed - so neither an apply nor a list update could recover.
if ! grep -q 'is_adoptable_srs_file(tmp_path)' "$TACHYON_LIB/service/lifecycle.uc"; then
  fail "lifecycle.uc trusts the /tmp copy without asking sing-box; a file downloaded before the fix stays broken forever"
fi

if ! grep -q 'is_adoptable_srs_file(etc_path)' "$TACHYON_LIB/service/lifecycle.uc"; then
  fail "restore_rulesets_from_cache copies /etc .srs files into the ruleset sing-box reads without parsing them first"
fi

# Validating spawns a process, so it must happen once per file and not once per
# apply. The marker lives in tmpfs next to the file it describes, and its stamp
# carries the mtime as well as the size: a rewrite that lands the same length is a
# different file as far as this is concerned.
STUB_LOG="$WORK_DIR/stub.log"
: >"$STUB_LOG"
cat >"$STUB_BIN/sing-box" <<STUB
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "\$*" >>"$STUB_LOG"
for arg in "\$@"; do
  case "\$arg" in
    *truncated*) echo "FATAL parse rule-set: read rule[0]: unexpected EOF" >&2; exit 1 ;;
  esac
done
exit 0
STUB
chmod 0755 "$STUB_BIN/sing-box"

export TACHYON_SRS_VERIFY_DIR="$WORK_DIR/verify"

adopt() { # <path> <expected yes|no> <label>
  local rc got=no
  set +e
  ucode -S -L "$TACHYON_LIB" "$RULESETS_UC" is-adoptable-srs-file "$1" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && got=yes
  [ "$got" = "$2" ] || { printf 'FAIL: %s: got %s, expected %s\n' "$3" "$got" "$2" >&2; exit 1; }
}

spawns() { grep -c decompile "$STUB_LOG" 2>/dev/null || true; }

adopt "$WORK_DIR/whole.srs" yes "first adopt of a whole list"
[ "$(spawns)" = "1" ] || { printf 'FAIL: first adopt spawned %s times, expected 1\n' "$(spawns)" >&2; exit 1; }

adopt "$WORK_DIR/whole.srs" yes "second adopt of the same list"
[ "$(spawns)" = "1" ] ||
  { printf 'FAIL: re-checking an unchanged file spawned again (%s spawns): that is a process per list per apply\n' "$(spawns)" >&2; exit 1; }

# Same length, newer mtime: the stamp has to notice, or a rewritten file inherits
# the verdict of the file it replaced.
touch -d '+1 hour' "$WORK_DIR/whole.srs"
adopt "$WORK_DIR/whole.srs" yes "adopt after the file changed"
[ "$(spawns)" = "2" ] ||
  { printf 'FAIL: a rewritten file reused the old verdict (%s spawns, expected 2)\n' "$(spawns)" >&2; exit 1; }

# A truncated file is never adopted. It is re-parsed every time rather than
# remembered as bad: the next apply is the first chance to notice it was replaced,
# and a negative verdict cached to tmpfs would outlive the repair.
adopt "$WORK_DIR/truncated.srs" no "adopt of a truncated list"
adopt "$WORK_DIR/truncated.srs" no "second adopt of a truncated list"
[ "$(spawns)" = "4" ] ||
  { printf 'FAIL: expected 4 spawns after the truncated adopts, got %s\n' "$(spawns)" >&2; exit 1; }

printf 'PASS: srs_truncated_rejected\n'