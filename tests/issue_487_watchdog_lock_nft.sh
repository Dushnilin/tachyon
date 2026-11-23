#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

BG_PIDS=()
cleanup() {
  for p in "${BG_PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

REAL_LIB="$ROOT_DIR/tachyon/files/usr/lib"
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/uci" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  get|show)
    exit 1
    ;;
  export|changes)
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/uci"

# ---------------------------------------------------------------------------
# 1. Watchdog PID ownership and supervisor superseding
# ---------------------------------------------------------------------------
W_PID="$WORK_DIR/watchdog.pid"
S_PID="$WORK_DIR/watchdog.supervisor.pid"
W_ERR="$WORK_DIR/worker.err"
FAKE_WORKER="$WORK_DIR/fake_worker.uc"

cat >"$FAKE_WORKER" <<'EOF'
let fs = require("fs");
let marker = getenv("FAKE_WORKER_STARTED_LOG") || "";
if (marker != "") {
    let f = fs.open(marker, "a");
    if (f) {
        f.write("started\n");
        f.close();
    }
}
sleep(30000);
EOF

ucode -e 'sleep(30000);' &
other_worker_pid=$!
BG_PIDS+=("$other_worker_pid")
printf '%s\n' "$other_worker_pid" >"$W_PID"

TACHYON_WATCHDOG_PID_FILE="$W_PID" \
TACHYON_WATCHDOG_SUPERVISOR_PID_FILE="$S_PID" \
TACHYON_WATCHDOG_WORKER_UC="$FAKE_WORKER" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/watchdog.uc" stop-runtime 1

[ -f "$W_PID" ] || fail "stop_runtime(true) deleted PID file belonging to another live worker"
[ "$(cat "$W_PID")" = "$other_worker_pid" ] || fail "stop_runtime(true) mutated PID file contents"
kill -0 "$other_worker_pid" 2>/dev/null || fail "stop_runtime(true) killed live foreign worker"
kill "$other_worker_pid" 2>/dev/null || true
wait "$other_worker_pid" 2>/dev/null || true
rm -f "$W_PID"

STARTED_LOG="$WORK_DIR/worker_started.log"
: >"$STARTED_LOG"
PATH="$FAKE_BIN:$PATH" \
TACHYON_WATCHDOG_PID_FILE="$W_PID" \
TACHYON_WATCHDOG_SUPERVISOR_PID_FILE="$S_PID" \
TACHYON_WATCHDOG_WORKER_ERR_FILE="$W_ERR" \
TACHYON_WATCHDOG_WORKER_UC="$FAKE_WORKER" \
FAKE_WORKER_STARTED_LOG="$STARTED_LOG" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/watchdog_supervisor.uc" supervise >/dev/null 2>&1 &
sup1_pid=$!
BG_PIDS+=("$sup1_pid")
printf '%s\n' "$sup1_pid" >"$S_PID"

w1_pid=""
for _ in $(seq 1 40); do
  if [ -s "$W_PID" ]; then
    w1_pid="$(tr -d '[:space:]' <"$W_PID")"
    if [ -n "$w1_pid" ] && kill -0 "$w1_pid" 2>/dev/null; then
      break
    fi
  fi
  sleep 0.1
done
[ -n "$w1_pid" ] && kill -0 "$w1_pid" 2>/dev/null || fail "supervisor failed to launch worker 1"

ucode -e 'sleep(30000);' &
sup2_pid=$!
BG_PIDS+=("$sup2_pid")
ucode -e 'sleep(30000);' &
w2_pid=$!
BG_PIDS+=("$w2_pid")
printf '%s\n' "$sup2_pid" >"$S_PID"
printf '%s\n' "$w2_pid" >"$W_PID"

for _ in $(seq 1 50); do
  if ! kill -0 "$sup1_pid" 2>/dev/null && ! kill -0 "$w1_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$sup1_pid" 2>/dev/null; then
  fail "superseded watchdog supervisor failed to exit"
fi
if kill -0 "$w1_pid" 2>/dev/null; then
  fail "superseded watchdog supervisor left its own worker alive"
fi
[ -f "$W_PID" ] && [ "$(tr -d '[:space:]' <"$W_PID")" = "$w2_pid" ] || fail "superseded supervisor overwrote new worker PID_FILE"
kill -0 "$w2_pid" 2>/dev/null || fail "superseded supervisor killed new worker"

