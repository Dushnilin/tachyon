#!/usr/bin/env bash
# BUG (TCH-1046): the sing-box version was read as the last field of the first
# line of `sing-box version` output. That held for 1.13 ("sing-box version
# 1.13.0") and broke as soon as 1.14 put anything after the version:
#
#     sing-box 1.14.5 linux-amd64                          -> "linux-amd64"
#     sing-box version 1.14.5 (with_quic, with_tailscale) -> "with_tailscale)"
#
# Both then fail the caller's /^[vV]?[0-9]+/ gate and produce "". An empty
# version is not a cosmetic status problem: config/validator.uc turns it into
# fail_requirement(..., "Aborted."), so the apply dies and the user is left with
# a config that refuses to generate and no stated cause. This is exactly the
# report behind TCH-1046: "1.14.4 worked, upgraded to 1.14.5 and everything
# fell apart".
#
# The invariant: the version is the token after the word "version", wherever the
# banner puts it. Build tags after the version must not be mistaken for it.
#
# Drives the real predicate from core/common.uc - the single copy every caller
# now shares - so it cannot pass against a re-implementation that happens to
# agree with itself.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

COMMON_UC="$TACHYON_LIB/core/common.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
RUNTIME_UC="$TACHYON_LIB/singbox/runtime.uc"
[ -f "$COMMON_UC" ] || fail "core/common.uc not found at $COMMON_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SANDBOX="$(mktemp -d /tmp/tachyon-sbver.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

# Written as a file rather than -e: the banners are full of quotes, commas and
# parens, and inlining them through three layers of shell quoting reliably
# produces a test that passes for the wrong reason.
cat >"$SANDBOX/probe.uc" <<'PROBE'
let common = require("core.common");

// Mirrors singbox/runtime.uc's gate: a parsed version that is not version-shaped
// is discarded, which is how the old misparse turned into a fatal abort.
function gated(parsed) {
    return match(parsed, /^[vV]?[0-9]+/) ? parsed : "";
}

let banners = [
    // 1.13 shape: still the common case, must not regress.
    "sing-box version 1.13.0\n\nTags: with_quic\n",
    // The reported failure: version present, build tag after it.
    "sing-box version 1.14.5 (with_quic, with_tailscale)\n",
    "sing-box version 1.14.4-lx.4\n\nTags: with_quic,with_tailscale\n",
    // Version not preceded by the "version" keyword.
    "sing-box 1.14.5 linux-amd64\nsing-box version 1.14.5\n\nTags: with_quic\n",
    // Keyword absent entirely, platform after the version: the fallback must
    // find the version rather than the platform token.
    "sing-box 1.14.5 linux-amd64\n",
    // Leading v.
    "sing-box version v1.14.5\n\nTags: with_quic\n",
    // Extra lines after the banner.
    "sing-box version 1.14.5\nCopyright (C) 2023-2025\nTags: with_quic\n",
    // Degenerate: nothing usable at all.
    "",
    "command not found\n"
];

// Reports whether the shared predicate exists, so the same probe runs against
// the pre-fix code and fails on an assertion instead of crashing.
let has_parse = type(common.parse_sing_box_version) == "function";

for (let b in banners) {
    let parsed = has_parse ? common.parse_sing_box_version(b) : "MISSING";
    let usable = parsed == "MISSING" ? "" : gated(parsed);
    print("BANNER ", usable != "" ? "OK " : "DEAD", " parsed=[", parsed, "]\n");
}
print("HAS_PARSE ", has_parse ? 1 : 0, "\n");
PROBE

out="$(ucode -L "$TACHYON_LIB" "$SANDBOX/probe.uc" 2>&1)" || fail "parse probe failed: $out"

dead="$(printf '%s\n' "$out" | grep -c 'BANNER DEAD' || true)"
has_parse="$(printf '%s\n' "$out" | grep '^HAS_PARSE ' | cut -d' ' -f2)"

# --- the shared predicate must exist at all --------------------------------
[ "$has_parse" = "1" ] ||
  fail "core/common.uc exports no parse_sing_box_version(): every caller falls back to the positional guess, and config/validator.uc:2541 turns its empty result into a fatal Aborted."
ok

[ "$dead" = "2" ] ||
  fail "expected exactly the 2 degenerate banners to parse empty, got $dead: $out"
ok

# --- every real-world banner must survive ----------------------------------
# The six banners before the degenerate pair are the shapes seen across
# 1.13/1.14 builds. If any of them parses empty, the apply aborts fatally.
for want in 1.13.0 1.14.5 1.14.4-lx.4 v1.14.5; do
  printf '%s\n' "$out" | grep -F "parsed=[$want]" >/dev/null ||
    fail "banner that contains '$want' did not parse to it: $out"
  ok
done

# --- the tag must not be mistaken for the version -------------------------
# The precise 1.14.5 failure: the last field is the build tag, not the version.
printf '%s\n' "$out" | grep -F 'parsed=[with_tailscale)]' >/dev/null &&
  fail "the build tag was parsed as the version"
ok

# A banner with no "version" keyword anywhere. The fallback must still find the
# version and must not hand back the platform token that follows it: returning
# "linux-amd64" is worse than returning "", because the caller's /^[vV]?[0-9]+/
# gate would accept a platform string and treat it as a version.
printf '%s\n' "$out" | grep -F 'BANNER OK  parsed=[1.14.5]' >/dev/null ||
  fail "a banner with no version keyword must still yield 1.14.5, not the platform token: $out"
ok

printf '%s\n' "$out" | grep -F 'parsed=[linux-amd64]' >/dev/null &&
  fail "the platform field was parsed as the version"
ok

# --- callers must share the one predicate ---------------------------------
# Three call sites previously each had their own copy of the positional guess;
# fixing one and leaving two would have left the abort reachable.
stale="$(grep -c 'first_line_last_field(sing_box_version_output)' "$RUNTIME_UC" || true)"
[ "$stale" = "0" ] ||
  fail "singbox/runtime.uc still parses the version positionally ($stale site(s))"
ok

stale="$(grep -c 'first_line_last_field(command_output_from_args(\[ "sing-box", "version" \]))' "$VALIDATOR_UC" || true)"
[ "$stale" = "0" ] ||
  fail "config/validator.uc still parses the version positionally ($stale site(s)): an empty result there is a fatal Aborted."
ok

echo "singbox_version_banner_parse: $pass_count checks passed"