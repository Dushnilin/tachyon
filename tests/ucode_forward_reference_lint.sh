#!/usr/bin/env bash
# ucode resolves a call target when the callee is defined, not when the caller
# is defined. A top-level function that calls a sibling declared further down
# the file compiles fine but dies at runtime with
# "left-hand side is not a function". That silently broke Tachyon self-update
# (pkg_tx_install_files -> sanitize_apk_world).
#
# This test statically rejects any such forward reference in the backend.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
LINTER_DIR="$ROOT_DIR/tests/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -d "$LIB_DIR" ] || fail "backend lib directory not found: $LIB_DIR"

command -v node >/dev/null 2>&1 || fail "node is required to run the forward reference linter"

# The linter must catch a known-bad snippet before we trust it on the tree.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/bad.uc" <<'EOF'
function caller() { callee(); }
function callee() { print("ok\n"); }
caller();
EOF

if node "$LINTER_DIR/ucode_forward_refs.js" "$tmp_dir/bad.uc" >/dev/null 2>&1; then
  fail "linter failed to flag a forward reference (self-test)"
fi

# A definition-ordered version of the same snippet must pass.
cat >"$tmp_dir/good.uc" <<'EOF'
function callee() { print("ok\n"); }
function caller() { callee(); }
caller();
EOF

node "$LINTER_DIR/ucode_forward_refs.js" "$tmp_dir/good.uc" >/dev/null 2>&1 ||
  fail "linter rejected a correctly ordered snippet (self-test)"

# Regression: regex literals containing unbalanced braces must not break the
# scanner (previously the linter went blind after a line like /[-=~_]{4,}/).
cat >"$tmp_dir/regex_braces.uc" <<'EOF'
function caller() { callee(); }
function helper() {
    if (match(last, /^[-=~_]{4,}$/) || match(other, /^(\d{1,3}\.){3}\d{1,3}$/))
        return 1;
    return 0;
}
function callee() { print("ok\n"); }
EOF

if node "$LINTER_DIR/ucode_forward_refs.js" "$tmp_dir/regex_braces.uc" >/dev/null 2>&1; then
  fail "linter went blind after a regex with braces (self-test)"
fi

# Regression: a top-level object literal must not make the linter skip every
# function declared after it.
cat >"$tmp_dir/top_level_object.uc" <<'EOF'
const LIMITS = { soft: 10, hard: 20 };
function caller() { callee(); }
function callee() { print("ok\n"); }
EOF

if node "$LINTER_DIR/ucode_forward_refs.js" "$tmp_dir/top_level_object.uc" >/dev/null 2>&1; then
  fail "linter skipped functions after a top-level object literal (self-test)"
fi

node "$LINTER_DIR/ucode_forward_refs.js" "$LIB_DIR" ||
  fail "forward references found in backend ucode"

printf 'PASS: ucode forward reference lint\n'
