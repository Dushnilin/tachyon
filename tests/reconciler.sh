#!/usr/bin/env bash
# tests/reconciler.sh
# Tests for service/reconciler.uc: desired vs actual state diffing,
# granular subsystem remediation, event trigger mapping, and CLI interface.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_DIR}/tachyon/files/usr/lib"
MODULE="${LIB_DIR}/service/reconciler.uc"

echo "=== Testing Reconciler Module ==="

# 1. Syntax check
echo "1. Checking ucode syntax..."
ucode -c "${MODULE}"
ucode -S -c "${MODULE}"
echo "PASS: ucode syntax clean"

# 2. Built-in selftest
echo "2. Running built-in selftest..."
ucode -L "${LIB_DIR}" "${MODULE}" selftest
echo "PASS: built-in selftest passed"

# 3. CLI commands execution and JSON validity
echo "3. Testing CLI commands..."

desired_out=$(ucode -L "${LIB_DIR}" "${MODULE}" desired)
echo "${desired_out}" | grep -q '"engine"' || { echo "FAIL: desired CLI output missing engine"; exit 1; }
echo "${desired_out}" | grep -q '"dns"' || { echo "FAIL: desired CLI output missing dns"; exit 1; }
echo "${desired_out}" | grep -q '"nftables"' || { echo "FAIL: desired CLI output missing nftables"; exit 1; }
echo "${desired_out}" | grep -q '"routing"' || { echo "FAIL: desired CLI output missing routing"; exit 1; }
echo "${desired_out}" | grep -q '"daemons"' || { echo "FAIL: desired CLI output missing daemons"; exit 1; }
echo "PASS: desired CLI output valid"

actual_out=$(ucode -L "${LIB_DIR}" "${MODULE}" actual)
echo "${actual_out}" | grep -q '"engine"' || { echo "FAIL: actual CLI output missing engine"; exit 1; }
echo "${actual_out}" | grep -q '"dns"' || { echo "FAIL: actual CLI output missing dns"; exit 1; }
echo "${actual_out}" | grep -q '"nftables"' || { echo "FAIL: actual CLI output missing nftables"; exit 1; }
echo "${actual_out}" | grep -q '"routing"' || { echo "FAIL: actual CLI output missing routing"; exit 1; }
echo "${actual_out}" | grep -q '"daemons"' || { echo "FAIL: actual CLI output missing daemons"; exit 1; }
echo "PASS: actual CLI output valid"

plan_out=$(ucode -L "${LIB_DIR}" "${MODULE}" plan)
echo "${plan_out}" | grep -q '"drifts"' || { echo "FAIL: plan CLI output missing drifts"; exit 1; }
echo "${plan_out}" | grep -q '"actions_by_subsystem"' || { echo "FAIL: plan CLI output missing actions_by_subsystem"; exit 1; }
echo "PASS: plan CLI output valid"

status_out=$(ucode -L "${LIB_DIR}" "${MODULE}" status)
echo "${status_out}" | grep -q '"drift_count"' || { echo "FAIL: status CLI output missing drift_count"; exit 1; }
echo "PASS: status CLI output valid"

# 4. Programmatic unit tests for State Diffing & Granular Logic
echo "4. Running programmatic unit tests for diffing & event mappings..."
ucode -L "${LIB_DIR}" -e '
let reconciler = require("service.reconciler");

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

// Test A: Subsystems isolation (DNS drift does NOT require engine repair)
let desired_sample = {
    engine: { should_run: true, id: "sing-box", is_steer: false },
    dns: { manage_dnsmasq: true, smartdns_needed: false, expect_resolving: true },
    nftables: { table_needed: true, table_name: "TachyonTable", sets_needed: ["localv4"] },
    routing: { needed: true, table_name: "tachyon" },
    daemons: []
};

let actual_dns_drop = {
    engine: { running: true, id: "sing-box" },
    dns: { dnsmasq_running: true, dnsmasq_managed: false, smartdns_running: false, resolving: false },
    nftables: { table_present: true, table_name: "TachyonTable", sets_present: ["localv4"], sets_missing: [], sets_empty: [] },
    routing: { rule4_present: true, rule6_present: true, route_present: true },
    daemons: []
};

let diff_dns = reconciler.diff_state(desired_sample, actual_dns_drop);
assert(!diff_dns.clean, "DNS drop must not be clean");
let subsystems_touched = {};
for (let d in diff_dns.drifts) {
    subsystems_touched[d.subsystem] = true;
}
assert(subsystems_touched["dns"] == true, "DNS subsystem must be flagged");
assert(subsystems_touched["engine"] == null, "Engine subsystem must NOT be flagged on DNS drop");
assert(subsystems_touched["nftables"] == null, "NFTables subsystem must NOT be flagged on DNS drop");
assert(subsystems_touched["routing"] == null, "Routing subsystem must NOT be flagged on DNS drop");

// Test B: Steer engine desired state verification
let steer_desired = reconciler.get_desired_state();
assert(steer_desired.timestamp > 0, "Desired state must have positive timestamp");

// Test C: Event mapping dispatch
let ev_dns = reconciler.reconcile_event("dns.down", {});
assert(ev_dns != null, "reconcile_event(dns.down) should return result object");

let ev_nft = reconciler.reconcile_event("nft.missing", {});
assert(ev_nft != null, "reconcile_event(nft.missing) should return result object");

print("All programmatic assertions passed successfully\n");
'
echo "PASS: programmatic unit tests passed"

# 5. CLI dry-run and event dispatch testing
echo "5. Testing CLI apply and event dispatch with dry-run..."
apply_cli_out=$(ucode -L "${LIB_DIR}" "${MODULE}" apply dry-run)
echo "${apply_cli_out}" | grep -q '"dry_run": true' || { echo "FAIL: apply CLI output missing dry_run: true"; exit 1; }
echo "PASS: CLI apply dry-run passed"

ev_cli_out=$(ucode -L "${LIB_DIR}" "${MODULE}" event dns.down dry-run)
echo "${ev_cli_out}" | grep -q '"dry_run": true' || { echo "FAIL: event CLI output missing dry_run: true"; exit 1; }
echo "PASS: CLI event dry-run dispatch passed"

echo "=== All Reconciler Tests Passed ==="
