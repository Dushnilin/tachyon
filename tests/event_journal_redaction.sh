#!/bin/bash
# tests/event_journal_redaction.sh
# Tests for core/events.uc: bounded ring journal, secret redaction,
# structured event schema, and event bus integration.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_DIR}/tachyon/files/usr/lib"
MODULE="${LIB_DIR}/core/events.uc"

echo "=== Testing event journal & secret redaction ==="

# 1. Syntax check
echo "1. Checking ucode syntax..."
ucode -c "${MODULE}"
ucode -S -c "${MODULE}"
echo "PASS: ucode syntax clean"

# 2. Built-in selftest
echo "2. Running built-in selftest..."
selftest_out=$(ucode -L "${LIB_DIR}" "${MODULE}" selftest)
[ "${selftest_out}" = "ok" ] || { echo "FAIL: selftest did not output ok: ${selftest_out}"; exit 1; }
echo "PASS: built-in selftest passed"

# 3. Dedicated temporary test environment
TEST_DIR=$(mktemp -d /tmp/tachyon_journal_test_XXXXXX)
trap 'rm -rf "${TEST_DIR}"' EXIT

JOURNAL_FILE="${TEST_DIR}/events.jsonl"
export TACHYON_EVENT_JOURNAL_PATH="${JOURNAL_FILE}"
export TACHYON_RUNTIME_STATE_DIR="${TEST_DIR}"

# 4. Programmatic Secret Redaction Tests
echo "3. Testing comprehensive secret redaction..."
ucode -L "${LIB_DIR}" -e '
let events = require("core.events");
let redact = events.redact;
let redact_string = events.redact_string;

// A. Key-based redaction in objects
let sensitive_keys = [
    "password", "secret", "token", "auth", "api_key",
    "bot_token", "private_key", "credential", "cookie",
    "access_token", "refresh_token"
];
for (let k in sensitive_keys) {
    let obj = {};
    obj[k] = "leak_attempt_value_12345";
    let res = redact(obj);
    if (res[k] != "[REDACTED]") {
        warn("FAIL: key " + k + " was not redacted\n");
        exit(1);
    }
}

// B. Non-sensitive keys preserved
let safe_obj = { user: "operator", mode: "tproxy", count: 42, enabled: true };
let safe_res = redact(safe_obj);
if (safe_res.user != "operator" || safe_res.count != 42 || safe_res.enabled != true) {
    warn("FAIL: safe keys were modified\n");
    exit(1);
}