# ---------------------------------------------------------------------------
# 2. Live lock never stolen after >300s & owner-checked release
# ---------------------------------------------------------------------------
LOCK_DIR="$WORK_DIR/reload.lock"
ucode -e 'sleep(30000);' &
lock_owner=$!
BG_PIDS+=("$lock_owner")
mkdir -p "$LOCK_DIR"
printf '%s\n' "$lock_owner" >"$LOCK_DIR/pid"
touch -d '@1000000000' "$LOCK_DIR" "$LOCK_DIR/pid"

if ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" acquire-runtime-dir-lock "$LOCK_DIR" 999999; then
  fail "state.uc stole lock from live owner after >300s"
fi
[ "$(tr -d '[:space:]' <"$LOCK_DIR/pid")" = "$lock_owner" ] || fail "state.uc overwrote live owner pid"

ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" release-runtime-dir-lock "$LOCK_DIR" 999999
[ -d "$LOCK_DIR" ] || fail "state.uc released lock despite wrong owner pid while owner alive"

TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/initd.uc" reload-release 999999
[ -d "$LOCK_DIR" ] || fail "initd.uc reload-release released lock despite wrong owner pid"

# ---------------------------------------------------------------------------
# 3. Direct lifecycle.uc reload honors RELOAD_LOCK_DIR
# ---------------------------------------------------------------------------
PENDING="$WORK_DIR/reload.pending"
TACHYON_LIB="$REAL_LIB" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_PENDING_RELOAD_FILE="$PENDING" \
PATH="$FAKE_BIN:$PATH" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload on_config_change

[ -d "$LOCK_DIR" ] && [ "$(tr -d '[:space:]' <"$LOCK_DIR/pid")" = "$lock_owner" ] || fail "lifecycle.uc reload broke live reload lock"
[ -f "$PENDING" ] && grep -q '^reason=reload_busy$' "$PENDING" || fail "lifecycle.uc reload did not mark pending reload when lock busy"

ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" release-runtime-dir-lock "$LOCK_DIR" "$lock_owner"
[ ! -d "$LOCK_DIR" ] || fail "state.uc failed to release lock for matching owner pid"

# ---------------------------------------------------------------------------
# 4. nft/apply.uc error propagation, per-set split, 256MB chunking & unchanged skip
# ---------------------------------------------------------------------------
NFT_LOG="$WORK_DIR/nft_calls.log"
NFT_BATCH_COPY_DIR="$WORK_DIR/nft_batches"
NFT_LIST_JSON="$WORK_DIR/nft_list_set.json"
NFT_TABLE_JSON="$WORK_DIR/nft_list_table.json"
mkdir -p "$NFT_BATCH_COPY_DIR"

cat >"$NFT_TABLE_JSON" <<'EOF'
{"nftables":[{"set":{"name":"set_a","table":"TachyonTest","type":"ipv4_addr"}},{"set":{"name":"set_b","table":"TachyonTest","type":"ipv6_addr"}}]}
EOF

cat >"$NFT_LIST_JSON" <<'EOF'
{"nftables":[{"set":{"family":"inet","name":"set_a","table":"TachyonTest","type":"ipv4_addr","elem":[{"prefix":{"addr":"10.0.0.0","len":23}}]}}]}
EOF

cat >"$FAKE_BIN/nft" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >>"$FAKE_NFT_LOG"
if [ "${1:-}" = "list" ] && [ "${2:-}" = "table" ]; then
  exit 0
fi
if [ "${1:-}" = "-j" ] && [ "${2:-}" = "-t" ] && [ "${3:-}" = "list" ] && [ "${4:-}" = "table" ]; then
  cat "$FAKE_NFT_TABLE_JSON"
  exit 0
fi
if [ "${1:-}" = "-j" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "set" ]; then
  cat "$FAKE_NFT_LIST_JSON"
  exit 0
fi
if [ "${FAKE_NFT_FAIL:-0}" = "1" ]; then
  exit 1
fi
if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ] && [ -f "${2:-}" ]; then
  idx=$(( $(find "$FAKE_NFT_BATCH_COPY_DIR" -maxdepth 1 -type f | wc -l) + 1 ))
  cp "$2" "$FAKE_NFT_BATCH_COPY_DIR/batch_${idx}.nft"
fi
exit 0
EOF
chmod +x "$FAKE_BIN/nft"

