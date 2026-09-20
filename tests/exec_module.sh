#!/usr/bin/env bash
set -eo pipefail

# Tests for core/exec.uc — unified process execution layer.
# Run on the router: bash /tmp/exec_module.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
EXEC_UC="$TACHYON_LIB/core/exec.uc"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# ── Selftest passes ──────────────────────────────────────────────────────────
ucode "$EXEC_UC" selftest || fail "exec.uc selftest failed"

# ── boot_id is readable and stable ───────────────────────────────────────────
BOOT1=$(ucode "$EXEC_UC" boot-id)
BOOT2=$(ucode "$EXEC_UC" boot-id)
[ -n "$BOOT1" ] || fail "boot_id should be non-empty"
assert_eq "$BOOT1" "$BOOT2" "boot_id should be stable across calls"

# ── starttime for PID 1 ─────────────────────────────────────────────────────
ST=$(ucode "$EXEC_UC" starttime 1)
[ -n "$ST" ] || fail "starttime for PID 1 should be readable"
[[ "$ST" =~ ^[0-9]+$ ]] || fail "starttime should be numeric, got: $ST"

# ── starttime for nonexistent PID ────────────────────────────────────────────
if ucode "$EXEC_UC" starttime 999999 >/dev/null 2>&1; then
  fail "starttime for nonexistent PID should return non-zero exit"
fi

# ── Run synchronously via module ─────────────────────────────────────────────
RESULT=$(ucode -e '
  let exec = require("core.exec");
  let r = exec.run({ argv: ["/bin/echo", "hello world"], timeout: 5 });
  print(r.status + ":" + r.output);
')
assert_eq "0:hello world" "$RESULT" "run() should capture output"

# ── Run with non-zero exit ───────────────────────────────────────────────────
STATUS=$(ucode -e '
  let exec = require("core.exec");
  print(exec.run_status({ argv: ["/bin/false"], timeout: 5 }));
')
[ "$STATUS" != "0" ] || fail "false should return non-zero status"

# ── Run with command string ──────────────────────────────────────────────────
RESULT=$(ucode -e '
  let exec = require("core.exec");
  let r = exec.run({ command: "echo test123", timeout: 5 });
  print(r.status + ":" + r.output);
')
assert_eq "0:test123" "$RESULT" "run() with command string should work"

# ── Background process with identity ─────────────────────────────────────────
BG_RESULT=$(ucode -e '
  let exec = require("core.exec");
  let bg = exec.run_background({
    argv: ["/bin/sh", "-c", "echo bg_ok"],
    stdout: "/dev/null",
    name: "test-bg"
  });
  print(bg.pid + ":" + (bg.identity != null ? "has_identity" : "no_identity"));
')
BG_PID=$(echo "$BG_RESULT" | cut -d: -f1)
BG_ID=$(echo "$BG_RESULT" | cut -d: -f2)
[[ "$BG_PID" =~ ^[0-9]+$ ]] || fail "background PID should be numeric, got: $BG_PID"
[ "$BG_PID" != "0" ] || fail "background PID should not be 0"
assert_eq "has_identity" "$BG_ID" "background process should have identity"

# ── is_alive for dead process ────────────────────────────────────────────────
ALIVE=$(ucode -e '
  let exec = require("core.exec");
  print(exec.is_alive("999999") ? "alive" : "dead");
')
assert_eq "dead" "$ALIVE" "nonexistent PID should not be alive"

# ── is_alive for init ────────────────────────────────────────────────────────
ALIVE=$(ucode -e '
  let exec = require("core.exec");
  print(exec.is_alive("1") ? "alive" : "dead");
')
assert_eq "alive" "$ALIVE" "PID 1 should always be alive"

# ── Identity matching ────────────────────────────────────────────────────────
ID_MATCH=$(ucode -e '
  let exec = require("core.exec");
  let id = exec.make_identity("1", "init");
  print(exec.identity_matches(id, "1") ? "match" : "nomatch");
')
assert_eq "match" "$ID_MATCH" "identity should match correct PID"

ID_NOMATCH=$(ucode -e '
  let exec = require("core.exec");
  let id = exec.make_identity("1", "init");
  print(exec.identity_matches(id, "999999") ? "match" : "nomatch");
')
assert_eq "nomatch" "$ID_NOMATCH" "identity should not match wrong PID"

# ── Kill nonexistent process is safe ─────────────────────────────────────────
KILL_RESULT=$(ucode -e '
  let exec = require("core.exec");
  print(exec.kill_process("999999") ? "killed" : "not_found");
')
assert_eq "not_found" "$KILL_RESULT" "kill nonexistent should return false"

# ── Backward-compatible command_success ──────────────────────────────────────
SUCCESS=$(ucode -e '
  let exec = require("core.exec");
  print(exec.command_success("/bin/true") ? "ok" : "fail");
')
assert_eq "ok" "$SUCCESS" "command_success(/bin/true) should return true"

# ── Backward-compatible command_output ────────────────────────────────────────
OUTPUT=$(ucode -e '
  let exec = require("core.exec");
  print(exec.command_output("/bin/echo compat"));
')
assert_eq "compat" "$OUTPUT" "command_output should work"

# ── close_inherited_fds is still accessible from common.uc ───────────────────
CLOSE_FDS=$(ucode -e '
  let common = require("core.common");
  let fds = common.close_inherited_fds();
  print(length(fds) > 10 ? "ok" : "short");
')
assert_eq "ok" "$CLOSE_FDS" "common.close_inherited_fds() should still work"

echo "core/exec.uc: all tests passed"
