#!/usr/bin/env bash
# A start that refuses on an invalid config left no trace.
#
# fail_validation() printed the reason to stdout and exited. The user runs
# `tachyon start` from a console, the message scrolls by, and logread shows nothing
# at all - reported on 1.4.8, where a section refused to start and the only symptom
# was a silent service and a message nobody had kept. The abort reason has to reach
# the system log too, under the same tag as every other tachylon message.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
[ -f "$VALIDATOR_UC" ] || fail "missing $VALIDATOR_UC"

LOG="$WORK_DIR/logger.log"
: >"$LOG"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<STUB
#!/usr/bin/env bash
printf 'logger\t%s\n' "\$*" >> "$LOG"
STUB
chmod 0755 "$WORK_DIR/bin/logger"

# The smallest thing that trips the validator: no DNS server at all.
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "main_dns": [],
    "bootstrap_dns": []
  },
  "section": []
}
JSON

set +e
out="$(PATH="$WORK_DIR/bin:$PATH" TACHYON_UCI_STATE_FILE="$WORK_DIR/fixture.json" \
  ucode -S -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/fixture.json" "{}" 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] ||
  { printf 'FAIL: the fixture was expected to be rejected, it passed\n%s\n' "$out" >&2; exit 1; }

[ -s "$LOG" ] ||
  { printf 'FAIL: the abort left no entry in the system log\nstdout was:\n%s\n' "$out" >&2; exit 1; }

grep -Fq 'tachyon' "$LOG" ||
  { printf 'FAIL: the log entry is not tagged as tachyon: %s\n' "$(cat "$LOG")" >&2; exit 1; }

# The same text in both places, so the log alone is enough to diagnose.
first_line="$(printf '%s\n' "$out" | grep -m1 -F 'Aborted.')"
[ -n "$first_line" ] ||
  { printf 'FAIL: no reason on stdout to compare against the log\n%s\n' "$out" >&2; exit 1; }
grep -Fq "$first_line" "$LOG" ||
  { printf 'FAIL: stdout and the log disagree.\nstdout: %s\nlog: %s\n' "$first_line" "$(cat "$LOG")" >&2; exit 1; }

printf 'validation failure logged: %s\n' "$first_line"
printf 'PASS: validation_failure_logged\n'