# 4a. Community subnet nft failure must propagate out of nft_load_community_subnets
FIXTURE_NFT="$WORK_DIR/fixture_nft.json"
cat >"$FIXTURE_NFT" <<'EOF'
{"section":[
  {".name":"tg","enabled":"1","action":"proxy","community_lists":["telegram"],"community_subnets":"1"}
]}
EOF

: >"$NFT_LOG"
if PATH="$FAKE_BIN:$PATH" \
  FAKE_NFT_LOG="$NFT_LOG" \
  FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
  FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
  FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
  FAKE_NFT_FAIL=1 \
  TACHYON_NFT_LOW_RAM=1 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
    "$FIXTURE_NFT" 1 "" TachyonTest tachyon_subnets tachyon_ports tachyon_ip_ports \
    tachyon_interfaces localv4 0x10 tachyon_subnets6 tachyon_ip6_ports localv6 2>/dev/null; then
  fail "nft_load_community_subnets swallowed nft execution failure"
fi

if ! PATH="$FAKE_BIN:$PATH" \
  FAKE_NFT_LOG="$NFT_LOG" \
  FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
  FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
  FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
  FAKE_NFT_FAIL=0 \
  TACHYON_NFT_LOW_RAM=1 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
    "$FIXTURE_NFT" 1 "" TachyonTest tachyon_subnets tachyon_ports tachyon_ip_ports \
    tachyon_interfaces localv4 0x10 tachyon_subnets6 tachyon_ip6_ports localv6; then
  fail "nft-populate-runtime-sets-fixture failed when stub nft succeeded"
fi

# 4b. Per-set split and low-RAM (<=384MB) chunking (1500 vs 3000) in nft-commit-list-refresh
MEMINFO_256M="$WORK_DIR/meminfo_256m"
MEMINFO_1G="$WORK_DIR/meminfo_1g"
printf 'MemTotal:         262144 kB\n' >"$MEMINFO_256M"
printf 'MemTotal:        1048576 kB\n' >"$MEMINFO_1G"

PREFIX="$WORK_DIR/prefix.nft"
ADDITIONS="$WORK_DIR/additions.nft"
printf 'flush set inet TachyonTest set_a\nflush set inet TachyonTest set_b\n' >"$PREFIX"
ips_1600=""
for i in $(seq 0 6); do
  for j in $(seq 0 255); do
    if [ $((i * 256 + j)) -ge 1600 ]; then
      break
    fi
    ip="10.10.${i}.${j}"
    if [ -n "$ips_1600" ]; then
      ips_1600="${ips_1600}, ${ip}"
    else
      ips_1600="${ip}"
    fi
  done
done
printf 'add element inet TachyonTest set_a { %s }\nadd element inet TachyonTest set_b { 2001:db8::1, 2001:db8::2 }\n' "$ips_1600" >"$ADDITIONS"

