#!/usr/bin/env bash
# FAULT: garbage at the configuration trust boundary.
#
# plan() is reachable from the UI, the REST agent API and MCP, so its input is
# untrusted: a candidate can be a path, raw UCI text or a JSON dictionary, and
# it may be truncated, hostile or simply the wrong type. The contract is that it
# never throws, always answers with a verdict, and a rejected candidate comes
# back with a reason naming the problem.
#
# A plan that crashes on malformed input is worse than one that rejects it: the
# caller is left with a stack trace and no way to tell the user what is wrong.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
PLAN_UC="$LIB_DIR/service/config_plan.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$PLAN_UC" ] || fail "service/config_plan.uc not found"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

# Runs plan() on the given source and prints: ok|verdict-hash
run_plan() {
  local source="$1" label="$2"
  local out rc
  set +e
  out="$(ucode -L "$LIB_DIR" "$PLAN_UC" plan "$source" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ge 128 ] || printf '%s' "$out" | grep -qiE 'type error|runtime error|syntax error|left-hand side|traceback'; then
    printf 'FAIL: %s made plan() crash (rc=%s): %s\n' "$label" "$rc" "$out" >&2
    return 1
  fi
  return 0
}

# --- the built-in selftest has to hold before any of this means anything ----
selftest_out="$(ucode -L "$LIB_DIR" "$PLAN_UC" selftest 2>&1)" || fail "config_plan selftest failed: $selftest_out"

# --- a candidate that exists but is nonsense -------------------------------
printf 'not uci at all\n\x00\x01 garbage\n' > "$WORK_DIR/garbage.uci"
run_plan "$WORK_DIR/garbage.uci" "binary garbage as a path"

printf 'config section\n  option "unterminated\n' > "$WORK_DIR/truncated.uci"
run_plan "$WORK_DIR/truncated.uci" "truncated UCI"

printf '' > "$WORK_DIR/empty.uci"
run_plan "$WORK_DIR/empty.uci" "empty file"

run_plan "$WORK_DIR/does-not-exist.uci" "missing file"

# --- semantically invalid but syntactically fine UCI ------------------------
# An unsupported action has to be an error, not a silent pass.
cat > "$WORK_DIR/bad-action.uci" <<'EOF'
config section 'broken'
    option enabled '1'
    option action 'definitely-not-an-action'
EOF
out="$(ucode -L "$LIB_DIR" "$PLAN_UC" plan "$WORK_DIR/bad-action.uci" 2>&1)" || true
printf '%s' "$out" | grep -qiE 'type error|runtime error|left-hand side' \
  && fail "an unsupported action crashed plan(): $out"

# A section name carrying shell metacharacters must be rejected, not carried
# into a later shell command.
cat > "$WORK_DIR/bad-name.uci" <<'EOF'
config section 'evil;rm -rf /'
    option enabled '1'
    option action 'outbound'
EOF
out="$(ucode -L "$LIB_DIR" "$PLAN_UC" plan "$WORK_DIR/bad-name.uci" 2>&1)" || true
printf '%s' "$out" | grep -qiE 'type error|runtime error|left-hand side' \
  && fail "a hostile section name crashed plan(): $out"
printf '%s' "$out" | grep -qiE 'invalid characters|unsupported|invalid' \
  || fail "a section name with shell metacharacters was not reported as invalid: $out"

# --- a large candidate must not wedge the validator -------------------------
python_free_big="$WORK_DIR/big.uci"
{
  printf "config section 'big'\n    option enabled '1'\n    option action 'outbound'\n"
  i=0
  while [ "$i" -lt 400 ]; do
    printf "    list domain 'host%d.example.com'\n" "$i"
    i=$((i + 1))
  done
} > "$python_free_big"
run_plan "$python_free_big" "400-entry section"

printf 'fault: invalid config checks passed\n'
