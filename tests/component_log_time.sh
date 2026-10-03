#!/usr/bin/env bash
# The operation log showed UTC on a router set to a local timezone.
#
# job_log_time() divided epoch seconds by 3600, which is the UTC hour, so every
# [HH:MM:SS] in the log was off by the router's offset while `date` and syslog on
# the same box were right - three hours in Europe/Moscow, four in UTC+4. core/logging.uc
# already used localtime(), which is why the two disagreed.
#
# The second half is the worker environment. It is spawned with an explicit env, so
# TZ is not inherited, and on OpenWrt /etc/localtime is a symlink into /tmp generated
# by the system init; with no zoneinfo-* installed musl lands on UTC. So TZ has to be
# passed in, taken from the setting the user changed in LuCI.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

HELPERS="$TACHYON_LIB/components/helpers.uc"
UPDATES="$TACHYON_LIB/components/updates.uc"
LOGGING="$TACHYON_LIB/core/logging.uc"
for f in "$HELPERS" "$UPDATES" "$LOGGING"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

cat >"$WORK_DIR/tzcheck.uc" <<'UCODE'
let helpers = require("components.helpers");

let errors = [];
let note = function(m) { push(errors, m); };

// Deterministic stamp: with TZ=Europe/Moscow the clock reads three hours ahead of
// UTC, so the hour has to be the local one.
let stamp = helpers.job_log_time();

if (!match(stamp, /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/))
    note("job_log_time returned [" + stamp + "], expected HH:MM:SS");

// The worker must learn the timezone. components.updates is a script, not a
// library, so the lookup lives in components.helpers where it can be called.
let tz = helpers.component_worker_tz();
if (type(tz) != "string")
    note("components.helpers must expose component_worker_tz");
else if (tz == "")
    note("component_worker_tz found no timezone; the operation log would stay on UTC");
else if (index(tz, ":") >= 0 || index(tz, " ") >= 0)
    note("TZ must be a POSIX TZ string, got [" + tz + "]");

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("tz=%s stamp=%s\n", tz, stamp);
UCODE

if out="$(TZ=MSK-3 ucode "$WORK_DIR/tzcheck.uc" 2>&1)"; then
  printf 'component log time: %s\n' "$out"
  ok
else
  fail "operation log timezone is wrong:
$out"
fi

# The stamp has to actually follow TZ.
#
# POSIX TZ strings, not zone names: OpenWrt stores /etc/TZ as "MSK-3" and ships no
# zoneinfo, so musl parses the offset straight out of the string. A zone name like
# Europe/Moscow needs /usr/share/zoneinfo and would silently stay on UTC - which is
# the trap this whole issue is about.
stamp_in() { # <index> <tz>
  TZ="$2" UPDATES_JOB_LOG="$WORK_DIR/job-$1.log" \
    ucode -e '
      let helpers = require("components.helpers");
      helpers.job_log_append("probe", "info");
    ' >/dev/null 2>&1
  sed -n 's/^\[\([0-9:]*\)\].*/\1/p' "$WORK_DIR/job-$1.log" 2>/dev/null | tail -1
}

msk="$(stamp_in msk MSK-3)"
nyc="$(stamp_in nyc EST5EDT)"
utc="$(stamp_in utc UTC0)"
if [ -z "$msk" ] || [ -z "$nyc" ] || [ -z "$utc" ]; then
  fail "job_log_append wrote no parsable stamp (msk='$msk' nyc='$nyc' utc='$utc')"
fi
ok

if [ "$msk" = "$utc" ]; then
  fail "MSK-3 and UTC0 produced the same stamp ('$msk'): the timezone is not applied at all"
fi
ok

if [ "$msk" = "$nyc" ]; then
  fail "MSK-3 and EST5EDT produced the same stamp ('$msk')"
fi
ok

# The timestamp must go through localtime and must not do the UTC division. Checked
# per function, because the two files are shaped differently: components/helpers.uc
# has a job_log_time() helper, core/logging.uc inlines the same code in
# job_log_append(). now_seconds() legitimately wants epoch seconds and is not in
# scope.
fn_body() { sed -n "/^function $2(/,/^}/p" "$1"; }

check_stamp() { # <file> <function> <label>
  local body
  body="$(fn_body "$1" "$2")"
  [ -n "$body" ] || fail "$1 has no $2"
  grep -q 'localtime' <<<"$body" ||
    fail "$3 must use localtime(); epoch/3600 is the UTC hour by definition"
  ok
  if grep -qE '/ *3600|3600 *\)' <<<"$body"; then
    fail "$3 still divides epoch seconds by 3600, which ignores the timezone:
$body"
  fi
  ok
}

check_stamp "$HELPERS" job_log_time "components/helpers.uc job_log_time"
check_stamp "$LOGGING" job_log_append "core/logging.uc job_log_append"

printf 'component log time: %d checks passed\n' "$pass_count"
printf 'PASS: component_log_time\n'