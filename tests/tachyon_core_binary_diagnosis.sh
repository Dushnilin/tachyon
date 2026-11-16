#!/usr/bin/env bash
# "Generated tachyon-core configuration is invalid" is not always about the configuration.
#
# Reported from the field as:
#
#   [fatal] Generated configuration is invalid: /usr/bin/tachyon-core: line 3:
#           syntax error: unexpected word (expecting ")"). Aborted.
#
# So the file is classified before the configuration is blamed, and a broken binary
# says so in as many words.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/tachyon_core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"
[ -f "$RUNTIME_UC" ] || fail "missing $RUNTIME_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

cat >"$WORK_DIR/binprobe.uc" <<'UCODE'
let r = require("tachyon_core.binary_diag");

let errors = [];
let note = function(m) { push(errors, m); };

// The reported case: a shell script standing where the binary should be.
let script = ARGV[0] + "/tc-script";
let empty = ARGV[0] + "/tc-empty";
let binary = ARGV[0] + "/tc-real";
let missing = ARGV[0] + "/tc-absent";

let problem = r.core_binary_problem(script);
if (problem == "") note("a shell script in place of the binary must be reported, got an empty problem");
else if (index(problem, "shell script") < 0) note("the report must say it is a shell script, got: " + problem);

// An empty file is its own failure and must not be read as "fine".
if (r.core_binary_problem(empty) == "") note("an empty binary must be reported");

// A missing one too, by path.
if (r.core_binary_problem(missing) == "") note("a missing binary must be reported");

// A real binary must not be reported as a problem, or every start would claim the
// engine is broken.
if (r.core_binary_problem(binary) != "") note("a real binary must report no problem, got: " + r.core_binary_problem(binary));

// The reported case: a macOS build standing where the Linux binary should be.
let macho = ARGV[0] + "/tc-macho";
let problem_macho = r.core_binary_problem(macho);
if (problem_macho == "") note("a macOS (Mach-O) binary must be reported, got an empty problem");
else if (index(problem_macho, "macOS") < 0 || index(problem_macho, "Mach-O") < 0)
    note("the report must name the wrong platform, got: " + problem_macho);

// The path arrives from `command -v` with its trailing newline.
if (r.core_binary_problem(binary + "\n") != "")
    note("a path with a trailing newline must still find the binary, got: " +
        r.core_binary_problem(binary + "\n"));

// Telling the two failures apart, from the check output alone.
let blames = function(reason, should_be_binary, label) {
    let got = r.core_check_blamed_the_binary(reason);
    if (got !== should_be_binary)
        note(label + ": got " + (got ? "blamed the binary" : "blamed the config"));
};

blames("/usr/bin/tachyon-core: line 3: syntax error: unexpected word (expecting \")\").", true,
    "a shell error from the binary must be recognised");
blames("Permission denied", true,
    "an unusable binary must be recognised from a permission error");
blames("sh: /usr/bin/tachyon-core: Exec format error", true,
    "a binary the kernel cannot exec must be recognised");
blames('outbounds[3].default: json: unknown field "default"', false,
    "a real configuration error must not be blamed on the binary");
blames("31mFATAL decode config: unknown transport", false,
    "a core diagnostic must not be blamed on the binary");
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

printf '#!/bin/sh\nexec /usr/bin/false\n' >"$WORK_DIR/tc-script"
: >"$WORK_DIR/tc-empty"
printf '\177ELF\002\001\001\000placeholder binary bytes' >"$WORK_DIR/tc-real"
printf '\317\372\355\376\000\000\000\002placeholder mach-o bytes' >"$WORK_DIR/tc-macho"

if out="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/binprobe.uc" "$WORK_DIR" 2>&1)"; then
  printf 'tachyon-core binary diagnosis: %s\n' "$out"
  ok
else
  fail "a broken binary is still reported as a bad configuration:
$out"
fi

# The failure path has to consult the diagnosis before blaming the configuration.
handler="$(sed -n '/Say which of the two it was before blaming the configuration\./,/Aborted\./p' "$RUNTIME_UC")"
[ -n "$handler" ] || fail "could not find the check failure path"

grep -q 'core_binary_problem' <<<"$handler" ||
  fail "the check failure path does not classify the binary"
ok

grep -q 'core_check_blamed_the_binary' <<<"$handler" ||
  fail "the check failure path does not use the output to tell the two failures apart"
ok

# The diagnosis must come first: blaming the configuration before classifying
# the binary is the original bug this test exists for.
classify_line="$(grep -n 'let bin_problem = core_binary_problem' "$RUNTIME_UC" | head -1 | cut -d: -f1)"
blame_line="$(grep -n 'Generated tachyon-core configuration is invalid' "$RUNTIME_UC" | head -1 | cut -d: -f1)"
[ -n "$classify_line" ] && [ -n "$blame_line" ] || fail "could not locate classification or blame"
if [ "$classify_line" -ge "$blame_line" ]; then
  fail "the binary is classified (line $classify_line) only after the configuration is blamed (line $blame_line)"
fi
ok

# Both messages have to survive: a genuine configuration error must still be reported as one.
grep -q 'Generated tachyon-core configuration is invalid' "$RUNTIME_UC" ||
  fail "the genuine configuration error message was replaced instead of supplemented"
ok

# command -v output carries a newline; stat'ing it raw is what reported a present
# binary as missing. The path must be trimmed at the source too.
grep -q 'trim(command_output_lenient' "$RUNTIME_UC" ||
  fail "core_binary_path() must trim the newline off \`command -v\` output"
ok

printf 'tachyon-core binary diagnosis: %d checks passed\n' "$pass_count"
printf 'PASS: tachyon_core_binary_diagnosis\n'
