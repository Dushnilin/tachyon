#!/usr/bin/env bash
# FAULT: the core installer OOM-kills itself backing up the old sing-box.
#
# Issue #124: install_tachyon_core on a 256 MB router (SNR-CPE-AX2) died with
# rc=247 twice, kernel log naming ucode as the OOM victim at 70-77 MB RSS, with
# ~95 MB available. The only step that holds a multi-tens-of-megabytes binary
# in the interpreter heap is copy_file(): fs.readfile() the whole file, compare,
# write it all back. Everything around it - curl, tar, chmod, the staged
# install - already runs as an external process and streams.
#
# The fix is copy_file_stream(): cp -p through the kernel, no heap. This test
# pins both halves - the installer must call the streaming helper, and the
# streaming helper must survive a memory ceiling that copy_file() cannot.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
ACTION_UC="$LIB_DIR/components/action.uc"
COMMON_UC="$LIB_DIR/core/common.uc"

[ -f "$ACTION_UC" ] || fail "components/action.uc not found"
[ -f "$COMMON_UC" ] || fail "core/common.uc not found"

trap 'rm -rf "$WORK_DIR"' EXIT

# --- contract: the installer must not read the binary into the heap ----------
# The rollback backup of /usr/bin/sing-box is the one copy in the install path
# whose payload is the binary itself. It has to go through the streaming helper;
# a plain copy_file() there is the OOM, whatever the rest of the function does.
grep -q 'copy_file_stream("/usr/bin/sing-box"' "$ACTION_UC" ||
  fail "install_tachyon_core no longer backs up the old core through copy_file_stream, so a big binary returns to the ucode heap"

if grep -n 'copy_file("/usr/bin/sing-box"' "$ACTION_UC" >/dev/null; then
  fail "install_tachyon_core still copies /usr/bin/sing-box with copy_file(), which reads the whole binary into memory (issue #124)"
fi

# The helper must exist and be reachable the way the installer uses it.
grep -q 'copy_file_stream' "$COMMON_UC" ||
  fail "core/common.uc does not define copy_file_stream"
grep -q 'copy_file_stream,' "$COMMON_UC" ||
  fail "copy_file_stream is not exported from core/common.uc"

# The comparison that copy_file() performs is exactly what cannot be afforded
# here: if the streaming helper grows an fs.readfile of its own, the fix is gone.
stream_body="$(sed -n '/^function copy_file_stream/,/^}/p' "$COMMON_UC")"
[ -n "$stream_body" ] || fail "could not extract copy_file_stream from core/common.uc"
if grep -q 'fs.readfile' <<<"$stream_body"; then
  fail "copy_file_stream reads the file into the heap with fs.readfile, which is the OOM it exists to avoid"
fi

# --- behaviour: the helper copies, and refuses a missing source --------------
out="$(SRC="$WORK_DIR/src.bin" DST="$WORK_DIR/deep/dir/dst.bin" ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let src = getenv("SRC");
let dst = getenv("DST");
// A null path would make every assertion below vacuously true.
if (src == null || dst == null || src == "" || dst == "") {
  print("SRC/DST not set - refusing a vacuous check");
  exit(1);
}
fs.writefile(src, "binary payload\n");
let copied = common.copy_file_stream(src, dst);
let missing = common.copy_file_stream(src + ".absent", dst + ".absent");
printf("copied=%s content=%s missing=%s\n",
  copied ? "yes" : "no",
  fs.readfile(dst) == "binary payload\n" ? "ok" : "WRONG",
  missing ? "yes" : "no");
' 2>&1)" || fail "could not drive copy_file_stream: $out"

grep -q 'copied=yes' <<<"$out" ||
  fail "copy_file_stream did not copy an existing file: $out"
grep -q 'content=ok' <<<"$out" ||
  fail "copy_file_stream did not produce the source content at the target: $out"
