#!/usr/bin/env bash
# Regression test for native WireGuard/AWG recovery in priority groups:
# When higher-priority outbounds stall across an outage, recovery probing
# calls reset_outbound (/tachyon/outbound/reset) after consecutive recovery
# failures and honors the per-tag cooldown, enabling transition back to tier 1.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

FAKE_DIAG="$WORK_DIR/fake_diagnostics.uc"
DIAG_STATE="$WORK_DIR/diag_state.json"
DIAG_LOG="$WORK_DIR/diag_calls.log"
UCI_STATE_FILE="$WORK_DIR/uci.state"

FAKE_BIN="$WORK_DIR/fake_bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat >"$FAKE_BIN/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/logger"

cat >"$UCI_STATE_FILE" <<'UCI'
tachyon.settings=settings
tachyon.pg_test=priority_group
tachyon.pg_test.check_timeout=2s
UCI

cat >"$FAKE_DIAG" <<'UC'
#!/usr/bin/env ucode
let fs = require("fs");
let state_file = getenv("TEST_DIAG_STATE");
let log_file = getenv("TEST_DIAG_LOG");

function read_state() {
    let raw = fs.readfile(state_file);
    return raw ? json(raw) : { awg_alive: false, always_dead: false, selected: "sub-backup" };
}

function write_state(s) {
    fs.writefile(state_file, sprintf("%J\n", s));
}

if (ARGV[0] != "clash-api")
    exit(1);

let action = ARGV[1] || "";
let existing_log = fs.readfile(log_file) || "";
fs.writefile(log_file, existing_log + action + " " + (ARGV[2] || "") + " " + (ARGV[3] || "") + "\n");

let st = read_state();
if (action == "get_proxy_latency") {
    let tag = ARGV[2] || "";
    if (tag == "sub-backup") {
        print("{\"delay\":55}\n");
        exit(0);
    }
    if (tag == "awg-primary") {
        if (st.awg_alive && !st.always_dead) {
            print("{\"delay\":30}\n");
            exit(0);
        }
        print("{\"error\":\"timeout\"}\n");
        exit(0);
    }
    print("{\"error\":\"unknown\"}\n");
    exit(0);
}

if (action == "reset_outbound") {
    let tag = ARGV[2] || "";
    if (tag == "awg-primary" && !st.always_dead) {
        st.awg_alive = true;
        write_state(st);
    }
    print("{\"ok\":true}\n");
    exit(0);
}

if (action == "set_group_proxy") {
    st.selected = ARGV[3] || "";
    write_state(st);
    print("ok\n");
    exit(0);
}

exit(1);
UC
chmod +x "$FAKE_DIAG"

# Part 1: recovery across stalled native AWG + cooldown check
printf '{"awg_alive":false,"always_dead":false,"selected":"sub-backup"}\n' >"$DIAG_STATE"
: >"$DIAG_LOG"