rm -f "$NFT_BATCH_COPY_DIR"/*
: >"$NFT_LOG"
PATH="$FAKE_BIN:$PATH" \
FAKE_NFT_LOG="$NFT_LOG" \
FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
TACHYON_PROC_MEMINFO="$MEMINFO_256M" \
TACHYON_NFT_SKIP_UNCHANGED=0 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-commit-list-refresh "$PREFIX" "$ADDITIONS"

batch_count_256m=$(find "$NFT_BATCH_COPY_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
[ "$batch_count_256m" -eq 3 ] || fail "256MB low-RAM mode should split 1600 IPv4 + 1 IPv6 set into 3 nft -f batches (got $batch_count_256m)"

for bf in "$NFT_BATCH_COPY_DIR"/*.nft; do
  if grep -q 'set_a' "$bf" && grep -q 'set_b' "$bf"; then
    fail "batch $bf mixed multiple target sets"
  fi
done

rm -f "$NFT_BATCH_COPY_DIR"/*
: >"$NFT_LOG"
PATH="$FAKE_BIN:$PATH" \
FAKE_NFT_LOG="$NFT_LOG" \
FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
TACHYON_PROC_MEMINFO="$MEMINFO_1G" \
TACHYON_NFT_SKIP_UNCHANGED=0 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-commit-list-refresh "$PREFIX" "$ADDITIONS"

batch_count_1g=$(find "$NFT_BATCH_COPY_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
[ "$batch_count_1g" -eq 2 ] || fail "1GB RAM mode should apply 1600 IPv4 + 1 IPv6 set in 2 per-set batches (got $batch_count_1g)"

# 4c. Skip unchanged IPv4 interval sets when canonical intervals match
printf 'flush set inet TachyonTest set_a\n' >"$PREFIX"
printf 'add element inet TachyonTest set_a { 10.0.0.0/24, 10.0.1.0/24 }\n' >"$ADDITIONS"
rm -f "$NFT_BATCH_COPY_DIR"/*
: >"$NFT_LOG"
PATH="$FAKE_BIN:$PATH" \
FAKE_NFT_LOG="$NFT_LOG" \
FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
TACHYON_NFT_SKIP_UNCHANGED=1 \
TACHYON_NFT_SKIP_UNCHANGED_MIN=2 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-commit-list-refresh "$PREFIX" "$ADDITIONS"

skip_batches=$(find "$NFT_BATCH_COPY_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
[ "$skip_batches" -eq 0 ] || fail "unchanged canonical IPv4 set was not skipped (ran $skip_batches batches)"

printf 'add element inet TachyonTest set_a { 10.0.0.0/24, 10.0.2.0/24 }\n' >"$ADDITIONS"
rm -f "$NFT_BATCH_COPY_DIR"/*
: >"$NFT_LOG"
PATH="$FAKE_BIN:$PATH" \
FAKE_NFT_LOG="$NFT_LOG" \
FAKE_NFT_BATCH_COPY_DIR="$NFT_BATCH_COPY_DIR" \
FAKE_NFT_TABLE_JSON="$NFT_TABLE_JSON" \
FAKE_NFT_LIST_JSON="$NFT_LIST_JSON" \
TACHYON_NFT_SKIP_UNCHANGED=1 \
TACHYON_NFT_SKIP_UNCHANGED_MIN=2 \
  ucode -L "$REAL_LIB" "$REAL_LIB/nft/apply.uc" nft-commit-list-refresh "$PREFIX" "$ADDITIONS"

changed_batches=$(find "$NFT_BATCH_COPY_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
[ "$changed_batches" -eq 1 ] || fail "changed IPv4 set did not trigger nft -f apply (got $changed_batches batches)"

# ---------------------------------------------------------------------------
# 5. Watchdog heal_oom distinguishes nft OOM during active RELOAD_LOCK_DIR
# ---------------------------------------------------------------------------
cat >"$FAKE_BIN/dmesg" <<'EOF'
#!/usr/bin/env bash
cat <<'KLOG'
[  123.456789] nft invoked oom-killer: gfp_mask=0x1100cca(GFP_HIGHUSER_MOVABLE), order=0, oom_score_adj=0
[  123.456790] Memory cgroup stats for /system.slice:
[  123.456800] Out of memory: Killed process 4321 (nft) total-vm:98304kB, anon-rss:81920kB, file-rss:0kB, shmem-rss:0kB
KLOG
EOF
chmod +x "$FAKE_BIN/dmesg"

KMSG_OUT="$WORK_DIR/watchdog.kmsg"
OOM_LOCK="$WORK_DIR/oom_reload.lock"
mkdir -p "$OOM_LOCK"
: >"$KMSG_OUT"

PATH="$FAKE_BIN:$PATH" \
TACHYON_WATCHDOG_KMSG="$KMSG_OUT" \
TACHYON_RELOAD_LOCK_DIR="$OOM_LOCK" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/watchdog.uc" heal-oom-test

grep -q 'OOM killed nft while Tachyon was applying firewall sets; not restarting Tachyon' "$KMSG_OUT" || \
  fail "heal_oom did not report active Tachyon nft OOM (got: $(cat "$KMSG_OUT"))"

rmdir "$OOM_LOCK"
: >"$KMSG_OUT"

PATH="$FAKE_BIN:$PATH" \
TACHYON_WATCHDOG_KMSG="$KMSG_OUT" \
TACHYON_RELOAD_LOCK_DIR="$OOM_LOCK" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/watchdog.uc" heal-oom-test

grep -q 'OOM killed nft outside Tachyon; not restarting Tachyon' "$KMSG_OUT" || \
  fail "heal_oom did not report external nft OOM when reload lock absent (got: $(cat "$KMSG_OUT"))"

printf 'issue_487_watchdog_lock_nft tests passed\n'
