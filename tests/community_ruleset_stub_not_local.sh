#!/usr/bin/env bash
# BUG (TCH-1043): a community ruleset that could not be downloaded is written as
# a placeholder SRS. That placeholder is itself a syntactically valid binary
# ruleset of exactly 17 bytes, so the "is there a local list?" test accepted it
# and the generator emitted:
#
#   { "type": "local", "format": "binary", "path": ".../community-ads_hagezi_pro.srs" }
#
# No url, no update_interval. sing-box loads the empty list happily, the block
# rule matches nothing, and the ads keep coming. The only recovery was a manual
# list update, because nothing in the config could ever fetch the real file.
#
# The invariant: a placeholder must never satisfy "a real list is present
# locally". A rule over an empty list is indistinguishable from no rule at all,
# so falling through to the remote branch (which can self-heal) is the safe
# direction.
#
# Drives the real predicates on a real placeholder decoded from the module's own
# constant, so it cannot pass against a copy of the logic that agrees with
# itself, and it cannot drift if the placeholder ever changes size.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

RULESETS_UC="$TACHYON_LIB/singbox/rulesets.uc"
GENERATOR_UC="$TACHYON_LIB/singbox/generator_routes.uc"
[ -f "$RULESETS_UC" ] || fail "singbox/rulesets.uc not found at $RULESETS_UC"
[ -f "$GENERATOR_UC" ] || fail "singbox/generator_routes.uc not found at $GENERATOR_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SANDBOX="$(mktemp -d /tmp/tachyon-stub-srs.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

# Written as a file rather than -e so the assertions read as data, not as a
# nested quoting problem, and so the ucode runs the same way on a router.
cat >"$SANDBOX/probe.uc" <<'PROBE'
let rs = require("singbox.rulesets");
let fs = require("fs");

// Reports what the module actually provides, so the same probe runs against the
// pre-fix code too and the failure is a failed assertion rather than a crash.
let has_populated = type(rs.is_populated_srs_file) == "function";

let decoded = b64dec(rs.EMPTY_SRS_B64);
let stub_path = ARGV[0];
let real_path = ARGV[1];

fs.writefile(stub_path, decoded);
let st = fs.stat(stub_path);
print("STUB_SIZE ", st ? st.size : -1, "\n");
print("STUB_VALID ", rs.is_valid_srs_file(stub_path) ? 1 : 0, "\n");
print("STUB_POPULATED ", has_populated && rs.is_populated_srs_file(stub_path) ? 1 : 0, "\n");

// A real list: the placeholder plus a plausible payload. Clearly larger, so
// this is not the case being fixed.
fs.writefile(real_path, decoded + "SRS-padding-0123456789abcdefghij");
let st2 = fs.stat(real_path);
print("REAL_SIZE ", st2 ? st2.size : -1, "\n");
print("REAL_VALID ", rs.is_valid_srs_file(real_path) ? 1 : 0, "\n");
print("REAL_POPULATED ", has_populated && rs.is_populated_srs_file(real_path) ? 1 : 0, "\n");
print("HAS_POPULATED ", has_populated ? 1 : 0, "\n");
PROBE

out="$(ucode -L "$TACHYON_LIB" "$SANDBOX/probe.uc" "$SANDBOX/stub.srs" "$SANDBOX/real.srs" 2>&1)" ||
  fail "predicate probe failed: $out"

val() { printf '%s\n' "$out" | grep "^$1 " | cut -d' ' -f2; }

STUB_SIZE="$(val STUB_SIZE)"
STUB_VALID="$(val STUB_VALID)"
STUB_POPULATED="$(val STUB_POPULATED)"
REAL_SIZE="$(val REAL_SIZE)"
REAL_POPULATED="$(val REAL_POPULATED)"

HAS_POPULATED="$(val HAS_POPULATED)"

[ -n "$STUB_SIZE" ] && [ -n "$STUB_POPULATED" ] && [ -n "$REAL_POPULATED" ] &&
  [ -n "$HAS_POPULATED" ] ||
  fail "probe did not report what this test asserts on: $out"

# --- 0. the module must offer the predicate at all -------------------------
[ "$HAS_POPULATED" = "1" ] ||
  fail "singbox/rulesets.uc exports no is_populated_srs_file(): callers asking whether a real list is present can only ask is_valid_srs_file, which the ${STUB_SIZE}-byte placeholder satisfies"
ok

# --- 1. the placeholder is a valid SRS: this is the trap, not the bug --------
# Asserted explicitly. If a future change made the placeholder invalid, the old
# broken predicate would start returning false and this whole bug would be
# "fixed" by accident while the test reports nothing about it.
[ "$STUB_VALID" = "1" ] ||
  fail "precondition: the placeholder must still pass is_valid_srs_file, otherwise this test no longer covers the trap it describes"
ok

# --- 2. so it must not count as populated ----------------------------------
[ "$STUB_POPULATED" = "0" ] ||
  fail "is_populated_srs_file accepted the ${STUB_SIZE}-byte placeholder: the generator emits a url-less local rule_set and the rule can never fetch the real list"
ok

# --- 3. a real list is still accepted --------------------------------------
# The other direction, and the one a lazy "reject everything" fix would break:
# rejecting real lists would turn every section into a remote fetch.
[ "$REAL_SIZE" -gt "$STUB_SIZE" ] ||
  fail "fixture error: the real-list fixture ($REAL_SIZE) must be larger than the placeholder ($STUB_SIZE)"
[ "$REAL_POPULATED" = "1" ] ||
  fail "is_populated_srs_file rejected a real ${REAL_SIZE}-byte list: every section would become a remote fetch"
ok

# --- 4. the generator must not accept the stub as a local list -------------
# Source-level pin on the call sites. This is what actually produced the broken
# config, and it is the part a predicate-only test would not catch.
sites="$(grep -c 'is_valid_srs_file(tmp_srs) || helpers.file_is_usable(tmp_srs, 16)' "$GENERATOR_UC" || true)"
[ "$sites" = "0" ] ||
  fail "generator_routes.uc still gates local/community lists on is_valid_srs_file with a 16-byte threshold ($sites site(s)); the placeholder passes it"
ok

echo "community_ruleset_stub_not_local: $pass_count checks passed"