// C. Nested structures and arrays
let nested = {
    subsystem: "telegram",
    config: {
        bot_token: "123456789:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567",
        chat_id: "987654321",
        headers: [
            { name: "Authorization", value: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xyz" },
            { name: "Content-Type", value: "application/json" }
        ]
    }
};
let nested_res = redact(nested);
if (nested_res.config.bot_token != "[REDACTED]") {
    warn("FAIL: nested bot_token not redacted\n");
    exit(1);
}
if (nested_res.config.chat_id != "987654321") {
    warn("FAIL: non-sensitive chat_id was altered\n");
    exit(1);
}
if (index(nested_res.config.headers[0].value, "eyJhbGci") >= 0) {
    warn("FAIL: Bearer token in array header not redacted\n");
    exit(1);
}
if (nested_res.config.headers[1].value != "application/json") {
    warn("FAIL: Content-Type header modified\n");
    exit(1);
}

// D. Proxy URL redaction
let urls = [
    { in: "vless://11111111-2222-3333-4444-555555555555@edge.example.com:443?type=tcp", uuid: "11111111-2222-3333-4444-555555555555" },
    { in: "trojan://mypassword123@proxy.org:8443", pass: "mypassword123" },
    { in: "https://admin:super_secret_pw@api.example.com/v1", pass: "super_secret_pw" }
];
for (let item in urls) {
    let out = redact_string(item.in);
    if (item.uuid && index(out, item.uuid) >= 0) {
        warn("FAIL: UUID leaked in URL: " + out + "\n");
        exit(1);
    }
    if (item.pass && index(out, item.pass) >= 0) {
        warn("FAIL: Password leaked in URL: " + out + "\n");
        exit(1);
    }
    if (index(out, "[REDACTED") < 0) {
        warn("FAIL: Expected redaction placeholder in URL: " + out + "\n");
        exit(1);
    }
}

// E. Telegram token in log message
let msg = "Webhook error from Telegram bot 9876543210:ABCdef-GHIjkl_MNOpqrsTUVwxyz1234567: unauthorized";
let msg_clean = redact_string(msg);
if (index(msg_clean, "9876543210:") >= 0) {
    warn("FAIL: Raw bot token present in message\n");
    exit(1);
}
if (index(msg_clean, "[REDACTED_TELEGRAM_TOKEN]") < 0) {
    warn("FAIL: Redaction marker missing from message\n");
    exit(1);
}

print("PASS: secret redaction tests\n");
'
echo "PASS: secret redaction verified"

# 5. Bounded Journal & Schema Verification
echo "4. Testing bounded journal recording, query & schema..."
ucode -L "${LIB_DIR}" -e '
let events = require("core.events");
let j_path = getenv("TACHYON_EVENT_JOURNAL_PATH");
let j = events.journal({
    path: j_path,
    max_entries: 20,
    max_bytes: 4096
});

// A. Record structured events
let ev1 = j.record("transaction.start", { tx_id: "tx_001", password: "plain" }, {
    severity: "info",
    source: "core.transaction",
    job_id: "job_99",
    correlation_id: "corr_42",
    message: "Transaction started"
});

if (ev1.event != "transaction.start" || ev1.severity != "info" || ev1.source != "core.transaction") {
    warn("FAIL: event schema fields mismatch\n");
    exit(1);
}
if (ev1.job_id != "job_99" || ev1.correlation_id != "corr_42") {
    warn("FAIL: correlation IDs mismatch\n");
    exit(1);
}
if (ev1.ts <= 0 || ev1.ms <= 0) {
    warn("FAIL: timestamps missing or non-positive\n");
    exit(1);
}
if (ev1.data.password != "[REDACTED]") {
    warn("FAIL: journal did not auto-redact data.password\n");
    exit(1);
}

// B. Query filtering
j.record("dns.failure", { domain: "blocked.com" }, { severity: "error", source: "watchdog", message: "DNS failure" });
j.record("service.reload", { subsystem: "nft" }, { severity: "warn", source: "reconciler", message: "Reloading rules" });

let all_entries = j.query();
if (length(all_entries) != 3) {
    warn("FAIL: expected 3 entries, got " + length(all_entries) + "\n");
    exit(1);
}
// Newest first by default
if (all_entries[0].event != "service.reload") {
    warn("FAIL: newest entry should be first\n");
    exit(1);
}

// Filter by severity
let error_only = j.query({ severity: "error" });
if (length(error_only) != 1 || error_only[0].event != "dns.failure") {
    warn("FAIL: severity filtering failed\n");
    exit(1);
}

// Filter by source
let tx_only = j.query({ source: "core.transaction" });
if (length(tx_only) != 1 || tx_only[0].job_id != "job_99") {
    warn("FAIL: source filtering failed\n");
    exit(1);
}

// Search filter
let search_res = j.query({ search: "DNS failure" });
if (length(search_res) != 1 || search_res[0].event != "dns.failure") {
    warn("FAIL: search filtering failed\n");
    exit(1);
}

// C. Tail
let tail_res = j.tail(2);
if (length(tail_res) != 2) {
    warn("FAIL: tail(2) should return 2 entries\n");
    exit(1);
}

// D. Bounded ring buffer compaction
for (let i = 0; i < 50; i++) {
    j.record("flood.event", { idx: i }, { message: "flood entry " + i });
}
let stats_after = j.stats();
if (stats_after.count > 20) {
    warn("FAIL: journal entries count " + stats_after.count + " exceeds max_entries 20\n");
    exit(1);
}
if (stats_after.size_bytes > 4096) {
    warn("FAIL: journal size " + stats_after.size_bytes + " exceeds max_bytes 4096\n");
    exit(1);
}

print("PASS: bounded journal and schema verified\n");
'
echo "PASS: journal schema and bounds verified"

# 6. Event Bus Integration with Journal
echo "5. Testing Event Bus integration with Journal..."
ucode -L "${LIB_DIR}" -e '
let events = require("core.events");
let j_path = getenv("TACHYON_EVENT_JOURNAL_PATH");
let j = events.journal({ path: j_path, max_entries: 50 });
j.clear();

let b = events.bus({ journal: j });
let handled = 0;
b.on("network.up", function(ev) {
    handled++;
});

b.emit("network.up", {
    interface: "wan",
    token: "leaked_secret_token",
    severity: "info",
    source: "netifd",
    message: "WAN interface is up"
});

if (handled != 1) {
    warn("FAIL: event handler was not invoked\n");
    exit(1);
}

let journaled = j.query({ event: "network.up" });
if (length(journaled) != 1) {
    warn("FAIL: event was not auto-recorded to journal via bus\n");
    exit(1);
}
if (journaled[0].data.token != "[REDACTED]") {
    warn("FAIL: bus-emitted event token was not redacted in journal\n");
    exit(1);
}
if (journaled[0].source != "netifd") {
    warn("FAIL: metadata source was not captured\n");
    exit(1);
}

print("PASS: bus and journal integration verified\n");
'
echo "PASS: bus and journal integration verified"

# 7. CLI Subcommands Test
echo "6. Testing CLI subcommands..."
ucode -L "${LIB_DIR}" "${MODULE}" clear
clear_stats=$(ucode -L "${LIB_DIR}" "${MODULE}" stats)
echo "${clear_stats}" | grep -Eq '"count":\s*0' || { echo "FAIL: stats after clear missing count 0"; exit 1; }

rec_out=$(ucode -L "${LIB_DIR}" "${MODULE}" record "cli.test" '{"password":"123","ok":true}' "info" "cli" "cli test message")
echo "${rec_out}" | grep -Eq '"event":\s*"cli.test"' || { echo "FAIL: record CLI output missing event"; exit 1; }
echo "${rec_out}" | grep -Eq '"password":\s*"\[REDACTED\]"' || { echo "FAIL: record CLI did not redact password"; exit 1; }

query_out=$(ucode -L "${LIB_DIR}" "${MODULE}" query '{"event":"cli.test"}')
echo "${query_out}" | grep -Eq '"cli.test"' || { echo "FAIL: query CLI missing recorded event"; exit 1; }

tail_out=$(ucode -L "${LIB_DIR}" "${MODULE}" tail 1)
echo "${tail_out}" | grep -Eq '"cli.test"' || { echo "FAIL: tail CLI missing recorded event"; exit 1; }

redact_cli_out=$(ucode -L "${LIB_DIR}" "${MODULE}" redact '{"secret":"my_key","user":"alice"}')
echo "${redact_cli_out}" | grep -Eq '"secret":\s*"\[REDACTED\]"' || { echo "FAIL: redact CLI did not redact secret"; exit 1; }
echo "${redact_cli_out}" | grep -Eq '"user":\s*"alice"' || { echo "FAIL: redact CLI did not preserve user"; exit 1; }

echo "=== All event journal and secret redaction tests passed successfully ==="
exit 0
