#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/jobs" "$WORK_DIR/sub_jobs" "$WORK_DIR/outbox"

# 1. core/uci.uc: reload export + harden_config_mode uses fs.chmod without external chmod binary
cat >"$WORK_DIR/bin/chmod" <<'SH'
#!/bin/sh
echo "chmod-called $*" >> "$TACHYON_CHMOD_CALLS"
exit 1
SH
chmod +x "$WORK_DIR/bin/chmod"

cat >"$WORK_DIR/uci_target.conf" <<'EOF'
package tachyon
config settings 'settings'
	option enabled '1'
EOF
chmod 0644 "$WORK_DIR/uci_target.conf"
: > "$WORK_DIR/uci_state"
: > "$WORK_DIR/chmod_calls.log"

env -i PATH="$WORK_DIR/bin:$PATH" HOME="$WORK_DIR" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_state" \
    TACHYON_CHMOD_CALLS="$WORK_DIR/chmod_calls.log" \
    ucode -L "$TACHYON_LIB" -e '
        let uci = require("core.uci");
        if (type(uci.reload) != "function") { warn("missing reload\n"); exit(1); }
        uci.reload("tachyon");
        // Verify fs.chmod works internally and uci.set/commit succeeds
        if (!uci.set("tachyon", "settings", "enabled", "1") || !uci.commit("tachyon")) {
            warn("uci set/commit failed\n"); exit(1);
        }
        let fs = require("fs");
        fs.chmod("'"$WORK_DIR/uci_target.conf"'", 0600);
        let st = fs.stat("'"$WORK_DIR/uci_target.conf"'");
        if ((st.mode & 0777) != 0600) { warn("mode mismatch\n"); exit(1); }
    ' || fail "core/uci check failed"
[ ! -s "$WORK_DIR/chmod_calls.log" ] || fail "external chmod must not be called"

