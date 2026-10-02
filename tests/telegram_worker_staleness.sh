#!/usr/bin/env bash
# The Telegram worker is a long-lived process, and check_telegram_worker only
# restarted it when the heartbeat went stale. A worker that kept polling was
# therefore never restarted, so after a package update it went on serving the
# code it had started with: old i18n strings, unpaginated server lists, buttons
# that no longer match the installed build. The user saw a stale bot and had no
# way to tell it apart from a current one.
#
# The heartbeat now carries the version the worker was launched from, and the
# watchdog restarts it when that no longer matches what is installed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WD="$TACHYON_LIB/service/watchdog.uc"
TRANSPORT="$TACHYON_LIB/service/telegram/transport.uc"

# --- 1. the heartbeat must actually carry a version ---
probe="$WORK_DIR/hb.uc"
cat >"$probe" <<'EOF'
let transport = require("service.telegram.transport");
transport.write_heartbeat();
EOF

HB="$WORK_DIR/hb.txt"
if TACHYON_TG_HEARTBEAT="$HB" TACHYON_VERSION="9.9.9-test" \
    ucode -L "$TACHYON_LIB" "$probe" >/dev/null 2>&1; then
    :
else
    fail "could not run write_heartbeat()"
fi

[ -s "$HB" ] || fail "write_heartbeat() wrote nothing to $HB"
printf 'heartbeat => %s\n' "$(cat "$HB")" >&2

epoch="$(awk '{print $1}' "$HB")"
case "$epoch" in
    ''|*[!0-9]*) fail "first heartbeat field must stay a bare epoch for the age check, got '$epoch'" ;;
esac

grep -q '9\.9\.9-test' "$HB" ||
    fail "heartbeat does not carry the version the worker was started from"

# --- 2. the watchdog must act on a version mismatch ---
grep -Fq 'TACHYON_VERSION' "$WD" ||
    fail "the watchdog never compares the running version against the installed one"
grep -Fq 'telegram_stop' "$WD" ||
    fail "the watchdog cannot stop the stale worker"

printf 'telegram worker staleness checks passed\n'