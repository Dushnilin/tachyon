#!/usr/bin/env bash
# FAULT: Tachyon rewrites flash with byte-identical content, over and over.
#
# On a router the flash is the only component that actually dies. NAND wears out
# long before the CPU does, and almost everything Tachyon regenerates is derived
# data that comes back identical most of the time: the steer spec, the per-channel
# domain lists, the zapret opts files, the compiled .srs rulesets, the
# subscription cache, the sing-box config.
#
# Measured on 192.168.1.1: one list update rewrote all 33 .srs rulesets - 2.5 MB
# - inside four minutes, with identical content, because the copy was
# unconditional. Nothing about that shows up in the UI, and the router just gets a
# little more worn out every time.
#
# The three central writers in core/common.uc - write_file, write_json_file and
# copy_file - are where every regenerator funnels through, so the guard belongs
# there rather than at the ~230 call sites.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

[ -f "$LIB_DIR/core/common.uc" ] || fail "core/common.uc not found"

trap 'rm -rf "$WORK_DIR"' EXIT

# Writes the same content twice and reports whether the second write actually
# touched the file, by comparing the inode's mtime with a sleep in between.
# mtime resolution on a router filesystem is 1s, so the sleep has to clear it.
probe_unchanged_write() {
  ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let path = getenv("PROBE_PATH");
let value = getenv("PROBE_VALUE");
common.write_file(path, value);
system("sleep 1.1");
let before = fs.stat(path).mtime;
common.write_file(path, value);
system("sleep 1.1");
let after = fs.stat(path).mtime;
printf("unchanged_skipped=%s\n", after == before ? "yes" : "no");
' 2>&1
}

probe_changed_write() {
  ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let path = getenv("PROBE_PATH");
common.write_file(path, "first\n");
system("sleep 1.1");
let before = fs.stat(path).mtime;
common.write_file(path, "second and different\n");
let after = fs.stat(path).mtime;
printf("changed_written=%s content=%s\n",
  after != before ? "yes" : "no",
  join("", [ fs.readfile(path) == "second and different\n" ? "ok" : "WRONG" ]));
' 2>&1
}

probe_json_unchanged() {
  ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let path = getenv("PROBE_PATH");
let spec = { outputs: { "direct": { kind: "direct" } }, channels: [ { name: "a" } ] };
common.write_json_file(path, spec);
system("sleep 1.1");
let before = fs.stat(path).mtime;
common.write_json_file(path, spec);
system("sleep 1.1");
let after = fs.stat(path).mtime;
printf("json_unchanged_skipped=%s\n", after == before ? "yes" : "no");
' 2>&1
}

probe_copy_unchanged() {
  ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let src = getenv("PROBE_SRC");
let dst = getenv("PROBE_DST");
common.write_file(src, "compiled ruleset bytes\n");
common.copy_file(src, dst);
system("sleep 1.1");
let before = fs.stat(dst).mtime;
common.copy_file(src, dst);
system("sleep 1.1");
let after = fs.stat(dst).mtime;
printf("copy_unchanged_skipped=%s\n", after == before ? "yes" : "no");
' 2>&1
}

# --- write_file: identical content must not be written again ------------------
out="$(PROBE_PATH="$WORK_DIR/plain.txt" PROBE_VALUE="regenerated content\n" probe_unchanged_write)" ||
  fail "could not drive write_file: $out"
grep -q 'unchanged_skipped=yes' <<< "$out" ||
  fail "write_file rewrote a file with identical content, so every regeneration costs a flash update whether or not anything changed: $out"

# --- write_file: real changes must still land --------------------------------
# A guard that skipped everything would be worse than no guard at all: the
# regenerated spec would never reach disk and the engine would keep running the
# old rules.
out="$(PROBE_PATH="$WORK_DIR/changing.txt" probe_changed_write)" ||
  fail "could not drive the changed-content write: $out"
grep -q 'changed_written=yes' <<< "$out" ||
  fail "write_file skipped a genuine content change, so config changes would never reach the engine: $out"
grep -q 'content=ok' <<< "$out" ||
  fail "write_file did not persist the new content: $out"

# --- write_json_file: same, and it must not leave temp files behind ---------
out="$(PROBE_PATH="$WORK_DIR/spec.json" probe_json_unchanged)" ||
  fail "could not drive write_json_file: $out"