# 2. core/events.uc: journal compact shrinks cleanly and keeps newest events; emit_once evicts cleanly
env -i PATH="$PATH" HOME="$WORK_DIR" \
    ucode -L "$TACHYON_LIB" -e '
        let ev = require("core.events");
        let fs = require("fs");
        let jpath = "'"$WORK_DIR/events.jsonl"'";
        let j = ev.journal({ path: jpath, max_bytes: 2048 });
        for (let i = 0; i < 60; i++)
            j.record("test.ev", { idx: i, pad: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
        j.compact();
        let st = fs.stat(jpath);
        if (!st || st.size > 2048 || st.size == 0) {
            warn("unexpected compacted journal size: " + (st ? st.size : "null") + "\n");
            exit(1);
        }
        let tail = j.tail(5);
        if (length(tail) == 0 || tail[0].data.idx != 59) {
            warn("journal tail missing latest event\n");
            exit(1);
        }
        let b = ev.bus();
        let count = 0;
        b.on("k", function() { count++; });
        for (let i = 0; i < 300; i++)
            b.emit_once("k", "key_" + i, {}, 60);
        if (count != 300) {
            warn("emit_once dropped events unexpectedly: " + count + "\n");
            exit(1);
        }
    ' || fail "core/events compact/emit_once check failed"

# 3. dns_failover.uc: stop-runtime sweeps orphan .candidate.* and .tmp.* files
touch "$WORK_DIR/run/dns-failover.json.candidate.9999"
touch "$WORK_DIR/run/dns-failover.json.tmp.9999.1"
env -i PATH="$PATH" HOME="$WORK_DIR" \
    TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/run/dns-failover.json" \
    TACHYON_DNS_FAILOVER_PID_FILE="$WORK_DIR/run/dns-failover.pid" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/dns_failover.uc" stop-runtime >/dev/null 2>&1 || true
[ ! -e "$WORK_DIR/run/dns-failover.json.candidate.9999" ] || fail "orphan .candidate file survived stop-runtime"
[ ! -e "$WORK_DIR/run/dns-failover.json.tmp.9999.1" ] || fail "orphan .tmp file survived stop-runtime"

# 4. updates.uc: cleanup_jobs works in pure ucode even when BusyBox find -delete is broken
cat >"$WORK_DIR/bin/find" <<'SH'
#!/bin/sh
echo "find: unrecognized: -delete" >&2
exit 1
SH
chmod +x "$WORK_DIR/bin/find"

old_epoch=$(( $(date +%s) - 7200 ))
touch -d "@$old_epoch" "$WORK_DIR/jobs/old1.out" "$WORK_DIR/jobs/old1.out.stderr" \
    "$WORK_DIR/jobs/old1.log" "$WORK_DIR/jobs/old1.out.json" "$WORK_DIR/jobs/tmp1.json.abc" \
    "$WORK_DIR/sub_jobs/sub1.out"
cat >"$WORK_DIR/jobs/finished1.json" <<'JSON'
{"running":false,"success":true}
JSON
cat >"$WORK_DIR/sub_jobs/subdone.json" <<'JSON'
{"running":false,"success":true}
JSON
touch -d "@$old_epoch" "$WORK_DIR/jobs/finished1.json" "$WORK_DIR/sub_jobs/subdone.json"

env -i PATH="$WORK_DIR/bin:$PATH" HOME="$WORK_DIR" \
    UPDATES_JOB_DIR="$WORK_DIR/jobs" \
    TACHYON_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/sub_jobs" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" component-action-status nonexistent >/dev/null 2>&1 || true
env -i PATH="$WORK_DIR/bin:$PATH" HOME="$WORK_DIR" \
    UPDATES_JOB_DIR="$WORK_DIR/jobs" \
    TACHYON_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/sub_jobs" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/updates.uc" subscription-update-status nonexistent >/dev/null 2>&1 || true

for f in \
    "$WORK_DIR/jobs/old1.out" \
    "$WORK_DIR/jobs/old1.out.stderr" \
    "$WORK_DIR/jobs/old1.log" \
    "$WORK_DIR/jobs/old1.out.json" \
    "$WORK_DIR/jobs/tmp1.json.abc" \
    "$WORK_DIR/jobs/finished1.json" \
    "$WORK_DIR/sub_jobs/sub1.out" \
    "$WORK_DIR/sub_jobs/subdone.json"
do
    [ ! -e "$f" ] || fail "orphan tmpfs job file was not cleaned without find: $f"
done

# 5. telegram/notifications.uc: drops non-retryable HTTP 400 notice cleanly on drain
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
echo '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}'
exit 0
SH
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/uci_tg_state" <<'EOF'
tachyon.settings=settings
tachyon.settings.config_path=/nonexistent
EOF

env -i PATH="$WORK_DIR/bin:$PATH" HOME="$WORK_DIR" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_tg_state" \
    TACHYON_TELEGRAM_OUTBOX="$WORK_DIR/outbox" \
    ucode -L "$TACHYON_LIB" -e '
        let notif = require("service.telegram.notifications");
        if (!notif.submit("123456:TESTTOKEN", "1001", "hello", "HTML")) {
            warn("submit failed\n"); exit(1);
        }
        notif.drain("123456:TESTTOKEN");
    ' || fail "telegram notifications check failed"

remaining_notices=$(find "$WORK_DIR/outbox" -maxdepth 1 -name 'notice.*.json' 2>/dev/null | wc -l)
[ "$remaining_notices" -eq 0 ] || fail "expected 400 notice to be purged from outbox, found $remaining_notices"

# 6. parental_quota.uc: scans ip neigh once per tick regardless of profile/device count
: > "$WORK_DIR/ip_calls.log"
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
echo "$*" >> "$TACHYON_IP_CALLS"
if [ "$1" = "neigh" ]; then
    echo "192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE"
    echo "192.168.1.51 dev br-lan lladdr aa:bb:cc:dd:ee:02 REACHABLE"
fi
exit 0
SH
chmod +x "$WORK_DIR/bin/ip"

cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/uci_pq_state" <<'EOF'
tachyon.prof1=profile
tachyon.prof1.enabled=1
tachyon.prof1.daily_quota_minutes=60
tachyon.prof1.device_ip=192.168.1.50
tachyon.prof2=profile
tachyon.prof2.enabled=1
tachyon.prof2.daily_quota_minutes=60
tachyon.prof2.device_ip=192.168.1.51
tachyon.prof3=profile
tachyon.prof3.enabled=1
tachyon.prof3.daily_quota_minutes=60
tachyon.prof3.device_ip=aa:bb:cc:dd:ee:03
EOF

env -i PATH="$WORK_DIR/bin:$PATH" HOME="$WORK_DIR" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_pq_state" \
    TACHYON_IP_CALLS="$WORK_DIR/ip_calls.log" \
    PARENTAL_QUOTA_STATE_FILE="$WORK_DIR/run/pq.json" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/parental_quota.uc" tick >/dev/null 2>&1 || fail "parental_quota tick failed"

neigh_count=$(grep -c '^neigh show$' "$WORK_DIR/ip_calls.log" || true)
[ "$neigh_count" -eq 1 ] || fail "expected 1 ip neigh show per tick across 3 devices, got $neigh_count"

# 7. agent_mcp.uc: reads JSON-RPC requests line-by-line (no stdin.read("all"))
mcp_resp="$(printf '{"jsonrpc":"2.0","id":7,"method":"ping"}\n' | \
    env -i PATH="$PATH" HOME="$WORK_DIR" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_tg_state" \
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/agent_mcp.uc")"
printf '%s' "$mcp_resp" | grep -qE '"id":[[:space:]]*7' || fail "agent_mcp did not respond to line-delimited ping: $mcp_resp"

echo "PASS: memory_and_cpu_leaks checks passed"
