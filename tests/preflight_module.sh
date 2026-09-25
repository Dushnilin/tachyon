#!/bin/bash
# tests/preflight_module.sh
# Tests for core/preflight.uc: RAM, tmp, flash, package DB, architecture,
# 7-factor disk budgeting, and core.transaction integration.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_DIR}/tachyon/files/usr/lib"
MODULE="${LIB_DIR}/core/preflight.uc"

# In CI/Docker container, apk/opkg might not be installed, allow package db check to pass
export TACHYON_PREFLIGHT_ALLOW_MISSING_PKG=1

echo "=== Testing preflight module ==="

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
ram_out=$(ucode -L "${LIB_DIR}" "${MODULE}" ram 1024)
echo "${ram_out}" | grep -q '"total_kb"' || { echo "FAIL: ram CLI output missing total_kb"; exit 1; }
echo "${ram_out}" | grep -Eq '"ok":\s*true' || { echo "FAIL: ram CLI output not ok for 1MB"; exit 1; }

tmp_out=$(ucode -L "${LIB_DIR}" "${MODULE}" tmp 1024)
echo "${tmp_out}" | grep -q '"available_kb"' || { echo "FAIL: tmp CLI output missing available_kb"; exit 1; }

flash_out=$(ucode -L "${LIB_DIR}" "${MODULE}" flash 512)
echo "${flash_out}" | grep -q '"available_kb"' || { echo "FAIL: flash CLI output missing available_kb"; exit 1; }

storage_out=$(ucode -L "${LIB_DIR}" "${MODULE}" storage / 512)
echo "${storage_out}" | grep -Eq '"path":\s*"/"' || { echo "FAIL: storage CLI output missing path"; exit 1; }

arch_out=$(ucode -L "${LIB_DIR}" "${MODULE}" arch)
echo "${arch_out}" | grep -q '"arch"' || { echo "FAIL: arch CLI output missing arch"; exit 1; }

pkg_out=$(ucode -L "${LIB_DIR}" "${MODULE}" packages)
echo "${pkg_out}" | grep -q '"package_manager"' || { echo "FAIL: packages CLI output missing package_manager"; exit 1; }

all_out=$(ucode -L "${LIB_DIR}" "${MODULE}" all)
echo "${all_out}" | grep -q '"checks"' || { echo "FAIL: all CLI output missing checks"; exit 1; }

# 4. Budget CLI test
echo "4. Testing disk budget CLI calculation..."
budget_json='{"download": 2097152, "temp": 4194304, "old": 3145728, "new": 5242880, "rollback": 3145728, "metadata": 1048576, "reserve": 2097152}'
budget_out=$(ucode -L "${LIB_DIR}" "${MODULE}" budget "${budget_json}")
echo "${budget_out}" | grep -q '"budget"' || { echo "FAIL: budget CLI output missing budget object"; exit 1; }
echo "${budget_out}" | grep -q '"tmp_peak_kb"' || { echo "FAIL: budget CLI output missing tmp_peak_kb"; exit 1; }
echo "${budget_out}" | grep -q '"flash_peak_kb"' || { echo "FAIL: budget CLI output missing flash_peak_kb"; exit 1; }
echo "PASS: CLI tests passed"

# 5. Programmatic API & Transaction engine integration test
echo "5. Testing programmatic API and core.transaction integration..."
TEST_DIR=$(mktemp -d /tmp/tachyon_preflight_test_XXXXXX)
trap 'rm -rf "${TEST_DIR}"' EXIT

export TACHYON_RUNTIME_STATE_DIR="${TEST_DIR}/state"
export TACHYON_CONFIG_DIR="${TEST_DIR}/config"
mkdir -p "${TACHYON_RUNTIME_STATE_DIR}" "${TACHYON_CONFIG_DIR}"

ucode -L "${LIB_DIR}" -e '
let preflight = require("core.preflight");
let transaction = require("core.transaction");

// Test A: 7-factor calculation correctness
let calc = preflight.calculate_disk_budget({
    download: 1048576, // 1024 KB
    temp: 2097152,     // 2048 KB
    old: 1048576,      // 1024 KB
    new: 3145728,      // 3072 KB
    rollback: 1048576, // 1024 KB
    metadata: 524288,  // 512 KB
    reserve: 1048576   // 1024 KB
});

if (calc.download_kb != 1024 || calc.temp_kb != 2048 || calc.rollback_kb != 1024 || calc.reserve_kb != 1024) {
    warn("FAIL: component KB calculations incorrect\n");
    exit(1);
}
// tmp_peak = 1024 + 2048 + 1024 + 1024 = 5120
if (calc.tmp_peak_kb != 5120) {
    warn("FAIL: tmp_peak_kb mismatch: expected 5120, got " + calc.tmp_peak_kb + "\n");
    exit(1);
}
// flash_peak = old(1024) + new(3072) + metadata(512) + reserve(1024) = 5632
if (calc.flash_peak_kb != 5632) {
    warn("FAIL: flash_peak_kb mismatch: expected 5632, got " + calc.flash_peak_kb + "\n");
    exit(1);
}
// flash_net = new(3072) - old(1024) + metadata(512) = 2560
if (calc.flash_net_kb != 2560) {
    warn("FAIL: flash_net_kb mismatch: expected 2560, got " + calc.flash_net_kb + "\n");
    exit(1);
}

// Test B: Integration with transaction engine (happy path)
let executed_mutate = false;
let res = transaction.run("preflight_happy_tx", {
    preflight: preflight.preflight_validator({
        ram: { min_available_kb: 512 },
        tmp: { min_free_kb: 512 },
        flash: { min_free_kb: 512 },
        ignore_package_lock: true
    }),
    mutate: function(tx) {
        executed_mutate = true;
    }
});
if (!res.ok || !executed_mutate) {
    warn("FAIL: transaction should commit when preflight passes\n");
    exit(1);
}

// Test C: Integration with transaction engine (failing preflight aborts before mutate)
let executed_unwanted_mutate = false;
let res_fail = transaction.run("preflight_fail_tx", {
    preflight: preflight.preflight_validator({
        ram: { min_available_kb: 999999999 } // impossibly high requirement
    }),
    mutate: function(tx) {
        executed_unwanted_mutate = true;
    }
});
if (res_fail.ok || executed_unwanted_mutate) {
    warn("FAIL: transaction should fail and abort before MUTATE when preflight fails\n");
    exit(1);
}

print("PASS: API and transaction integration verified\n");
'

echo "=== All preflight module tests passed successfully ==="
exit 0