grep -q 'json_unchanged_skipped=yes' <<< "$out" ||
  fail "write_json_file rewrote an identical JSON file, burning a tmp write plus a rename on flash every time the spec is regenerated: $out"

leftover="$(find "$WORK_DIR" -name '*.tmp' | wc -l)"
[ "$leftover" -eq 0 ] || fail "write_json_file left $leftover temp file(s) behind: $(find "$WORK_DIR" -name '*.tmp')"

# --- copy_file: this is the one that rewrote 2.5 MB of rulesets ------------
out="$(PROBE_SRC="$WORK_DIR/ruleset.srs" PROBE_DST="$WORK_DIR/persistent.srs" probe_copy_unchanged)" ||
  fail "could not drive copy_file: $out"
grep -q 'copy_unchanged_skipped=yes' <<< "$out" ||
  fail "copy_file rewrote an identical ruleset, which is how a single list update put 2.5 MB through the flash on a router: $out"

# --- a different size must not be mistaken for unchanged --------------------
# Size is compared before content as a fast path, so a same-size but different
# payload has to be caught by the content compare rather than skipped.
out="$(PROBE_PATH="$WORK_DIR/probe.bin" ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let path = getenv("PROBE_PATH");
// A null path makes every assertion below vacuously true, which is how a test
// ends up passing without testing anything. Fail loudly instead.
if (path == null || path == "") {
  print("PROBE_PATH is not set - refusing to run a vacuous check");
  exit(1);
}
common.write_file(path, "AAAA\n");
let same_size = common.content_unchanged(path, "BBBB\n");
let different_size = common.content_unchanged(path, "CCCCC\n");
let identical = common.content_unchanged(path, "AAAA\n");
let missing = common.content_unchanged("/nonexistent/nope", "x\n");
printf("same_size_changed=%s different_size_changed=%s identical=%s missing=%s\n",
  same_size ? "no" : "yes",
  different_size ? "no" : "yes",
  identical ? "yes" : "no",
  missing ? "no" : "yes");
' 2>&1)" || fail "could not drive content_unchanged: $out"

grep -q 'same_size_changed=yes' <<< "$out" ||
  fail "a same-size but different payload was treated as unchanged, so real config changes would be silently dropped: $out"
grep -q 'different_size_changed=yes' <<< "$out" ||
  fail "a different-size payload was treated as unchanged: $out"
grep -q 'identical=yes' <<< "$out" ||
  fail "identical content was not recognised, so the guard never fires: $out"
grep -q 'missing=yes' <<< "$out" ||
  fail "a missing file was treated as unchanged, so the first write of every file would be skipped: $out"

# --- /etc/steer must not survive a switch away from steer ---------------------
# Measured on 192.168.1.1, which runs sing-box: /etc/steer still held ten files
# including a full spec.json and every channel list, untouched since the day the
# engine was switched away from steer. Only the switching code knows the engine
# just changed, so that is where the cleanup has to live.
# The spec path is passed in, so this runs in a scratch directory and needs no
# root. An earlier version wrote to /etc/steer: it passed locally because the
# local docker image runs as root, and went red in CI on
# "mkdir: cannot create directory /etc/steer" - the runner is not root.
STEER_DIR="$WORK_DIR/steer"
printf '%s\n' '--- steer artifacts are discarded when the engine leaves steer ---'
rm -rf "$STEER_DIR"
mkdir -p "$STEER_DIR/lists/channels/Main" "$STEER_DIR/zapret" "$STEER_DIR/subs"
printf '{ "outputs": {} }\n' > "$STEER_DIR/spec.json"
printf 'example.com\n' > "$STEER_DIR/lists/channels/Main/domains.lst"
printf '%s\n' '--filter-tcp' > "$STEER_DIR/zapret/Youtube.opts"
printf 'vless://a@b\n' > "$STEER_DIR/subs/Main.txt"
printf 'package-owned\n' > "$STEER_DIR/keep.d"

out="$(STEER_SPEC="$STEER_DIR/spec.json" STEER_DIR="$STEER_DIR" ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let state = require("components.engine_state");
let dir = getenv("STEER_DIR");
state.discard_steer_artifacts("sing-box", getenv("STEER_SPEC"));
function mark(p) { return fs.stat(p) == null ? "GONE" : "PRESENT"; }
printf("spec=%s lists=%s zapret=%s subs=%s keep=%s\n",
  mark(dir + "/spec.json"), mark(dir + "/lists"), mark(dir + "/zapret"),
  mark(dir + "/subs"), mark(dir + "/keep.d"));
