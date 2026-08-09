#!/usr/bin/env bash
set -eo pipefail

# Pins that background spawns close the descriptors they would otherwise inherit.
#
# ucode keeps one open descriptor per require()d module for the lifetime of the
# interpreter, and offers no way to close them or mark them close-on-exec. Every
# background spawn therefore inherits the whole set. On the router the watchdog
# carried ~90 of them and handed them to each child: `logread`, `sh` and nfqws2
# were all found holding descriptors on Tachyon's own .uc files, several already
# unlinked by a package upgrade — the old inode pinned on disk by a process with
# no interest in it. watchdog.uc's own comment records this class of leak
# reaching the 1024-descriptor limit and failing the config generator.
#
# The codebase used to write a literal `1000<&-` against this, at 22 sites in 13
# modules. It closed nothing: no descriptor 1000 is ever opened, and every real
# one falls in 6..89. The protection read as present in every diff and was
# absent at runtime, which is the reason this test exists — the failure is
# invisible from the outside, so only counting descriptors shows it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"
COMMON_UC="$LIB_DIR/core/common.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ── the literal that closed nothing does not come back ────────────────────────
if grep -rn '1000<&-\|1000>&-' "$LIB_DIR" | grep -v '^.*core/common.uc:.*//' | grep -q .; then
  printf 'FAIL: a spawn still redirects descriptor 1000, which is never open:\n' >&2
  grep -rn '1000<&-\|1000>&-' "$LIB_DIR" | grep -v '^.*core/common.uc:.*//' >&2
  exit 1
fi

# ── no site hand-rolls its own background spawn ───────────────────────────────
# Backgrounding is the helpers' job. A site that appends its own ` &` is a site
# that inherits every descriptor, which is exactly the state being fixed. The
# three helper definitions are what everything else routes through, so they are
# the one place the raw form is expected.
stray="$(grep -rn '2>&1 &"' "$LIB_DIR" \
  | grep -v 'core/common.uc:.*close_inherited_fds()' \
  | grep -v 'service/initd.uc:.*as_string(command)' \
  | grep -v 'service/state.uc:.*as_string(command)' || true)"
[ -z "$stray" ] || fail "background spawn bypasses the helpers:
$stray"

# ── the prologue actually closes descriptors ──────────────────────────────────
# Structural checks cannot show this: the string has to be run. The parent opens
# a batch of files, spawns a child both ways, and each child counts what it got.
#
# How much the prologue can close depends on the shell. busybox ash — what
# OpenWrt runs — closes the whole set. dash cannot touch descriptors at or above
# 10 (it keeps its own bookkeeping there, and the redirection is fatal even for a
# number that was never open), so under dash the prologue lowers its ceiling to 9
# and leaves the rest. Either way it must close strictly more than nothing and
# must not take the spawn down with it, which is what this checks. The exact
# floor is asserted only where the shell can reach it.
if sh -c '( eval "exec 10<&-" ) 2>/dev/null' 2>/dev/null; then
  closes_high=yes
else
  closes_high=no
fi

SPAWN_UC="$(mktemp "${TMPDIR:-/tmp}/tachyon_spawn_fds.XXXXXX.uc")"
COUNT_OUT="$(mktemp "${TMPDIR:-/tmp}/tachyon_spawn_count.XXXXXX")"
trap 'rm -f "$SPAWN_UC" "$COUNT_OUT"' EXIT

cat > "$SPAWN_UC" <<UCODE
let fs = require("fs");
let common = require("core.common");

// Stand-ins for the descriptors ucode holds on require()d modules. Held in an
// array so they stay open — a closed handle would make the test pass for the
// wrong reason.
let held = [];
for (let i = 0; i < 12; i++)
    push(held, fs.open("/etc/hostname", "r"));

// Counted from inside the child via /proc/self/fd. The shell's own descriptors
// are counted too, so what matters is the difference between the two spawns,
// not either number alone.
//
// The count is written by reopening the output file inside the command rather
// than by redirecting the spawn, because background_command() points stdout at
// /dev/null — as it should — and would otherwise swallow it. Opening the file
// after the prologue has run also proves the prologue leaves the child able to
// open descriptors of its own.
let count_cmd = "{ ls /proc/self/fd | wc -l; } >>$COUNT_OUT";

// The way the codebase used to spawn: no prologue, descriptors inherited.
system("{ " + count_cmd + "; } </dev/null >/dev/null 2>&1 &");
sleep(300);

// Through the helper. Same command, one difference: the prologue runs first.
system(common.background_command(count_cmd));
sleep(300);

for (let handle in held)
    handle.close();
UCODE

ucode -L "$LIB_DIR" "$SPAWN_UC" || fail "spawn probe did not run"

inherited="$(sed -n '1p' "$COUNT_OUT" | tr -d ' ')"
closed="$(sed -n '2p' "$COUNT_OUT" | tr -d ' ')"

