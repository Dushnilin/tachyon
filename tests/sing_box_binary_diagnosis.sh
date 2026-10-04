#!/usr/bin/env bash
# "Generated sing-box configuration is invalid" is not always about the configuration.
#
# Reported from the field as:
#
#   [fatal] Generated sing-box configuration is invalid: /usr/bin/sing-box: line 3:
#           syntax error: unexpected word (expecting ")"). Aborted.
#
# That is the shell reporting on /usr/bin/sing-box: the file is a script, not the
# engine - a wrapper, a half-extracted stub, a failed upgrade. Nothing was wrong with
# the configuration, and the message sent the user looking there instead.
#
# So the file is classified before the configuration is blamed, and a broken binary
# says so in as many words.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/singbox" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

RUNTIME_UC="$TACHYON_LIB/singbox/runtime.uc"
[ -f "$RUNTIME_UC" ] || fail "missing $RUNTIME_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

cat >"$WORK_DIR/binprobe.uc" <<'UCODE'
let r = require("singbox.binary_diag");

let errors = [];
let note = function(m) { push(errors, m); };

// The reported case: a shell script standing where the binary should be.
let script = ARGV[0] + "/sb-script";
let empty = ARGV[0] + "/sb-empty";
let binary = ARGV[0] + "/sb-real";
let missing = ARGV[0] + "/sb-absent";

let problem = r.sing_box_binary_problem(script);
if (problem == "") note("a shell script in place of the binary must be reported, got an empty problem");
else if (index(problem, "shell script") < 0) note("the report must say it is a shell script, got: " + problem);

// An empty file is its own failure and must not be read as "fine".
if (r.sing_box_binary_problem(empty) == "") note("an empty binary must be reported");

// A missing one too, by path.
if (r.sing_box_binary_problem(missing) == "") note("a missing binary must be reported");

// A real binary must not be reported as a problem, or every start would claim the
// engine is broken.
if (r.sing_box_binary_problem(binary) != "") note("a real binary must report no problem, got: " + r.sing_box_binary_problem(binary));

// Telling the two failures apart, from the check output alone.
let blames = function(reason, should_be_binary, label) {
    let got = r.sing_box_check_blamed_the_binary(reason);
    if (got !== should_be_binary)
        note(label + ": got " + (got ? "blamed the binary" : "blamed the config"));
};

blames("/usr/bin/sing-box: line 3: syntax error: unexpected word (expecting \")\").", true,
    "a shell error from the binary must be recognised");
blames("Permission denied", true,
    "an unusable binary must be recognised from a permission error");
blames("sh: /usr/bin/sing-box: Exec format error", true,
    "a binary the kernel cannot exec must be recognised");
blames('outbounds[3].default: json: unknown field "default"', false,
    "a real configuration error must not be blamed on the binary");
blames("31mFATAL decode config: unknown transport", false,
    "a sing-box diagnostic must not be blamed on the binary");
blames("", false,
    "an empty reason must not be blamed on anything");
blames("exit status 1", false,
    "a bare exit status carries no evidence and must not be blamed on the binary");

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("binary diagnosis ok\n");
UCODE

printf '#!/bin/sh\nexec /usr/bin/false\n' >"$WORK_DIR/sb-script"
: >"$WORK_DIR/sb-empty"
printf '\177ELF\002\001\001\000placeholder binary bytes' >"$WORK_DIR/sb-real"

if out="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/binprobe.uc" "$WORK_DIR" 2>&1)"; then
  printf 'sing-box binary diagnosis: %s\n' "$out"
  ok
else
  fail "a broken binary is still reported as a bad configuration:
$out"
fi

# The fatal path has to consult the diagnosis before blaming the configuration.
body="$(sed -n '/^    if (check_result.status != 0) {/,/^    }/p' "$RUNTIME_UC")"
[ -n "$body" ] || fail "could not find the check failure path"

grep -q 'sing_box_binary_problem' <<<"$body" ||
  fail "the check failure path does not classify the binary"
ok

grep -q 'sing_box_check_blamed_the_binary' <<<"$body" ||
  fail "the check failure path does not use the output to tell the two failures apart"
ok

# Both messages have to survive: a genuine configuration error must still be reported
# as one.
grep -q 'Generated sing-box configuration is invalid' "$RUNTIME_UC" ||
  fail "the genuine configuration error message was replaced instead of supplemented"
ok

printf 'sing-box binary diagnosis: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_binary_diagnosis\n'