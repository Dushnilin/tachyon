#!/usr/bin/env bash
# Per-domain silent-drop strike tracker (smart_detect_plus.silent_drops):
#   - counts direct connections (tproxy/tun/redirect -> direct-out) with
#     upload > 30B and download == 0 across distinct socket retries
#   - ignores tiny uploads (<= 30B) and sub-1200ms transient sockets
#   - resets strikes immediately if any connection to the domain receives bytes
#   - emits a priority-3 candidate on the 3rd strike
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"

out="$(ucode -L "$TACHYON_LIB" -e '
let module = require("service.smart_detect_plus");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }

check(type(module.silent_drops) == "function", "silent_drops is exported");

function conn(id, host, upload, download, inbound, duration_ms) {
    let c = {
        id: id,
        metadata: {
            host: host,
            network: "tcp",
            type: inbound || "tproxy/tproxy-in",
            destinationPort: "443"
        },
        upload: upload,
        download: download,
        chains: [ "direct-out" ]
    };
    if (duration_ms != null)
        c.duration_ms = duration_ms;
    return c;
}

// 1. Sub-30B upload (TCP SYN / empty preconnect) or sub-1200ms duration does not count
let r0 = module.silent_drops({}, [
    conn("c0", "blocked.example.com", 20, 0, "tproxy/tproxy-in", 2000),
    conn("c0b", "blocked.example.com", 500, 0, "tproxy/tproxy-in", 800)
], 100);
check(length(r0.domains) == 0 && r0.state["blocked.example.com"] == null,
      "sub-30B upload and sub-1200ms attempts are ignored");

// 2. Three distinct zero-reply attempts (across tproxy and tun) trigger candidate on 3rd strike
let r1 = module.silent_drops({}, [ conn("c1", "blocked.example.com", 517, 0, "tproxy/tproxy-in", 1500) ], 100);
check(length(r1.domains) == 0, "1st strike does not emit yet");
let r2 = module.silent_drops(r1.state, [ conn("c2", "blocked.example.com", 517, 0, "tun/tun-in", 1800) ], 105);
check(length(r2.domains) == 0, "2nd strike does not emit yet");
// Duplicate poll of same conn.id must not double-count
let r2_dup = module.silent_drops(r2.state, [ conn("c2", "blocked.example.com", 517, 0, "tun/tun-in", 2500) ], 108);
check(length(r2_dup.domains) == 0, "same conn.id is not counted twice");
let r3 = module.silent_drops(r2_dup.state, [ conn("c3", "blocked.example.com", 517, 0, "redirect/redirect-in", 1600) ], 112);
check(r3.domains["blocked.example.com"] == "https" && r3.priorities["blocked.example.com"] == 3,
      "3rd distinct silent-drop attempt emits priority-3 https candidate");

// 3. Any successful download resets accumulated strikes
let s1 = module.silent_drops({}, [
    conn("d1", "alive.example.com", 400, 0, "tproxy/tproxy-in", 1500),
    conn("d2", "alive.example.com", 400, 0, "tproxy/tproxy-in", 1500)
], 200);
let s2 = module.silent_drops(s1.state, [
    conn("d3", "alive.example.com", 400, 1024, "tproxy/tproxy-in", 1500),
    conn("d4", "alive.example.com", 400, 0, "tproxy/tproxy-in", 1500)
], 205);
check(length(s2.domains) == 0 && s2.state["alive.example.com"].count == 1,
      "download > 0 clears previous strikes before counting new ones");

print(sprintf("PASS: %d silent_drops checks\n", checks));
' 2>&1)" || fail "silent_drops checks failed: $out"

echo "$out" | grep -q "^PASS:" || fail "silent_drops did not report PASS"

grep -Fq 'smart_plus.silent_drops(' "$CONTROLLER_UC" ||
  fail "event_controller.uc does not call smart_plus.silent_drops"

printf 'Silent drop checks passed\n'
