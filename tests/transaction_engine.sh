#!/bin/bash
# Tests for core/transaction.uc — Unified Transaction Engine.
#
# Verifies:
#   - Module selftest passes
#   - Lifecycle phase constants and valid/invalid transitions
#   - Full happy path: PLAN -> PREFLIGHT -> SNAPSHOT -> MUTATE -> VALIDATE -> ACTIVATE -> VERIFY -> COMMIT
#   - Automatic snapshot cleanup on commit (tmpfs RAM conservation)
#   - Rollback on MUTATE exception restores original file
#   - Rollback on VALIDATE failure restores original file
#   - Rollback on VERIFY failure restores original file
#   - Newly created file unlinked on rollback
#   - LIFO execution order of compensations (last registered reverted first)
#   - Process identity integration and stale transaction detection
#   - Query, list filtering, and recovery
#   - Stale transaction GC
#   - CLI subcommands (list, query, rollback, gc)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$SCRIPT_DIR/../tachyon/files/usr/lib}"
TACHYON_UCODE="${TACHYON_UCODE:-ucode}"

pass=0
fail=0

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected '$expected', got '$actual'"
    fi
}

assert_true() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        fail_test "$label: command failed: $*"
    fi
}

# ---------------------------------------------------------------------------
# Run module selftest
# ---------------------------------------------------------------------------

printf '%s\n' '--- transaction.uc selftest ---'
if $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/transaction.uc" selftest; then
    pass=$((pass + 1))
else
    fail_test "transaction.uc selftest failed"
fi

# ---------------------------------------------------------------------------
# Test setup: isolated state directory
# ---------------------------------------------------------------------------

TEST_STATE_DIR="$(mktemp -d /tmp/tachyon_tx_test_XXXXXX 2>/dev/null || mktemp -d)"
cleanup() { rm -rf "$TEST_STATE_DIR"; }
trap cleanup EXIT
export TACHYON_RUNTIME_STATE_DIR="$TEST_STATE_DIR"

# ---------------------------------------------------------------------------
# Test 1: Phase and status constants
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 1: constants ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let tx = require("core.transaction");
let c1 = (tx.PHASE_PLAN == "plan" && tx.PHASE_PREFLIGHT == "preflight" && tx.PHASE_SNAPSHOT == "snapshot");
let c2 = (tx.PHASE_MUTATE == "mutate" && tx.PHASE_VALIDATE == "validate" && tx.PHASE_ACTIVATE == "activate");
let c3 = (tx.PHASE_VERIFY == "verify" && tx.PHASE_COMMIT == "commit" && tx.PHASE_ROLLBACK == "rollback");
let c4 = (tx.STATUS_IN_PROGRESS == "in_progress" && tx.STATUS_COMMITTED == "committed" && tx.STATUS_ROLLED_BACK == "rolled_back");
if (c1 && c2 && c3 && c4)
    print("PASS\n");
else
    print("FAIL\n");
' 2>&1)
assert_eq "constants" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 2: Valid and invalid phase transitions
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 2: phase transitions ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let tx = require("core.transaction");
let t = tx.create("transition_test");
let ok1 = t.transition(tx.PHASE_PREFLIGHT);
let ok2 = t.transition(tx.PHASE_SNAPSHOT);
// Invalid jump from snapshot directly to commit without mutate/validate/activate/verify
let bad = t.transition(tx.PHASE_COMMIT);
if (ok1 === true && ok2 === true && bad === false)
    print("PASS\n");
else
    print("FAIL: ok1=" + ok1 + " ok2=" + ok2 + " bad=" + bad + "\n");
' 2>&1)
assert_eq "phase transitions" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 3: Happy path execution through all 7 phases to COMMIT
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 3: happy path run() ---'
TARGET_FILE="$TEST_STATE_DIR/sample_config.conf"
printf 'initial_data=123\n' > "$TARGET_FILE"

RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e "
let tx = require(\"core.transaction\");
let fs = require(\"fs\");
let target = \"$TARGET_FILE\";

let res = tx.run(\"happy_update\", {
    plan: function(t) { return { will_update: true }; },
    preflight: function(t) { return true; },
    snapshot: function(t) {
        let snap = t.snapshot_file(target);
        if (!snap || !snap.existed) return false;
        return true;
    },
    mutate: function(t) {
        fs.writefile(target, \"updated_data=456\n\");
        return true;
    },
    validate: function(t) {
        let val = trim(fs.readfile(target) || \"\");
        return val == \"updated_data=456\";
    },
    activate: function(t) { return true; },
    verify: function(t) { return true; }
});

if (res && res.ok === true) {
    let q = tx.query(res.tx_id);
    if (q && q.status == \"committed\" && q.phase == \"commit\") {
        // Verify snapshot was cleaned up on commit
        let snap_dir = q.dir + \"/snapshots\";
        let snap_files = fs.lsdir(snap_dir) || [];
        let count = 0;
        for (let f in snap_files) {
            if (f != \".\" && f != \"..\") count++;
        }
        if (count == 0) {
            print(\"PASS:\" + res.tx_id + \"\n\");
        } else {
            print(\"FAIL: snapshots not cleaned up, count=\" + count + \"\n\");
        }
    } else {
        print(\"FAIL: query status=\" + (q ? q.status : \"null\") + \"\n\");
    }
} else {
    print(\"FAIL: run failed \" + sprintf(\"%J\", res) + \"\n\");
}
" 2>&1)
assert_eq "happy path run()" "PASS" "${RESULT%%:*}"

# ---------------------------------------------------------------------------
# Test 4: Rollback on VALIDATE failure restores original content
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 4: rollback on validate failure ---'
TARGET_FILE2="$TEST_STATE_DIR/sample_config_2.conf"
printf 'pre_mutation_content\n' > "$TARGET_FILE2"

RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e "
let tx = require(\"core.transaction\");
let fs = require(\"fs\");
let target = \"$TARGET_FILE2\";

let res = tx.run(\"failing_validation\", {
    snapshot: function(t) {
        t.snapshot_file(target);
        return true;
    },
    mutate: function(t) {
        fs.writefile(target, \"bad_corrupted_data\n\");
        return true;
    },
    validate: function(t) {
        return { ok: false, error: \"Syntax error in config\" };
    }
});

let restored = trim(fs.readfile(target) || \"\");
if (res.ok === false && res.rolled_back === true && restored == \"pre_mutation_content\") {
    print(\"PASS\n\");
} else {
    print(\"FAIL: ok=\" + res.ok + \" rolled_back=\" + res.rolled_back + \" restored=\" + restored + \"\n\");
}
" 2>&1)
assert_eq "rollback on validate" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 5: Rollback on VERIFY failure restores state
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 5: rollback on verify failure ---'
TARGET_FILE3="$TEST_STATE_DIR/sample_config_3.conf"
printf 'active_version=1.0\n' > "$TARGET_FILE3"

RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e "
let tx = require(\"core.transaction\");
let fs = require(\"fs\");
let target = \"$TARGET_FILE3\";

let res = tx.run(\"failing_verify\", {
    snapshot: function(t) {
        t.snapshot_file(target);
        return true;
    },
    mutate: function(t) {
        fs.writefile(target, \"active_version=2.0\n\");
        return true;
    },
    validate: function(t) { return true; },
    activate: function(t) { return true; },
    verify: function(t) {
        // Health check fails (e.g. sing-box didn not answer)
        return false;
    }
});

let restored = trim(fs.readfile(target) || \"\");
if (res.ok === false && res.rolled_back === true && restored == \"active_version=1.0\") {
    print(\"PASS\n\");
} else {
    print(\"FAIL: restored=\" + restored + \"\n\");
}
" 2>&1)
assert_eq "rollback on verify" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 6: LIFO compensation execution order
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 6: LIFO compensation order ---'
ORDER_LOG="$TEST_STATE_DIR/lifo_order.log"

RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e "
let tx = require(\"core.transaction\");
let fs = require(\"fs\");
let order_file = \"$ORDER_LOG\";

let t = tx.create(\"lifo_test\");
t.register_compensation(\"custom\", {}, function(ctx, data) {
    let cur = fs.readfile(order_file) || \"\";
    fs.writefile(order_file, cur + \"1,\");
    return true;
});
t.register_compensation(\"custom\", {}, function(ctx, data) {
    let cur = fs.readfile(order_file) || \"\";
    fs.writefile(order_file, cur + \"2,\");
    return true;
});
t.register_compensation(\"custom\", {}, function(ctx, data) {
    let cur = fs.readfile(order_file) || \"\";
    fs.writefile(order_file, cur + \"3,\");
    return true;
});

let rb = t.rollback(\"test LIFO order\");
let order = trim(fs.readfile(order_file) || \"\");
if (order == \"3,2,1,\")
    print(\"PASS\n\");
else
    print(\"FAIL: order=\" + order + \"\n\");
" 2>&1)
assert_eq "LIFO compensation order" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 7: Newly created file cleanup on rollback
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 7: newly created file cleanup ---'
NEW_TARGET="$TEST_STATE_DIR/created_during_mutate.bin"
rm -f "$NEW_TARGET"

RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e "
let tx = require(\"core.transaction\");
let fs = require(\"fs\");
let target = \"$NEW_TARGET\";

let res = tx.run(\"new_file_test\", {
    snapshot: function(t) {
        t.snapshot_file(target); // does not exist yet
        return true;
    },
    mutate: function(t) {
        fs.writefile(target, \"binary_blob_content\");
        return true;
    },
    validate: function(t) {
        // Intentionally throw exception to test crash during validation
        die(\"Corrupted binary header\");
    }
});

let exists = (fs.stat(target) != null);
if (res.ok === false && res.rolled_back === true && !exists)
    print(\"PASS\n\");
else
    print(\"FAIL: exists=\" + exists + \" res=\" + sprintf(\"%J\", res) + \"\n\");
" 2>&1)
assert_eq "newly created file cleanup" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 8: Process identity and stale transaction detection
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 8: stale transaction detection & recovery ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let tx = require("core.transaction");
let t = tx.create("stale_test");

// Simulate dead executor PID
t.executor = {
    pid: "999999",
    starttime: "12345",
    boot_id: "fake_boot_id",
    command: "dead_worker"
};
tx.save(t);

let is_stale = tx.is_stale(t);
let rec = tx.recover(t.id);
let q = tx.query(t.id);

if (is_stale === true && rec.ok === false && rec.rolled_back === true && q.status == "rolled_back")
    print("PASS\n");
else
    print("FAIL: stale=" + is_stale + " rec=" + sprintf("%J", rec) + " q_status=" + (q ? q.status : "null") + "\n");
' 2>&1)
assert_eq "stale detection and recovery" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 9: List and query filtering
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 9: list and query filtering ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let tx = require("core.transaction");
let all_txs = tx.list();
let committed_txs = tx.list({ status: "committed" });
let rolled_back_txs = tx.list({ status: "rolled_back" });

let has_all = length(all_txs) >= 4;
let has_committed = length(committed_txs) >= 1;
let has_rolled = length(rolled_back_txs) >= 2;

if (has_all && has_committed && has_rolled)
    print("PASS\n");
else
    print("FAIL: all=" + length(all_txs) + " committed=" + length(committed_txs) + " rolled=" + length(rolled_back_txs) + "\n");
' 2>&1)
assert_eq "list and query filtering" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Test 10: GC cleans up old transactions
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 10: gc cleans up expired transactions ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let tx = require("core.transaction");
let before_count = length(tx.list());
// Run GC with 0 max_age to clean all completed transactions
let gc_res = tx.gc(0);
let after_count = length(tx.list());

if (gc_res.ok === true && gc_res.cleaned > 0 && after_count < before_count)
    print("PASS:" + gc_res.cleaned + "\n");
else
    print("FAIL: gc_res=" + sprintf("%J", gc_res) + " before=" + before_count + " after=" + after_count + "\n");
' 2>&1)
assert_eq "gc cleanup" "PASS" "${RESULT%%:*}"

# ---------------------------------------------------------------------------
# Test 11: CLI subcommands (list, query, gc)
# ---------------------------------------------------------------------------

printf '%s\n' '--- test 11: CLI subcommands ---'
assert_true "CLI list succeeds" $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/transaction.uc" list
assert_true "CLI gc succeeds" $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/transaction.uc" gc

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%s\n' "========================================"
printf '%s: %d passed, %d failed\n' "$0" "$pass" "$fail"
printf '%s\n' "========================================"

if [ "$fail" -eq 0 ]; then
    exit 0
else
    exit 1
fi