' 2>&1)" || fail "could not drive discard_steer_artifacts: $out"

grep -q 'spec=GONE' <<< "$out" || fail "spec.json survived the switch away from steer: $out"
grep -q 'lists=GONE' <<< "$out" || fail "the channel list files survived the switch away from steer: $out"
grep -q 'zapret=GONE' <<< "$out" || fail "the zapret opts files survived the switch away from steer: $out"
# The steer package owns the rest of the directory. Uninstalling its files is
# not this function's business, so keep.d has to come out untouched.
grep -q 'keep=PRESENT' <<< "$out" ||
  fail "discard_steer_artifacts deleted a file the steer package owns: $out"

# The safety floor: a caller that passes a filesystem root or a single
# top-level system directory must be refused, not obeyed. Exercised against
# /tmp because that is the one top-level directory a test may safely point a
# real delete at: if the guard were broken it would only ever have removed
# /tmp/lists, /tmp/zapret and /tmp/spec.json, never /tmp itself.
printf 'precious\n' > /tmp/spec.json
out="$(ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let state = require("components.engine_state");
state.discard_steer_artifacts("sing-box", "/");
state.discard_steer_artifacts("sing-box", "/tmp/spec.json");
state.discard_steer_artifacts("sing-box", "relative/spec.json");
printf("toplevel=%s relative_untouched=%s\n",
  fs.stat("/tmp/spec.json") == null ? "GONE" : "PRESENT",
  fs.stat("/tmp/spec.json") == null ? "GONE" : "PRESENT");
' 2>&1)" || fail "could not drive the safety-floor case: $out"
grep -q 'toplevel=PRESENT' <<< "$out" ||
  fail "a caller passed a single top-level directory and discard_steer_artifacts deleted it: $out"
rm -f /tmp/spec.json /tmp/lists /tmp/zapret

# Switching *to* steer must keep the artifacts, or the engine would start with
# nothing to read and fall back to direct.
rm -rf "$STEER_DIR"
mkdir -p "$STEER_DIR"
printf '{ "outputs": {} }\n' > "$STEER_DIR/spec.json"
out="$(STEER_SPEC="$STEER_DIR/spec.json" ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let state = require("components.engine_state");
let spec = getenv("STEER_SPEC");
state.discard_steer_artifacts("steer", spec);
state.discard_steer_artifacts("steer-extended", spec);
printf("spec=%s\n", fs.stat(spec) == null ? "GONE" : "PRESENT");
' 2>&1)" || fail "could not drive the steer-target case: $out"
grep -q 'spec=PRESENT' <<< "$out" ||
  fail "switching to steer deleted its own spec.json, so the engine would start with no config at all: $out"
rm -rf /etc/steer


# ---------------------------------------------------------------------------
# The steer spec write path, end to end.
#
# write_file() skips a write when the content is identical, but generate_steer_spec
# pointed it at a fresh temp name (`spec.json.tachyon.<clock>`) which never exists
# beforehand. The guard therefore always saw a difference and always wrote, and the
# rename then put a byte-identical copy of the spec onto the flash overlay on every
# apply - including a no-op restart.
#
# generate_steer_spec now lives in service/engine_runtime_lib.uc, which is
# requireable and never exits, so the real path is driven instead of asserted.
# ---------------------------------------------------------------------------
# A stub steer that reports 2.0, so the version gate - which correctly refuses to
# write a spec an older kernel would reject - does not block the write path.
STUB_DIR="$WORK_DIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/steer" <<'SH'
#!/bin/sh
case "$1" in
  version) echo "steer 2.0.1" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/steer"
export TACHYON_STEER_BINARY="$STUB_DIR/steer"

PROBE_DIR="$WORK_DIR/flash-spec"
mkdir -p "$PROBE_DIR"

cat >"$WORK_DIR/flashprobe.uc" <<'UCODE'
let rt = require("service.engine_runtime_lib");
let path = getenv("TACHYON_STEER_SPEC_FILE");
let fs = require("fs");