UCI_STATE="$UCI_STATE_FILE" \
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_DIAGNOSTICS_UC="$FAKE_DIAG" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PRIORITY_RESET_COOLDOWN="0" \
TEST_DIAG_STATE="$DIAG_STATE" \
TEST_DIAG_LOG="$DIAG_LOG" \
PATH="$FAKE_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" -e '
    let fs = require("fs");
    let priority = require("tachyon_core.priority");
    let group = {
        id: "pg_test",
        tag: "bal-sec-pg_test",
        kind: "priority",
        section: "",
        health_url: "https://www.gstatic.com/generate_204",
        health_urls: [ "https://www.gstatic.com/generate_204" ],
        multi_url_strategy: "worst_case",
        active_check_interval: "15s",
        check_timeout: "2s",
        recovery_check_interval: "15s",
        pick_fastest: false,
        switch_to_faster_same_priority: false,
        fastest_check_interval: "3m",
        tolerance: 50,
        min_hold_time: "0s",
        levels: [
            { id: "lvl1", displayName: "AWG", order: 1, outbounds: [ "awg-primary" ] },
            { id: "lvl2", displayName: "Sub", order: 2, outbounds: [ "sub-backup" ] }
        ]
    };

    let state = priority.init_group_state(group);
    state.active = "sub-backup";
    state.levelIndex = 1;
    state.guard.escalated = true;
    state.guard.escalated_at = int(clock()[0]) - 60;
    state.guard.dwell_seconds = 0;
    state.guard.recover_threshold = 2;
    state.guard.ok_streak = 0;

    // Tick 1: first failed recovery probe -> threshold (2) not yet hit, no reset
    state.nextActiveCheck = int(clock()[0]) + 9999;
    state.nextFastestCheck = int(clock()[0]) + 9999;
    state.nextRecoveryCheck = 0;
    priority.tick_group(state, group);

    let log1 = fs.readfile(getenv("TEST_DIAG_LOG")) || "";
    if (index(log1, "reset_outbound awg-primary") >= 0) {
        warn("Tick 1 unexpectedly called reset_outbound before 2 consecutive failures\n");
        exit(1);
    }
    if (state.active != "sub-backup" || state.levelIndex != 1) {
        warn("Tick 1 unexpectedly switched away from sub-backup\n");
        exit(1);
    }

    // Tick 2: second failed recovery probe -> triggers reset_outbound, re-probes awg-primary -> ok_streak=1
    state.nextActiveCheck = int(clock()[0]) + 9999;
    state.nextFastestCheck = int(clock()[0]) + 9999;
    state.nextRecoveryCheck = 0;
    priority.tick_group(state, group);

    let log2 = fs.readfile(getenv("TEST_DIAG_LOG")) || "";
    if (index(log2, "reset_outbound awg-primary") < 0) {
        warn("Tick 2 failed to invoke reset_outbound for stalled awg-primary\n");
        exit(1);
    }
    if (state.guard.ok_streak != 1) {
        warn("Expected ok_streak=1 after immediate re-probe success, got " + state.guard.ok_streak + "\n");
        exit(1);
    }

    // Tick 3: second successful recovery probe -> switches back to tier 0 (awg-primary)
    state.nextActiveCheck = int(clock()[0]) + 9999;
    state.nextFastestCheck = int(clock()[0]) + 9999;
    state.nextRecoveryCheck = 0;
    priority.tick_group(state, group);

    if (state.active != "awg-primary" || state.levelIndex != 0) {
        warn("Tick 3 failed to recover to awg-primary, active=" + state.active + "\n");
        exit(1);
    }
  '

grep -Fq 'set_group_proxy bal-sec-pg_test awg-primary' "$DIAG_LOG" ||
  fail "expected set_group_proxy to restore awg-primary"

# Part 2: cooldown prevents repeated resets on every tick when endpoint stays dead
printf '{"awg_alive":false,"always_dead":true,"selected":"sub-backup"}\n' >"$DIAG_STATE"
: >"$DIAG_LOG"

UCI_STATE="$UCI_STATE_FILE" \
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_DIAGNOSTICS_UC="$FAKE_DIAG" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime2" \
TACHYON_PRIORITY_RESET_COOLDOWN="300" \
TEST_DIAG_STATE="$DIAG_STATE" \
TEST_DIAG_LOG="$DIAG_LOG" \
PATH="$FAKE_BIN:$PATH" \
  ucode -L "$TACHYON_LIB" -e '
    let priority = require("tachyon_core.priority");
    let group = {
        id: "pg_test",
        tag: "bal-sec-pg_test",
        kind: "priority",
        section: "",
        health_url: "https://www.gstatic.com/generate_204",
        health_urls: [ "https://www.gstatic.com/generate_204" ],
        multi_url_strategy: "worst_case",
        active_check_interval: "15s",
        check_timeout: "2s",
        recovery_check_interval: "15s",
        pick_fastest: false,
        switch_to_faster_same_priority: false,
        fastest_check_interval: "3m",
        tolerance: 50,
        min_hold_time: "0s",
        levels: [
            { id: "lvl1", displayName: "AWG", order: 1, outbounds: [ "awg-primary" ] },
            { id: "lvl2", displayName: "Sub", order: 2, outbounds: [ "sub-backup" ] }
        ]
    };

    let state = priority.init_group_state(group);
    state.active = "sub-backup";
    state.levelIndex = 1;
    state.guard.escalated = true;

    for (let i = 0; i < 5; i++) {
        state.nextActiveCheck = int(clock()[0]) + 9999;
        state.nextFastestCheck = int(clock()[0]) + 9999;
        state.nextRecoveryCheck = 0;
        priority.tick_group(state, group);
    }
  '

reset_count="$(grep -c '^reset_outbound awg-primary' "$DIAG_LOG" || true)"
[ "$reset_count" = "1" ] ||
  fail "expected reset_outbound cooldown to cap resets at 1 during outage, got $reset_count"

printf 'priority_recovery_outbound_reset: OK\n'
