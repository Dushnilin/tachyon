#!/usr/bin/env bash
# FAULT: no room to install.
#
# A router that runs out of /tmp or out of flash mid-transaction cannot install,
# cannot roll back, and often cannot even log. The failure arrives late by
# nature: the download has already happened by the time the budget is checked.
# The contract is that the check refuses BEFORE any mutation, and that the
# refusal says how many kilobytes are missing and on which filesystem, because
# "disk full" with no number gives the user nothing to act on.
#
# preflight takes mock_df overrides shaped like parse_df_output()'s result, so
# the scenarios run without filling a real filesystem. Written as a single
# script file rather than inline -e: nested quoting silently ate the string
# values in the mock objects and produced a ucode syntax error.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

cat > "$WORK_DIR/scenarios.uc" <<'UCODE'
let preflight = require("core.preflight");
let common = require("core.common");
let as_string = common.as_string;

let SPEC = {
    download: 60000, temp: 12000, old: 90000, new: 95000,
    metadata: 512, reserve: 4096, unit: "kb"
};

function df(total, used, avail) {
    return { filesystem: "mock", total_kb: total, used_kb: used, available_kb: avail, use_pct: "0%" };
}

// ucode print() does not append a newline, so use printf through a helper.
function say(v) { printf("%s\n", v); }

function report(tag, r) {
    say(tag + "_ok=" + (r.ok ? "yes" : "no"));
    say(tag + "_tmp_avail=" + r.tmp.available_kb);
    say(tag + "_tmp_deficit=" + r.tmp.deficit_kb);
    say(tag + "_flash_deficit=" + r.flash.deficit_kb);
    say(tag + "_message=" + r.message);
}

// Room to spare.
report("roomy", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(500000, 100000, 400000),
    mock_flash_df: df(2100000, 100000, 2000000)
}));

// /tmp full, flash fine.
report("tmpfull", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(500000, 498000, 2000),
    mock_flash_df: df(2100000, 100000, 2000000)
}));

// Flash full, /tmp fine.
report("flashfull", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(500000, 100000, 400000),
    mock_flash_df: df(2100000, 2099000, 1000)
}));

// Both full: the message has to carry both, not just whichever came first.
report("bothfull", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(500, 0, 500),
    mock_flash_df: df(500, 0, 500)
}));

// A zero reading must not read as "plenty of room" - a naive comparison would
// accept it.
report("zerofree", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(0, 0, 0),
    mock_flash_df: df(0, 0, 0)
}));

// A negative reading is what a corrupt df parse would look like.
report("negative", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(0, 5000, -5000),
    mock_flash_df: df(2100000, 100000, 2000000)
}));

// Exactly at the requirement: the boundary has to pass, one kilobyte less must
// not. Off-by-one here means either a wedged install or a needless refusal.
let exact = preflight.calculate_disk_budget(SPEC);
say("budget_tmp_peak=" + exact.tmp_peak_kb);
say("budget_flash_peak=" + exact.flash_peak_kb);
report("atexact", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(exact.tmp_peak_kb, 0, exact.tmp_peak_kb),
    mock_flash_df: df(exact.flash_peak_kb, 0, exact.flash_peak_kb)
}));
report("onebelow", preflight.validate_disk_budget(SPEC, {
    mock_tmp_df: df(exact.tmp_peak_kb, 1, exact.tmp_peak_kb - 1),
    mock_flash_df: df(exact.flash_peak_kb, 0, exact.flash_peak_kb)
}));

// The numbers in the message have to be the ones from the budget, not the
// stored defaults - a message that names a different requirement than the one
// enforced sends the user chasing the wrong number.
print("tmp_peak_kb=" + exact.tmp_peak_kb);
print("flash_peak_kb=" + exact.flash_peak_kb);
UCODE

out="$(ucode -L "$LIB_DIR" "$WORK_DIR/scenarios.uc" 2>&1)" \
  || fail "the disk scenarios did not run: $out"

field() { printf '%s\n' "$out" | grep "^$1=" | cut -d= -f2- | head -1; }

# --- room to spare ---------------------------------------------------------
[ "$(field roomy_ok)" = "yes" ] || fail "a disk with plenty of room was rejected: $out"
[ "$(field roomy_tmp_deficit)" = "0" ] || fail "a healthy /tmp reported a deficit: $out"
[ "$(field roomy_flash_deficit)" = "0" ] || fail "healthy flash reported a deficit: $out"

# --- /tmp full -------------------------------------------------------------
[ "$(field tmpfull_ok)" = "no" ] || fail "a full /tmp was accepted: $out"
grep -qE '^tmpfull_tmp_deficit=[1-9]' <<< "$out" || fail "a full /tmp was not reported as short: $out"
grep -qiE "^tmpfull_message=.*/tmp needs [0-9]+ KB, short by [0-9]+ KB" <<< "$out" \
  || fail "the refusal does not say how much /tmp is short: $out"

# --- flash full ------------------------------------------------------------
[ "$(field flashfull_ok)" = "no" ] || fail "a full flash was accepted: $out"
grep -qE '^flashfull_flash_deficit=[1-9]' <<< "$out" || fail "a full flash was not reported as short: $out"
grep -qiE "^flashfull_message=.*flash needs [0-9]+ KB, short by [0-9]+ KB" <<< "$out" \
  || fail "the refusal does not say how much flash is short: $out"

# --- both full: both filesystems named -------------------------------------
msg="$(field bothfull_message)"
grep -q '/tmp' <<< "$msg" || fail "a doubly-full disk reported only one filesystem: $msg"
grep -q 'flash' <<< "$msg" || fail "a doubly-full disk reported only one filesystem: $msg"

# --- garbage free-space readings -------------------------------------------
[ "$(field zerofree_ok)" = "no" ] || fail "a zero-free filesystem was accepted: $out"
[ "$(field negative_ok)" = "no" ] || fail "a negative-free filesystem was accepted: $out"

# --- the boundary ----------------------------------------------------------
[ "$(field atexact_ok)" = "yes" ] || fail "a filesystem exactly at the requirement was refused: $out"
[ "$(field onebelow_ok)" = "no" ] || fail "one kilobyte below the requirement was accepted: $out"

# --- the message names the figure that was actually enforced ---------------
tmp_peak="$(field budget_tmp_peak)"
flash_peak="$(field budget_flash_peak)"
[ -n "$tmp_peak" ] && [ -n "$flash_peak" ] || fail "the budget was not computed: $out"
grep -qE "^tmpfull_message=.*/tmp needs ${tmp_peak} KB" <<< "$out" \
  || fail "the refusal names a different /tmp requirement than the one enforced (${tmp_peak} KB): $out"
grep -qE "^flashfull_message=.*flash needs ${flash_peak} KB" <<< "$out" \
  || fail "the refusal names a different flash requirement than the one enforced (${flash_peak} KB): $out"

printf 'fault: disk exhaustion checks passed\n'
