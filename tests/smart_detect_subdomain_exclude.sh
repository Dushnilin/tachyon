#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$test_dir/../tachyon/files/usr/lib"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export TACHYON_RUNTIME_STATE_DIR="$work"
export TACHYON_SMART_PROBE_DIR="$work"
export TACHYON_PSL_FILE="$test_dir/../tachyon/files/usr/share/tachyon/public-suffix-list.dat"

cat > "$work/test.uc" <<'UCODE'
let fs = require('fs');
let common = require('core.common');
let smart_plus = require('service.smart_detect_plus');

let applied = [];
function smart_detect_observe_dns() { return { ready: true, signature: 'sig1' }; }
function smart_detect_get_proxy_sections() { return ['vpn']; }
function smart_detect_direct_curl_argv() { return []; }
function smart_detect_apply_domains(items) {
    for (let it in items) push(applied, it);
    return items;
}
function log_message(m, l) {}

let smart_probe = {
    start: function(r) { return { id: 'test' }; },
    poll: function(j) { return { act: true, seen: true }; },
    stop: function(j) {}
};
let controller = { proxy_port: function() { return '4534'; } };

let smart_detect_dns_state = {};
let smart_plus_seen = {};
let smart_plus_job = null;
let smart_plus_last_run = 0;
let pending_smart_plus = {};
let PENDING_SMART_DOMAINS_MAX = 500;

UCODE

awk '/^function smart_detect_plus_seen\(/ {active=1} /^function smart_detect_process_pending\(/ {exit} active {print}' "$lib/service/watchdog.uc" >> "$work/test.uc"

cat >> "$work/test.uc" <<'UCODE'
// Test 1: smart_detect_expand_to_root != "0" (default behavior expands to eTLD+1)
applied = [];
smart_plus_job = null;
smart_plus_last_run = 0;
smart_plus_seen = {};
pending_smart_plus = { 'clck.yandex.net': { queued: time(), scheme: 'https', priority: 3 } };
let cfg1 = { smart_detect: '1', smart_detect_mode: 'plus', smart_detect_sections: ['vpn'], smart_detect_expand_to_root: '1' };
smart_detect_process_plus(cfg1); // starts probe job
assert(smart_plus_job != null, 'job started for clck.yandex.net');
smart_detect_process_plus(cfg1); // polls completed probe job
assert(length(applied) == 1, 'applied 1 domain');
assert(applied[0].domain == 'yandex.net', 'default expanded to root domain yandex.net');
assert(applied[0].source_domain == 'clck.yandex.net', 'source domain preserved');

// Test 2: smart_detect_expand_to_root == "0" (keeps exact subdomain)
applied = [];
smart_plus_job = null;
smart_plus_last_run = 0;
smart_plus_seen = {};
pending_smart_plus = { 'clck.yandex.net': { queued: time(), scheme: 'https', priority: 3 } };
let cfg2 = { smart_detect: '1', smart_detect_mode: 'plus', smart_detect_sections: ['vpn'], smart_detect_expand_to_root: '0' };
smart_detect_process_plus(cfg2); // starts probe job
assert(smart_plus_job != null, 'job started for clck.yandex.net');
smart_detect_process_plus(cfg2); // polls completed probe job
assert(length(applied) == 1, 'applied 1 domain');
assert(applied[0].domain == 'clck.yandex.net', 'kept exact subdomain clck.yandex.net');
assert(applied[0].source_domain == 'clck.yandex.net', 'source domain is clck.yandex.net');

// Test 3: smart_detect_exclude drops candidate without probing or applying
applied = [];
smart_plus_job = null;
smart_plus_last_run = 0;
smart_plus_seen = {};
pending_smart_plus = { 'clck.yandex.net': { queued: time(), scheme: 'https', priority: 3 } };
let cfg3 = { smart_detect: '1', smart_detect_mode: 'plus', smart_detect_sections: ['vpn'], smart_detect_exclude: ['yandex.net'] };
smart_detect_process_plus(cfg3);
assert(smart_plus_job == null, 'excluded candidate not probed');
assert(length(applied) == 0, 'excluded candidate not applied');
assert(pending_smart_plus['clck.yandex.net'] == null, 'excluded candidate purged from queue');

// An excluded sibling prevents parent expansion, but not the safe hostname.
applied = []; smart_plus_job = null; smart_plus_last_run = 0; smart_plus_seen = {};
pending_smart_plus = { 'api.example.com': { queued: time(), scheme: 'https', priority: 3 } };
let cfg4 = { smart_detect: '1', smart_detect_mode: 'plus', smart_detect_sections: ['vpn'], smart_detect_exclude: ['cdn.example.com'] };
smart_detect_process_plus(cfg4); smart_detect_process_plus(cfg4);
assert(length(applied) == 1 && applied[0].domain == 'api.example.com', 'excluded sibling prevents broad parent rule');
// A selection changed while a probe was running is checked before apply.
applied = []; smart_plus_job = null; smart_plus_last_run = 0; smart_plus_seen = {};
pending_smart_plus = { 'api.example.com': { queued: time(), scheme: 'https', priority: 3 } };
let cfg5 = { smart_detect: '1', smart_detect_mode: 'plus', smart_detect_sections: ['vpn'] };
smart_detect_process_plus(cfg5);
cfg5.smart_detect_exclude = ['example.com'];
smart_detect_process_plus(cfg5);
assert(length(applied) == 0, 'new exclusion blocks in-flight result');
print("PASS: smart_detect_subdomain_exclude\n");
UCODE

ucode -L "$lib" "$work/test.uc"
