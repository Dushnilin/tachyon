#!/usr/bin/env bash
# BUG (TCH-1046): parse_core_version() must extract the version token rather than
# the trailing build tag or platform token.
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
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"
[ -f "$COMMON_UC" ] || fail "core/common.uc not found at $COMMON_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SANDBOX="$(mktemp -d /tmp/tachyon-corever.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

cat >"$SANDBOX/probe.uc" <<'PROBE'
let common = require("core.common");

function gated(parsed) {
    return match(parsed, /^[vV]?[0-9]+/) ? parsed : "";
}

let banners = [
    "tachyon-core version 0.3.9\n\nTags: with_quic\n",
    "tachyon-core version 0.5.7 (with_quic, with_tailscale)\n",
    "tachyon-core version 0.5.7-tachyon.1\n\nTags: with_quic,with_tailscale\n",
    "tachyon-core 0.5.7 linux-amd64\ntachyon-core version 0.5.7\n\nTags: with_quic\n",
    "tachyon-core 0.5.7 linux-amd64\n",
    "tachyon-core version v0.5.7\n\nTags: with_quic\n",
    "tachyon-core version 0.5.7\nCopyright (C) 2025\nTags: with_quic\n",
    "",
    "command not found\n"
];

let has_parse = type(common.parse_core_version) == "function";

for (let b in banners) {
    let parsed = has_parse ? common.parse_core_version(b) : "MISSING";
    let usable = parsed == "MISSING" ? "" : gated(parsed);
    print("BANNER ", usable != "" ? "OK " : "DEAD", " parsed=[", parsed, "]\n");
}
print("HAS_PARSE ", has_parse ? 1 : 0, "\n");
PROBE

out="$(ucode -L "$TACHYON_LIB" "$SANDBOX/probe.uc" 2>&1)" || fail "parse probe failed: $out"

dead="$(printf '%s\n' "$out" | grep -c 'BANNER DEAD' || true)"
has_parse="$(printf '%s\n' "$out" | grep '^HAS_PARSE ' | cut -d' ' -f2)"

[ "$has_parse" = "1" ] ||
  fail "core/common.uc exports no parse_core_version()"
ok

[ "$dead" = "2" ] ||
  fail "expected exactly the 2 degenerate banners to parse empty, got $dead: $out"
ok

for want in 0.3.9 0.5.7 0.5.7-tachyon.1 v0.5.7; do
  printf '%s\n' "$out" | grep -F "parsed=[$want]" >/dev/null ||
    fail "banner that contains '$want' did not parse to it: $out"
  ok
done

printf '%s\n' "$out" | grep -F 'parsed=[with_tailscale)]' >/dev/null &&
  fail "the build tag was parsed as the version"
ok

printf '%s\n' "$out" | grep -F 'BANNER OK  parsed=[0.5.7]' >/dev/null ||
  fail "a banner with no version keyword must still yield 0.5.7, not the platform token: $out"
ok

printf '%s\n' "$out" | grep -F 'parsed=[linux-amd64]' >/dev/null &&
  fail "the platform field was parsed as the version"
ok

stale="$(grep -c 'first_line_last_field(core_version_output' "$RUNTIME_UC" || true)"
[ "$stale" = "0" ] ||
  fail "tachyon_core/runtime.uc still parses the version positionally ($stale site(s))"
ok

stale="$(grep -c 'first_line_last_field(command_output' "$VALIDATOR_UC" || true)"
[ "$stale" = "0" ] ||
  fail "config/validator.uc still parses the version positionally ($stale site(s))"
ok

echo "tachyon_core_version_banner_parse: $pass_count checks passed"
