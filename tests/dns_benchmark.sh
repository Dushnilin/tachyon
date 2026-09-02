#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
BENCHMARK="$TACHYON_LIB/dns/benchmark.uc"
BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ─── 1. Syntax check & module load ──────────────────────────────────────────
ucode -L "$TACHYON_LIB" -c "$BENCHMARK" || fail "benchmark.uc must pass ucode syntax check"
ucode -S -L "$TACHYON_LIB" -c "$BENCHMARK" || fail "benchmark.uc must pass strict ucode syntax check"

# ─── 2. Test candidate pool and structure ───────────────────────────────────
cat >"$WORK_DIR/test_candidates.uc" <<'UCODE'
let benchmark = require("dns.benchmark");

let candidates = benchmark.CANDIDATE_SERVERS;
if (type(candidates) != "array" || length(candidates) < 8) {
    print("ERR: candidate servers array invalid or too small\n");
    exit(1);
}

let has_udp = false;
let has_doh = false;
let has_yandex = false;
let has_cf = false;

for (let c in candidates) {
    if (c.type == "udp") has_udp = true;
    if (c.type == "doh") has_doh = true;
    if (c.provider == "Yandex") has_yandex = true;
    if (c.provider == "Cloudflare") has_cf = true;
}

if (!has_udp || !has_doh) {
    print("ERR: must contain both UDP and DoH servers\n");
    exit(2);
}

if (!has_yandex || !has_cf) {
    print("ERR: must contain Yandex and Cloudflare servers\n");
    exit(3);
}

print("OK\n");
exit(0);
UCODE

ucode -L "$TACHYON_LIB" "$WORK_DIR/test_candidates.uc" | grep -q "OK" ||
  fail "benchmark.uc candidate server pool validation failed"

# ─── 3. Test Recommendation Calculation ─────────────────────────────────────
cat >"$WORK_DIR/test_recommendation.uc" <<'UCODE'
let benchmark = require("dns.benchmark");

// Scenario A: Fast DoH (<85ms, close to UDP) -> Expect DoH recommended
let results_a = [
    { id: "yandex_udp", provider: "Yandex", type: "udp", address: "77.88.8.8", ip: "77.88.8.8", latency: 15, lossPct: 0, status: "excellent", score: 15 },
    { id: "cf_udp", provider: "Cloudflare", type: "udp", address: "1.1.1.1", ip: "1.1.1.1", latency: 20, lossPct: 0, status: "excellent", score: 20 },
    { id: "cf_doh", provider: "Cloudflare", type: "doh", address: "https://cloudflare-dns.com/dns-query", ip: "1.1.1.1", latency: 25, lossPct: 0, status: "excellent", score: 25 }
];

let rec_a = benchmark.compute_recommendation(results_a);
if (rec_a.dns_type != "doh") {
    print("ERR: Scenario A should recommend DoH, got ", rec_a.dns_type, "\n");
    exit(1);
}
if (rec_a.bootstrap_dns_server[0] != "77.88.8.8") {
    print("ERR: Scenario A bootstrap DNS should be fastest UDP (77.88.8.8)\n");
    exit(2);
}
if (rec_a.dns_fallback_server[0] != "1.1.1.1") {
    print("ERR: Scenario A fallback DNS should be secondary provider (1.1.1.1)\n");
    exit(3);
}

// Scenario B: Blocked/slow DoH -> Expect UDP recommended
let results_b = [
    { id: "yandex_udp", provider: "Yandex", type: "udp", address: "77.88.8.8", ip: "77.88.8.8", latency: 18, lossPct: 0, status: "excellent", score: 18 },
    { id: "cf_udp", provider: "Cloudflare", type: "udp", address: "1.1.1.1", ip: "1.1.1.1", latency: 35, lossPct: 0, status: "good", score: 35 },
    { id: "cf_doh", provider: "Cloudflare", type: "doh", address: "https://cloudflare-dns.com/dns-query", ip: "1.1.1.1", latency: 350, lossPct: 50, status: "slow", score: 600 }
];

let rec_b = benchmark.compute_recommendation(results_b);
if (rec_b.dns_type != "udp" || rec_b.dns_server[0] != "77.88.8.8") {
    print("ERR: Scenario B should recommend UDP 77.88.8.8\n");
    exit(4);
}

// Scenario C: All failed -> Expect safe failsafe fallback
let results_c = [];
let rec_c = benchmark.compute_recommendation(results_c);
if (rec_c.dns_type != "udp" || rec_c.dns_server[0] != "77.88.8.8" || rec_c.dns_fallback_server[0] != "1.1.1.1") {
    print("ERR: Scenario C failsafe failed\n");
    exit(5);
}

print("OK\n");
exit(0);
UCODE

ucode -L "$TACHYON_LIB" "$WORK_DIR/test_recommendation.uc" | grep -q "OK" ||
  fail "compute_recommendation logic tests failed"

# ─── 4. Test CLI help & command registration in /usr/bin/tachyon ─────────────
grep -Fq "dns_benchmark" "$BIN" || fail "/usr/bin/tachyon must register dns_benchmark"
grep -Fq "dns_autotune" "$BIN" || fail "/usr/bin/tachyon must register dns_autotune"
grep -Fq "dns_benchmark_async" "$BIN" || fail "/usr/bin/tachyon must register dns_benchmark_async"
grep -Fq "dns_benchmark_status" "$BIN" || fail "/usr/bin/tachyon must register dns_benchmark_status"
grep -Fq "dns_benchmark_stop" "$BIN" || fail "/usr/bin/tachyon must register dns_benchmark_stop"
grep -Fq "dns_benchmark_apply" "$BIN" || fail "/usr/bin/tachyon must register dns_benchmark_apply"

printf 'PASS: dns_benchmark\n'
