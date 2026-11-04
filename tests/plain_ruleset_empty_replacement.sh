#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/core" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK_DIR/bin/core"
export TACHYON_SING_BOX_BIN="$WORK_DIR/bin/core"
export TACHYON_SRS_VERIFY_DIR="$WORK_DIR/verified"
export CASE_DIR="$WORK_DIR"
: >"$WORK_DIR/empty.lst"
printf 'SRS\001previously-populated-list' >"$WORK_DIR/list.srs"
cp "$WORK_DIR/list.srs" "$WORK_DIR/previous.srs"
cat >"$WORK_DIR/run.uc" <<'UCODE'
let fs = require("fs");
let dir = getenv("CASE_DIR");
let result = require("routing.rulesets").compile_plain_list(
    dir + "/empty.lst", dir + "/list.srs", dir + "/list.json");
let expected = getenv("EXPECT_SOURCE") == "1" ? "source" : "binary";
if (result.format != expected || fs.stat(result.path) == null || result.has_domains || result.has_ips)
    die("empty compile returned an unavailable or nonempty ruleset\n");
if (expected == "binary" && fs.readfile(dir + "/list.srs") == fs.readfile(dir + "/previous.srs"))
    die("clearing a plain list kept the previous binary\n");
if (expected == "source" && fs.readfile(dir + "/list.srs") != fs.readfile(dir + "/previous.srs"))
    die("failed publication changed the previous binary\n");
UCODE
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/run.uc"
cmp "$WORK_DIR/previous.srs" "$WORK_DIR/list.srs.bak" || fail 'previous binary was not backed up'
[ ! -e "$WORK_DIR/list.json" ] || fail 'successful publication kept intermediate JSON'

# A failed rename must leave the old file intact and return the empty JSON.
cp "$WORK_DIR/previous.srs" "$WORK_DIR/list.srs"
cat >"$WORK_DIR/bin/mv" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$WORK_DIR/bin/mv"
PATH="$WORK_DIR/bin:$PATH" EXPECT_SOURCE=1 ucode -S -L "$TACHYON_LIB" "$WORK_DIR/run.uc"
if find "$WORK_DIR" -name 'list.srs.empty.*' | grep -q .; then fail 'failed publication leaked staging files'; fi
printf 'empty plain ruleset replacement passed\n'
