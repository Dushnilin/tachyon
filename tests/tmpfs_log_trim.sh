#!/bin/sh
# tmpfs logs are RAM: the watchdog must cut an oversized log back to its tail,
# keep the inode (a daemon holds it open with O_APPEND) and leave small logs
# alone. Extracts the installed function; touches only a private temp dir.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=${TACHYON_LIB:-$root/tachyon/files/usr/lib}
source=$lib/service/watchdog.uc
work=$(mktemp -d /tmp/tachyon-log-trim-test.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

grep -q '^function trim_tmpfs_log(' "$source" || { echo "FAIL: trim_tmpfs_log missing"; exit 1; }

{
    echo 'let fs = require("fs");'
    grep -E '^const TMPFS_LOG_(MAX|KEEP)_BYTES' "$source"
    awk '/^function trim_tmpfs_log\(/ {a=1} a {print} a && /^}/ {exit}' "$source"
    cat <<'UCODE'
let dir = ARGV[0];

// Oversized: 800 numbered lines of ~1KB each.
let big = dir + "/big.log";
let pad = "";
for (let k = 0; k < 100; k++)
    pad += "xxxxxxxxxx";
let body = "";
for (let i = 0; i < 800; i++)
    body += sprintf("%05d %s\n", i, pad);
fs.writefile(big, body);
let ino_before = fs.stat(big).ino;
assert(fs.stat(big).size > TMPFS_LOG_MAX_BYTES, "fixture not oversized");
assert(trim_tmpfs_log(big) == true, "oversized log not trimmed");
let after = fs.stat(big);
assert(after.size <= TMPFS_LOG_KEEP_BYTES, "log still " + after.size + " bytes");
assert(after.ino == ino_before, "inode changed - an O_APPEND writer would be orphaned");
let content = fs.readfile(big);
assert(match(content, /^[0-9]{5} x/) != null, "first kept line is a fragment");
assert(index(content, "00799 ") >= 0, "newest line was lost");

// Small log untouched.
let small = dir + "/small.log";
fs.writefile(small, "one\ntwo\n");
assert(trim_tmpfs_log(small) == false, "small log was rewritten");
assert(fs.readfile(small) == "one\ntwo\n", "small log content changed");

// Missing file is not an error.
assert(trim_tmpfs_log(dir + "/absent.log") == false, "absent file");
print("PASS: tmpfs log trim\n");
UCODE
} > "$work/test.uc"

ucode -L "$lib" "$work/test.uc" "$work"
