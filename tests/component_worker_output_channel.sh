#!/usr/bin/env bash
set -eo pipefail

# A component action prints its JSON result to stdout and logs to syslog, but the
# worker used to redirect stderr into the same file with 2>&1. Anything a child
# wrote to stderr after the result - apk warnings, init-script chatter from the
# restart that a Tachyon self-update performs on itself - landed after the JSON.
# The whole-file parse then failed, the line scan found no object, and a
# successful action was reported to the UI as a failure whose message was the
# tail of a log ("Failed to execute").

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
SINGBOX_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Comments mention 2>&1 to explain the bug; only real redirections count.
code_only() {
  sed 's://.*::'
}

worker="$(sed -n '/^function component_action_worker/,/^}/p' "$UPDATES_UC" | code_only)"
[ -n "$worker" ] || fail "components/updates.uc must define component_action_worker"

if grep -Fq '2>&1' <<<"$worker"; then
  fail "component_action_worker must not merge stderr into the result file; stray stderr corrupts the JSON the UI parses"
fi
grep -Fq '".stderr"' <<<"$worker" ||
  fail "component_action_worker must redirect stderr to a separate .stderr file"

# The automatic check runs the same action module and parses the same way.
auto="$(sed -n '/^function run_automatic_component_update_check/,/^}/p' "$UPDATES_UC" | code_only)"
[ -n "$auto" ] || fail "components/updates.uc must define run_automatic_component_update_check"
if grep -Fq '2>&1' <<<"$auto"; then
  fail "run_automatic_component_update_check must not merge stderr into the file it json-parses"
fi

# The stderr file must be cleaned up with the rest of the job, and it is the
# better source for a failure message than the (empty) result file.
finish="$(sed -n '/^function finish_component_job/,/^}/p' "$UPDATES_UC" | code_only)"
[ -n "$finish" ] || fail "components/updates.uc must define finish_component_job"
grep -Fq 'remove_file(output_file + ".stderr")' <<<"$finish" ||
  fail "finish_component_job must remove the worker .stderr file"
grep -Fq 'output_file + ".stderr"' <<<"$finish" ||
  fail "finish_component_job should report the worker stderr as the failure message"

# A worker killed mid-run leaves its .stderr behind; the orphan sweep must take
# it too, or the files pile up in tmpfs.
grep -Fq 'remove_file(output_path + ".stderr")' "$UPDATES_UC" ||
  fail "the component job sweep must remove orphaned .stderr files"
grep -Fq '"*.out.stderr"' "$UPDATES_UC" ||
  fail "the age-based orphan cleanup must cover *.out.stderr"

# --- validation must judge sing-box by its output, not its exit status ---------
#
# `sing-box version` prints the version and can still exit non-zero or be
# signalled by the service stop that precedes the install. command_output()
# discards stdout whenever the raw wait status is non-zero, so validation saw an
# empty string, declared a working binary broken and rolled the install back with
# exit_code 129 (128+SIGHUP).

probe="$(sed -n '/^function read_sing_box_binary_version/,/^}/p' "$ACTION_UC" | code_only)"
[ -n "$probe" ] || fail "components/action.uc must define read_sing_box_binary_version"
grep -Fq 'command_output_lenient(' <<<"$probe" ||
  fail "read_sing_box_binary_version must keep stdout regardless of exit status"
if grep -Eq '[^_]command_output\(' <<<"$probe"; then
  fail "read_sing_box_binary_version must not use the status-gated command_output"
fi

version_output="$(sed -n '/^function sing_box_version_output/,/^}/p' "$SINGBOX_UC" | code_only)"
[ -n "$version_output" ] || fail "singbox/runtime.uc must define sing_box_version_output"
grep -Fq 'command_output_lenient(' <<<"$version_output" ||
  fail "sing_box_version_output must keep stdout regardless of exit status"

# ucode does not hoist: the helper must be declared before every call site.
for file in "$ACTION_UC" "$SINGBOX_UC"; do
  decl="$(grep -n '^function command_output_lenient' "$file" | head -1 | cut -d: -f1)"
  [ -n "$decl" ] || fail "$file must declare command_output_lenient"
  # Every mention that is not the declaration itself is a call site.
  first_use="$(sed 's://.*::' "$file" | grep -n 'command_output_lenient(' |
    grep -v ':function ' | head -1 | cut -d: -f1)"
  [ -n "$first_use" ] || fail "$file declares command_output_lenient but never calls it"
  [ "$decl" -lt "$first_use" ] ||
    fail "$file declares command_output_lenient at line $decl but calls it at $first_use; ucode does not hoist"
done

# --- behavioural: the helper really survives a non-zero exit ------------------

if command -v ucode >/dev/null 2>&1; then
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  cat >"$WORK_DIR/probe.uc" <<'UC'
import * as fs from "fs";

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return "" + data;
}

function command_output_lenient(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data != null ? "" + data : "";
}

let cmd = "printf 'sing-box version 1.13.18-extended-2.6.3\\n'; exit 1";
print("strict=[" + trim(command_output(cmd)) + "]\n");
print("lenient=[" + trim(command_output_lenient(cmd)) + "]\n");
UC

  out="$(ucode -R "$WORK_DIR/probe.uc")"
  grep -Fq 'strict=[]' <<<"$out" ||
    fail "sanity: status-gated command_output was expected to drop the output, got: $out"
  grep -Fq 'lenient=[sing-box version 1.13.18-extended-2.6.3]' <<<"$out" ||
    fail "command_output_lenient must return stdout of a command that exits non-zero, got: $out"
fi

printf 'component worker output channel checks passed\n'
