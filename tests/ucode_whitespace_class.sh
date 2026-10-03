#!/usr/bin/env bash
# "\s" inside a character class is not whitespace in ucode's regex engine.
#
# It reads as "not backslash, not s". A negated class built that way keeps
# matching the very characters it was meant to stop at, so:
#
#   match("sing-box version 1.15.0-alpha.10\n\nTags: with_quic\n",
#         /sing-box version ([^\s]+)/)[1]
#     == "1.15.0-alpha.10\n\nTag"
#
# and is_valid_url() - whose path class was [^\s;`$&|<>'"\\] - rejected every URL
# whose path contained the letter s, so https://discord.com/api/v9/users/@me came
# back invalid and a custom fuzzer target was refused with no stated reason.
#
# core/common.uc already documents the rule for parse_sing_box_version(). This test
# keeps the rest of the tree honest about it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/diagnostics" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

cat >"$WORK_DIR/wsclass.uc" <<'UCODE'
let common = require("core.common");
let runner = require("diagnostics.fuzzer_runner");

let errors = [];
let note = function(m) { push(errors, m); };

// The shared parser has to survive a banner with blank lines and a Tags line.
let banner = "sing-box version 1.15.0-alpha.10\n\nTags: with_quic,with_tailscale\n";
let got = common.parse_sing_box_version(banner);
if (got != "1.15.0-alpha.10") note("parse_sing_box_version returned [" + got + "]");

// The engine really does behave this way, so the rule is not cargo cult.
let leaky = match("a b", /a[^\s]+/);
if (leaky == null || leaky[0] != "a b")
    note("expected [^\\s]+ to swallow the space; the engine changed and this test needs revisiting");

// A path class built with \s rejects the letter s.
for (let url in [
    "https://example.com/users",
    "https://discord.com/api/v9/users/@me",
    "https://www.youtube.com/",
    "https://rr5.googlevideo.com/videoplayback",
]) {
    if (!runner.is_valid_url(url)) note("is_valid_url rejected " + url);
}

// And it still has to reject what it is there to reject.
for (let url in [
    "ftp://example.com/",
    "https://example.com/a b",
    "https://example.com/a;rm",
    "not-a-url",
]) {
    if (runner.is_valid_url(url)) note("is_valid_url accepted " + url);
}

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("whitespace class ok\n");
UCODE

if out="$(ucode "$WORK_DIR/wsclass.uc" 2>&1)"; then
  printf 'ucode whitespace class: %s\n' "$out"
else
  fail "character classes still use \\s:
$out"
fi

# No source may reintroduce \s inside a class. Comment lines are stripped first:
# the prose explaining the trap quotes the pattern, and a check that matched its own
# explanation could never pass.
offenders=""
while IFS= read -r file; do
  found="$(grep -n '\[\^\\s' "$file" 2>/dev/null | grep -v ':[[:space:]]*//' || true)"
  [ -z "$found" ] || offenders="$offenders$found"$'\n'
done <<EOF
$(find "$TACHYON_LIB" -name '*.uc' -type f)
EOF

if [ -n "$offenders" ]; then
  fail "these use \\s inside a character class, where it means the literal characters \\ and s:
$offenders"
fi
ok

printf 'PASS: ucode_whitespace_class\n'