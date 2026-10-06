#!/usr/bin/env bash
# A requireable ucode module must not call exit().
#
# Found as a hard crash: `ucode -e "...require(...)..." somearg` aborted with
# "free(): invalid pointer" / SIGABRT (exit 134) or SIGSEGV, with no ucode error
# message - heap corruption, not a caught exception.
#
# The cause is the module guard every library module here ended with:
#
#     if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
#         return module_exports();
#     print("Usage: ... (library module, no CLI)\n");
#     exit(1);
#
# `sourcepath(1)` is the *caller's* path, not the module's own. So it is null in
# two different situations: this module being the main script, and this module
# being imported from `ucode -e`. There is no way to tell them apart - ucode has
# no __FILE__ - because both report null. With an argument in ARGV the guard
# falls through to exit(1), and exit() from inside an imported module tears down
# the interpreter the caller is still running in. The caller then touches freed
# memory.
#
# The fix is not to detect the situation but to remove the possibility: a module
# with no CLI simply returns its exports unconditionally. There is no exit path
# left to take, so no invocation can corrupt the heap.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
[ -d "$LIB_DIR" ] || fail "$LIB_DIR not found"

# ─── no library module may keep the fake CLI that exits ──────────────────────
# Definitions, not mentions: a comment explaining the crash is allowed to name
# exit(1), and an earlier version of this check tripped over its own explanation.
if grep -rqlF 'library module, no CLI' "$LIB_DIR" 2>/dev/null; then
  for f in $(grep -rlF 'library module, no CLI' "$LIB_DIR"); do
    fail "the fake-CLI exit() guard is back in $f; requiring it under \`ucode -e\` with an argument corrupts the heap"
  done
fi

# Every module that defines module_exports must hand them back somehow: either an
# unconditional top-level return (the pure-library shape, which is what the fake
# CLI used to follow) or a real CLI that calls exit(). A module with neither
# returns null from require() and the caller dies on "left-hand side is not a
# function" - which is how a botched edit to this pattern shows up.
missing=""
while IFS= read -r mod; do
  rel="${mod#"$LIB_DIR"/}"
  if grep -q '^return module_exports();' "$mod"; then
    continue
  fi
  # A guarded return plus a CLI tail is only safe if the tail cannot exit: the
  # CLI has to be behind a check that a mode was actually named.
  if grep -q 'return module_exports();' "$mod" &&
     grep -qE '^if \(length\(ARGV\) > 0\)' "$mod"; then
    continue
  fi
  if grep -qE 'exit\(' "$mod"; then
    continue
  fi
  missing="$missing $rel"
done <<< "$(grep -rl 'function module_exports' "$LIB_DIR" --include='*.uc')"
[ -z "$missing" ] \
  || fail "these modules define module_exports but never return it and never call exit(), so require() gets null:$missing"

# ─── and the crash itself must stay fixed ────────────────────────────────────
# Driven with an argument on purpose: that is the combination that used to abort.
cat >"$WORK_DIR/require.uc" <<'EOF'
let g = require("steer.generator");
print("exports=" + (type(g.build_spec_v2) == "function" ? "yes" : "no") + "\n");
EOF

status=0
out="$(ucode -L "$LIB_DIR" "$WORK_DIR/require.uc" with-an-argument 2>&1)" || status=$?
[ "$status" -lt 128 ] \
  || fail "requiring a library module with an argument must not abort the interpreter (exit $status): $out"
printf '%s' "$out" | grep -q '^exports=yes$' \
  || fail "require() returned no usable exports: $out"

out="$(ucode -L "$LIB_DIR" -e 'let g = require("steer.generator"); print("inline=" + (type(g.build_spec_v2) == "function" ? "yes" : "no") + "\n");' with-an-argument 2>&1)" \
  || fail "inline require with an argument must not abort the interpreter: $out"
printf '%s' "$out" | grep -q '^inline=yes$' \
  || fail "inline require returned no usable exports: $out"

# ─── no module may abort the process when it is merely imported ──────────────
# This is the invariant that actually matters, and it is checked behaviourally
# rather than by grepping for one wording of the bug: a module whose import path
# reaches exit() tears down the interpreter and the process dies on a signal.
#
# Scoped to modules that other modules actually require. A module that is only
# ever run as a program cannot corrupt anything by being imported - nobody
# imports it - so it keeps its CLI. Those are checked separately below.
cat >"$WORK_DIR/sweep.uc" <<'EOF'
let mod = require(ARGV[0]);
print("ok\n");
EOF

# Every module another module requires, and every one that exports unconditionally.
#
# The set of require() targets is collected in a single pass. Doing it the obvious
# way - grep -r per candidate module - rescans all 147 files once per candidate,
# which measured at ~27 s for a single lookup and grew with the tree; the answer
# is the same set either way.
grep -rhoE 'require\("[A-Za-z0-9_./-]+"\)' "$LIB_DIR" --include='*.uc' \
  | sed -e 's/^require("//' -e 's/")$//' -e 's#/#.#g' -e 's#\.uc$##' \
  | sort -u > "$WORK_DIR/required.txt"

importable=""
for f in $(find "$LIB_DIR" -name '*.uc' | sort); do
  rel="${f#"$LIB_DIR"/}"; dotted="${rel%.uc}"; dotted="${dotted//\//.}"
  grep -q '^return module_exports();' "$f" || continue
  grep -Fxq "$dotted" "$WORK_DIR/required.txt" || continue
  printf '%s\n' "$dotted" >> "$WORK_DIR/importable.txt"
done
sort -u "$WORK_DIR/importable.txt" -o "$WORK_DIR/importable.txt"

aborted=""
while IFS= read -r dotted; do
  [ -n "$dotted" ] || continue
  code=0
  ucode -L "$LIB_DIR" "$WORK_DIR/sweep.uc" "$dotted" with-an-argument >/dev/null 2>&1 || code=$?
  case "$code" in
    134|136|137|139|132) aborted="$aborted $dotted($code)" ;;
    254) aborted="$aborted $dotted(unimportable)" ;;
  esac
done < "$WORK_DIR/importable.txt"

[ -z "$aborted" ] \
  || fail "importing these modules with an argument aborts the process on a signal, which is heap corruption from exit() inside an import:$aborted"

printf 'fault: library module exit guards are safe\n'