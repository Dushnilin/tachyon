#!/usr/bin/env bash
# The OOM healer must act on who the kernel killed, not on the word "OOM".
#
# Checked here: oom_report/oom_response decisions against real dmesg samples
# and heal_oom's non-restarting structure.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
[ -f "$WATCHDOG_UC" ] || fail "missing $WATCHDOG_UC"

uc() { command ucode -L "$TACHYON_LIB" "$@"; }

cat >"$WORK_DIR/decide.uc" <<'UCODE'
let oom = require("service.oom_report");
let errors = [];
let note = function(m) { push(errors, m); };
let check = function(label, got, want) {
    if (got != want) note(label + ": got " + sprintf("%J", got) + ", want " + sprintf("%J", want));
};

// Abridged from the router's dmesg.
let memcg = join("\n", [
    "[408668.451740] 4-chrome-macos invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=500",
    "[408668.462245] memory: usage 131088kB, limit 131072kB, failcnt 543",
    "[408668.477706] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=7f3f7fab6ed1,mems_allowed=0,oom_memcg=/docker/7f3f7fab6ed1,task=urusai,pid=15410,uid=0",
    "[408668.480046] Memory cgroup out of memory: Killed process 15410 (urusai) total-vm:148248kB, anon-rss:130096kB, file-rss:0kB"
]);
let r = oom.oom_report(memcg);
check("memcg complete", r.complete, true);
check("memcg victim", r.victim, "urusai");
check("memcg flag", r.memcg, true);
check("container OOM, native core", oom.oom_response(r), "report");

// What the healer saw at the time: the first line only.
let early = split(memcg, "\n")[0];
r = oom.oom_report(early);
check("report still being printed", r.complete, false);
check("incomplete report is not a restart", oom.oom_response(r), "report");

// Host OOM that killed tachyon-core: procd respawns it without full Tachyon restart.
let host_native = "[1.0] tachyon-core invoked oom-killer: gfp_mask=0x140cca\n" +
    "[1.1] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=tachyon-core,pid=8212,uid=0\n" +
    "[1.2] Out of memory: Killed process 8212 (tachyon-core) total-vm:300000kB, anon-rss:250000kB";
r = oom.oom_report(host_native);
check("core victim", r.victim, "tachyon-core");
check("core memcg", r.memcg, false);
check("native core killed: procd respawns", oom.oom_response(r), "respawn");

// Core killed inside a cgroup is still the core.
let memcg_core = oom.oom_report(replace(memcg, /urusai/g, "tachyon-core"));
check("core in a cgroup", oom.oom_response(memcg_core), "respawn");

// Another process killed on the host.
let host_other = replace(host_native, /tachyon-core/g, "dnsmasq");
check("other victim, native core", oom.oom_response(oom.oom_report(host_other)), "report");

// The newest report decides: an old complete one followed by a fresh,
// still-printing one is incomplete, not the old victim.
r = oom.oom_report(host_native + "\n[9.0] foo invoked oom-killer: gfp_mask=0x0");
check("newest report wins", r.complete, false);
check("newest report victim", r.victim, null);

check("no OOM in the log", oom.oom_report("[1.0] nothing here").complete, false);

if (length(errors) > 0) { for (let e in errors) print(e + "\n"); exit(1); }
print("decisions ok\n");
UCODE
out="$(uc "$WORK_DIR/decide.uc" 2>&1)" || fail "OOM decisions:
$out"
printf '%s\n' "$out"

body="$(sed -n '/^function heal_oom/,/^}/p' "$WATCHDOG_UC" | grep -v '^[[:space:]]*//')"
[ -n "$body" ] || fail "heal_oom not found"
grep -q 'oom_report_mod.oom_response(' <<<"$body" || fail "heal_oom must use oom_report_mod.oom_response"
grep -q 'read_oom_report()' <<<"$body" || fail "heal_oom must wait for the complete kernel report"
! grep -qE 'write_state_file|tachyon restart' <<<"$body" ||
  fail "heal_oom must never write mem_scale or restart Tachyon"

printf 'PASS: watchdog_oom_victim\n'
