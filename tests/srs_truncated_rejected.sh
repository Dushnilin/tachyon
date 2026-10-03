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
out="$(TACHYON_SING_BOX_BIN="$WORK_DIR/absent-sing-box" \
  ucode -S -L "$TACHYON_LIB" "$RULESETS_UC" is-usable-srs-file "$WORK_DIR/whole.srs" 2>&1)" ||
  { printf 'FAIL: without sing-box a whole list was rejected: %s\n' "$out" >&2; exit 1; }

# And the adopt paths must ask for the strict predicate, not the cheap one. Both
# call sites matter: a truncated download must not be published, and a truncated
# /etc copy must not be promoted after a failed download.
for f in "$TACHYON_LIB/components/updates.uc" "$TACHYON_LIB/service/lifecycle.uc"; do
  [ -f "$f" ] || fail "missing $f"
  if ! grep -q 'is_usable_srs_file' "$f"; then
    fail "$f adopts .srs files without asking sing-box whether they parse"
  fi
done

# The trusted-into-/tmp shortcut stays cheap: re-parsing every list on every apply
# would cost a process per list per apply for no gain.
if ! grep -q 'if (runtime_rulesets_mod.is_valid_srs_file(tmp_path))' "$TACHYON_LIB/service/lifecycle.uc"; then
  fail "lifecycle.uc must keep the cheap check for the already-present /tmp copy"
fi

printf 'PASS: srs_truncated_rejected\n'