[ -n "$inherited" ] && [ -n "$closed" ] \
  || fail "spawn probe produced no counts (got '$inherited' / '$closed')"

# The child spawned through the helper must hold strictly fewer descriptors than
# the one spawned the old way. Where the shell can close the high ones too, it
# must be down to roughly the standard three.
[ "$closed" -lt "$inherited" ] \
  || fail "background_command did not close anything: old way inherited $inherited, helper $closed"
if [ "$closes_high" = yes ]; then
  [ "$closed" -le 5 ] \
    || fail "background_command left $closed descriptors open in the child; expected the standard three"
fi

# ── the fd ceiling must sit above procd's lock descriptor ─────────────────────
# Structural, because the runtime check below only runs on a shell that can close
# high descriptors — dash cannot, so CI would never reach it. Every copy of the
# prologue (core/common.uc plus the two early-boot duplicates) must agree.
#
# Matched per occurrence, not per line: one line carries both the real ceiling
# and the dash fallback `__tfd=9`, so a line-wise filter would discard both.
ceilings="$(grep -rho '__tfd=[0-9]*' "$LIB_DIR" | sort -u | grep -v '^__tfd=9$' || true)"
[ -n "$ceilings" ] || fail "no fd ceiling found; the spawn prologue lost its __tfd assignment"
for entry in $ceilings; do
  value="${entry#__tfd=}"
  [ "$value" -gt 1000 ] 2>/dev/null \
    || fail "fd ceiling $value does not cover procd lock descriptor 1000 (procd_lock does exec 1000> then flock 1000)"
done

# ── descriptor 1000 is the procd lock and must not survive the prologue ───────
# procd_lock() in /lib/functions/procd.sh does `exec 1000>/var/lock/procd_<svc>.lock`
# then `flock 1000` with no -w. A ceiling of 999 skipped exactly that descriptor,
# so every background spawn inherited the held lock and outlived the init script
# that took it — after which any /etc/init.d/tachyon call blocked in flock
# forever, which is how package_prerm hung until apk rolled the upgrade back.
# Killing the flock processes cannot help while an inheriting child holds the fd.
if [ "$closes_high" = yes ]; then
  LOCK_OUT="$(mktemp "${TMPDIR:-/tmp}/tachyon_spawn_lock.XXXXXX")"
  LOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/tachyon_spawn_lockfile.XXXXXX")"
  trap 'rm -f "$SPAWN_UC" "$COUNT_OUT" "$LOCK_OUT" "$LOCK_FILE"' EXIT

  cat > "$SPAWN_UC" <<UCODE
let common = require("core.common");
print(common.background_command("{ ls /proc/self/fd | grep -c '^1000\$' || true; } >>$LOCK_OUT"), "\n");
UCODE

  lock_command="$(ucode -L "$LIB_DIR" "$SPAWN_UC")"
  # Opened the way procd opens it, in this shell, so the child inherits it.
  ( eval "exec 1000>\"\$LOCK_FILE\""; eval "$lock_command"; sleep 0.4 )

  lock_seen="$(tr -d ' \n' < "$LOCK_OUT")"
  [ "$lock_seen" = 0 ] \
    || fail "background_command left procd's lock descriptor 1000 open in the child (saw '$lock_seen'); the fd ceiling must sit above 1000"
fi

# ── the pid-carrying form reports the daemon, not a wrapper ───────────────────
# `exec` has to replace the subshell, or `$!` names a shell that exits at once
# and the recorded pid belongs to nothing. Checked against a real spawn: the
# process the pid names must still be alive and must be the command itself.
PID_OUT="$(mktemp "${TMPDIR:-/tmp}/tachyon_spawn_pid.XXXXXX")"
trap 'rm -f "$SPAWN_UC" "$COUNT_OUT" "$PID_OUT"' EXIT

cat > "$SPAWN_UC" <<UCODE
let common = require("core.common");
print(common.background_command_with_pid("sleep 5", ">/dev/null", ">$PID_OUT"), "\n");
UCODE

pid_command="$(ucode -L "$LIB_DIR" "$SPAWN_UC")"
eval "$pid_command" >/dev/null
sleep 0.3

pid="$(tr -d ' \n' < "$PID_OUT")"
[ -n "$pid" ] || fail "background_command_with_pid wrote no pid"
[ -d "/proc/$pid" ] || fail "recorded pid $pid names no live process; \$! caught a wrapper that already exited"

comm="$(tr -d '\0\n' < "/proc/$pid/comm" 2>/dev/null || true)"
[ "$comm" = "sleep" ] \
  || fail "recorded pid $pid is '$comm', not the spawned command; exec did not replace the subshell"

kill "$pid" 2>/dev/null || true

printf 'background spawn descriptor checks passed (old way %s fds, helper %s)\n' "$inherited" "$closed"
