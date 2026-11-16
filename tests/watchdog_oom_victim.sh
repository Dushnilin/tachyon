#!/usr/bin/env bash
# The OOM healer must act on who the kernel killed, not on the word "OOM".
#
# heal_oom() shrank GOMEMLIMIT and ran a full `tachyon restart` on any kernel
# OOM line. On a router running the native core and a docker container, the
# container hit its own memory-cgroup limit ("Memory cgroup out of memory:
# Killed process ... (urusai)"); the healer restarted Tachyon, and with a
# fail-closed section the LAN stayed blocked through the restart (~17 minutes
# there, most of it the bypass pre-resolution stall). GOMEMLIMIT does nothing
# for the native core, and the router never ran out of memory.
#
# The healer also reacted 16 ms before the kernel printed the victim, so the
# report has to be read until it is complete.
#
# Checked here: the decisions through the real module, against the kernel log
# from that router; the event payload; and the healer's order of checks.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"
[ -f "$WATCHDOG_UC" ] || fail "missing $WATCHDOG_UC"

uc() { command ucode -L "$TACHYON_LIB" "$@"; }

cat >"$WORK_DIR/decide.uc" <<'UCODE'
let oom = require("service.oom_scale");
let errors = [];
let note = function(m) { push(errors, m); };
let check = function(label, got, want) {
    if (got != want) note(label + ": got " + sprintf("%J", got) + ", want " + sprintf("%J", want));
};

// Abridged from the router's dmesg.
let memcg = join("\n", [
    "[408668.451740] 4-chrome-macos invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=500",
    "[408668.462245] memory: usage 131088kB, limit 131072kB, failcnt 543",
    "[408668.464031] tachyon: [err] Watchdog: OOM event detected from syslog! Reducing GOMEMLIMIT scaling...",
    "[408668.477706] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=7f3f7fab6ed1,mems_allowed=0,oom_memcg=/docker/7f3f7fab6ed1,task=urusai,pid=15410,uid=0",
    "[408668.480046] Memory cgroup out of memory: Killed process 15410 (urusai) total-vm:148248kB, anon-rss:130096kB, file-rss:0kB"
]);
let r = oom.oom_report(memcg);
check("memcg complete", r.complete, true);
check("memcg victim", r.victim, "urusai");
check("memcg flag", r.memcg, true);
check("container OOM, native core", oom.oom_response(r, false), "report");
check("container OOM, Go core", oom.oom_response(r, true), "report");

// What the healer saw at the time: the first line only.
let early = split(memcg, "\n")[0];
r = oom.oom_report(early);
check("report still being printed", r.complete, false);
check("incomplete report is not a restart", oom.oom_response(r, false), "report");

// Host OOM that killed the core. Every sing-box build is installed as
// /usr/bin/tachyon-core, so the name cannot say Go or native - go_core does.
let host_native = "[1.0] tachyon-core invoked oom-killer: gfp_mask=0x140cca\n" +
    "[1.1] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=tachyon-core,pid=8212,uid=0\n" +
    "[1.2] Out of memory: Killed process 8212 (tachyon-core) total-vm:300000kB, anon-rss:250000kB";
r = oom.oom_report(host_native);
check("core victim", r.victim, "tachyon-core");
check("core memcg", r.memcg, false);
check("native core killed: procd respawns", oom.oom_response(r, false), "respawn");
check("Go build under the tachyon-core name keeps the old cure", oom.oom_response(r, true), "shrink");

// The legacy sing-box name is the core as well.
let host_legacy = oom.oom_report(replace(host_native, /tachyon-core/g, "sing-box"));
check("legacy name, native", oom.oom_response(host_legacy, false), "respawn");
check("legacy name, Go", oom.oom_response(host_legacy, true), "shrink");

// A core killed inside a cgroup is still the core.
let memcg_core = oom.oom_report(replace(memcg, /urusai/g, "tachyon-core"));
check("core in a cgroup, Go", oom.oom_response(memcg_core, true), "shrink");

// Another process killed on the host.
let host_other = replace(host_native, /tachyon-core/g, "dnsmasq");
check("other victim, native core", oom.oom_response(oom.oom_report(host_other), false), "report");
check("other victim, Go core", oom.oom_response(oom.oom_report(host_other), true), "shrink");

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

# --- the event carries whether the Go runtime itself ran out ---
payload() {
  local tmp="$WORK_DIR/payload.uc"
  cat >"$tmp" <<UCODE
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
let c = ec.controller(b, {});
let got = "none";
b.on("oom.detected", function(ev) { got = ev.payload.go_runtime; });
c.set_syslog_start(time() - 3600);
c.handle_log_line(ARGV[0]);
print(got);
UCODE
  uc "$tmp" "$1"
}
[ "$(payload 'daemon.err sing-box[123]: fatal error: runtime: out of memory')" = "true" ] ||
  fail "a Go runtime OOM must reach the healer as go_runtime"
[ "$(payload 'kernel: [1.0] urusai invoked oom-killer: gfp_mask=0xcc0')" = "false" ] ||
  fail "a kernel OOM line is not a Go runtime OOM"

# --- the healer decides before any GOMEMLIMIT write or restart ---
body="$(sed -n '/^function heal_oom/,/^}/p' "$WATCHDOG_UC" | grep -v '^[[:space:]]*//')"
[ -n "$body" ] || fail "heal_oom not found"
line_of() { grep -n -- "$1" <<<"$body" | head -1 | cut -d: -f1; }
decide="$(line_of 'oom_scale.oom_response(')"
noshrink="$(line_of 'response != "shrink"')"
write="$(line_of 'write_state_file(')"
restart="$(line_of 'tachyon restart')"
[ -n "$decide" ] && [ -n "$noshrink" ] && [ -n "$write" ] && [ -n "$restart" ] ||
  fail "heal_oom lost a step (decide=$decide noshrink=$noshrink write=$write restart=$restart)"
[ "$decide" -lt "$write" ] && [ "$noshrink" -lt "$write" ] && [ "$noshrink" -lt "$restart" ] ||
  fail "heal_oom must decide and return before touching GOMEMLIMIT or restarting"
grep -q 'read_oom_report()' <<<"$body" || fail "heal_oom must wait for the complete kernel report"
grep -q 'installed_core_is_go()' <<<"$body" || fail "heal_oom must ask the variant state whether the core is Go"

# --- Go or native comes from the variant state, not the process name ---
mkdir -p "$WORK_DIR/state"
variant_case() {
  printf '%s' "$1" >"$WORK_DIR/state/variant"
  printf '%s' "$2" >"$WORK_DIR/state/version"
  SB_VARIANT_STATE_FILE="$WORK_DIR/state/variant" SB_VERSION_STATE_FILE="$WORK_DIR/state/version" \
    uc -e 'print(require("tachyon_core.variant_state").is_tachyon_core() ? "native" : "go")'
}
[ "$(variant_case tachyon-core 0.5.2)" = "native" ] || fail "tachyon-core 0.5.2 must read as the native core"
for v in "extended 1.12.4-extended-1.4.1" "lx 1.12.10-lx.3" "stable 1.12.12" "tiny 1.12.12"; do
  set -- $v
  [ "$(variant_case "$1" "$2")" = "go" ] || fail "sing-box variant $1 ($2) must read as a Go core"
done

printf 'PASS: watchdog_oom_victim\n'