let first = rt.generate_steer_spec({});
let second = rt.generate_steer_spec({});

printf("first=%s\n", first.ok ? "ok" : "fail");
printf("second_reason=%s\n", second.reason);
printf("content_ok=%s\n", fs.readfile(path) != null ? "yes" : "no");
UCODE

out="$(TACHYON_STEER_SPEC_FILE="$PROBE_DIR/spec.json" ucode -L "$LIB_DIR" "$WORK_DIR/flashprobe.uc" 2>&1)" \
  || fail "could not drive the spec write path: $out"

grep -q '^first=ok$' <<< "$out" \
  || fail "the first generate did not succeed, so the flash check proves nothing: $out"
# The whole point: identical content must not be rewritten. `reason` is the direct
# signal for that decision, and the changed-content case below is the control that
# keeps it from being a guard that simply always skips.
#
# A permissions-based proof would be stronger but is not available here: chmod is
# ignored when the suite runs as root, and this repository has already been burned
# by a flash test that proved nothing for exactly that reason.
grep -q '^second_reason=unchanged$' <<< "$out" \
  || fail "an identical spec was rewritten to flash instead of being skipped: $out"
grep -q '^content_ok=yes$' <<< "$out" \
  || fail "skipping the rewrite must still leave a readable spec on disk: $out"

# Control: a genuinely different spec must still be written, or the guard would
# freeze the config on disk.
cat >"$WORK_DIR/flashchange.uc" <<'UCODE'
let rt = require("service.engine_runtime_lib");
let path = getenv("TACHYON_STEER_SPEC_FILE");
let fs = require("fs");
rt.generate_steer_spec({});
fs.writefile(path, "{\"version\":2,\"lan\":{\"devices\":[\"edited\"]}}\n");
let again = rt.generate_steer_spec({});
printf("ok=%s\n", again.ok ? "yes" : "no");
printf("reason=%s\n", again.reason == null ? "null" : again.reason);
printf("restored=%s\n", index(fs.readfile(path) || "", "br-lan") >= 0 ? "yes" : "no");
UCODE

out="$(TACHYON_STEER_SPEC_FILE="$PROBE_DIR/spec.json" ucode -L "$LIB_DIR" "$WORK_DIR/flashchange.uc" 2>&1)" \
  || fail "could not drive the changed-content case: $out"
grep -q '^ok=yes$' <<< "$out" \
  || fail "a genuinely different spec was not written: the guard would freeze the config: $out"
grep -q '^reason=$' <<< "$out" \
  || fail "a changed spec took the unchanged path, so the config would freeze on disk: $out"
grep -q '^restored=yes$' <<< "$out" \
  || fail "the spec on disk still holds the edited content after a real change: $out"

# The library must be requireable without running a CLI or exiting, while the CLI
# shim must still work as a program. These used to be one file, which is exactly
# why it could not do both.
ucode -L "$LIB_DIR" "$LIB_DIR/service/engine_runtime.uc" engine-info >/dev/null 2>&1 \
  || fail "the engine_runtime CLI shim no longer answers engine-info"
out="$(ucode -L "$LIB_DIR" -e 'let rt = require("service.engine_runtime_lib"); print("lib=" + (type(rt.generate_steer_spec) == "function" ? "yes" : "no") + "\n");' with-an-argument 2>&1)" \
  || fail "requiring the library with an argument must not run a CLI or exit: $out"
grep -q '^lib=yes$' <<< "$out" || fail "the library exports nothing usable: $out"

# Production code requires the library; pointing it back at the CLI shim would run
# main() with the caller's arguments and exit the interpreter underneath them.
for caller in "$LIB_DIR/components/action.uc" "$LIB_DIR/diagnostics/system_info.uc"; do
  grep -q 'require("service.engine_runtime_lib")' "$caller" \
    || fail "$caller must require the library, not the CLI shim"
  if grep -q 'require("service.engine_runtime")' "$caller"; then
    fail "$caller still requires the CLI shim, which runs main() and exits on import"
  fi
done

# The spec path has to be redirectable for any of this to be testable without
# root, and the default must stay the real one.
grep -q 'TACHYON_STEER_SPEC_FILE' "$LIB_DIR/core/engine.uc" \
  || fail "the steer spec path is not overridable, so its write path cannot be tested without root"

printf 'fault: flash wear guard passed\n'