grep -q 'missing=no' <<<"$out" ||
  fail "copy_file_stream reported success for a missing source, so a failed backup would be believed: $out"

# --- behaviour: a memory ceiling that copy_file() cannot clear ---------------
# The OOM is reproduced small: a data ceiling just above the interpreter's own
# footprint. Reading a file several times larger than the headroom cannot fit;
# cp never brings it into this process at all. The copy_file() control proves
# the ceiling actually bites - without it a too-generous limit would make this
# test agree with both implementations, which is how a test passes without
# testing anything.
#
# The baseline is measured, not guessed: ucode's virtual footprint differs
# between the musl build in the test image and any local build.
vm_size_kb() {
  local probe="$WORK_DIR/vmprobe.uc"
  cat >"$probe" <<'UCODE'
let fs = require("fs");
let raw = fs.readfile("/proc/self/status");
// A null read would make every branch below vacuously silent.
if (raw == null) {
  print("0\n");
  exit(0);
}
for (let line in split(raw, "\n")) {
  if (substr(line, 0, 7) == "VmSize:") {
    let parts = split(line, /[ \t]+/);
    print(parts[1], "\n");
    exit(0);
  }
}
print("0\n");
UCODE
  ucode -L "$LIB_DIR" "$probe" 2>/dev/null
}

baseline="$(vm_size_kb)" || fail "could not measure the ucode baseline footprint"
case "$baseline" in
  ''|*[!0-9]*) fail "baseline VmSize is not a number: '$baseline'" ;;
esac
[ "$baseline" -gt 0 ] || fail "baseline VmSize measured as 0, so the ceiling below would be meaningless"

# 48 MiB of payload against 32 MiB of headroom above the baseline: copy_file()
# needs the payload as one ucode string and cannot fit; copy_file_stream() never
# allocates it here.
headroom_kb=32768
limit_kb=$((baseline + headroom_kb))
payload_bytes=$((48 * 1024 * 1024))

# busybox dd has no status=none; the progress line goes to stderr either way.
dd if=/dev/zero of="$WORK_DIR/big.src" bs=1M count=48 2>/dev/null ||
  fail "could not create the payload file"

run_under_ceiling() {
  local fn="$1" dst="$2"
  local script="$WORK_DIR/ceiling.uc"
  cat >"$script" <<UCODE
let common = require("core.common");
let ok = common.$fn(getenv("CEIL_SRC"), getenv("CEIL_DST"));
printf("ok=%s\n", ok ? "yes" : "no");
UCODE
  # The subshell carries the ceiling; ulimit is a shell builtin, not a binary.
  (
    ulimit -v "$limit_kb"
    CEIL_SRC="$WORK_DIR/big.src" CEIL_DST="$dst" \
      ucode -L "$LIB_DIR" "$script" 2>&1
  ) || printf 'ok=crashed\n'
}

stream_out="$(run_under_ceiling copy_file_stream "$WORK_DIR/big.stream.dst")"
grep -q '^ok=yes$' <<<"$stream_out" ||
  fail "copy_file_stream could not copy ${payload_bytes} bytes under a ${limit_kb} kB ceiling, so the streaming path is broken: $stream_out"
cmp -s "$WORK_DIR/big.src" "$WORK_DIR/big.stream.dst" ||
  fail "copy_file_stream produced a different file under the ceiling"

# Control: the pre-fix helper must fail under the same ceiling. If it does not,
# the ceiling does not bind and the assertion above proves nothing.
heap_out="$(run_under_ceiling copy_file "$WORK_DIR/big.heap.dst")"
if grep -q '^ok=yes$' <<<"$heap_out" && cmp -s "$WORK_DIR/big.src" "$WORK_DIR/big.heap.dst"; then
  fail "copy_file() copied ${payload_bytes} bytes under a ${limit_kb} kB ceiling, so the ceiling does not bind and this test proves nothing"
fi

printf 'fault: binary backup streams without OOM passed\n'
