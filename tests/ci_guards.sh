#!/usr/bin/env bash
# CI guard: stops the codebase from growing new instances of the patterns the
# remaining refactoring stages exist to remove.
#
# Each pattern carries a per-file baseline count. A violation is reported only
# when the current count EXCEEDS the baseline, so existing legacy keeps working
# while any new occurrence fails the build. As legacy gets refactored away the
# baseline shrinks and `--update` rewrites it.
#
#   bash tests/ci_guards.sh            # check (fails on new violations)
#   bash tests/ci_guards.sh --update   # rewrite the baseline
#
# Keyed by file rather than line numbers, so ordinary edits above a violation do
# not churn the baseline.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

BASELINE="$ROOT_DIR/tests/ci_guards_baseline.txt"

if [ "${1:-}" = "--update" ]; then
  UPDATE=1
else
  UPDATE=0
fi

# Rules are three TAB-separated fields: id, extended regex, exempt files.
#
# TAB, not pipe: the regexes themselves contain "|" (as in "(^|[^_a-zA-Z.])"),
# so a pipe separator silently truncates every one of them. That bug shipped
# once already and produced a baseline computed from the fragment "^(", which
# matched nothing and made the guard pass unconditionally.
#
# core/common.uc and core/exec.uc own the sanctioned background-command builder,
# so they are exempt from the raw-"&" rule. core/transaction.uc exists to commit
# UCI, so it is exempt from that rule as well.
TAB="$(printf '\t')"
RULES="raw_system${TAB}(^|[^_a-zA-Z.])system[[:space:]]*\\(${TAB}
shell_c${TAB}(^|[^_a-zA-Z.])sh[[:space:]]+-c[[:space:]]${TAB}
raw_popen${TAB}(^|[^_a-zA-Z.])popen[[:space:]]*\\(${TAB}tachyon/files/usr/lib/core/common.uc tachyon/files/usr/lib/core/exec.uc
direct_uci_commit${TAB}uci[[:space:]]+commit${TAB}tachyon/files/usr/lib/core/transaction.uc
raw_background${TAB}2>&1[[:space:]]*&${TAB}tachyon/files/usr/lib/core/common.uc tachyon/files/usr/lib/core/exec.uc"

cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

count_current() {
  : > "$WORK/current"
  local files id re exclude file n
  files="$(git ls-files 'tachyon/files/usr/lib/*.uc')"
  [ -n "$files" ] || fail "no ucode files found under tachyon/files/usr/lib"

  while IFS="$TAB" read -r id re exclude; do
    [ -n "${id:-}" ] || continue
    for file in $files; do
      case " $exclude " in
        *" $file "*) continue ;;
      esac
      n="$(grep -cE -- "$re" "$file" 2>/dev/null || true)"
      [ "${n:-0}" -gt 0 ] || continue
      printf '%s|%s|%s\n' "$id" "$file" "$n" >> "$WORK/current"
    done
  done <<< "$RULES"

  sort -o "$WORK/current" "$WORK/current"
}

count_current

if [ "$UPDATE" -eq 1 ]; then
  cp "$WORK/current" "$BASELINE"
  printf 'CI guards: baseline rewritten (%s entries)\n' "$(wc -l < "$BASELINE" | tr -d ' ')"
  exit 0
fi

[ -f "$BASELINE" ] || fail "baseline missing: $BASELINE (create it with: bash tests/ci_guards.sh --update)"

regressions="$(awk -F'|' '
  NR == FNR { have[$1 SUBSEP $2] = $3; next }
  {
    key = $1 SUBSEP $2
    if (($3 + 0) > (have[key] + 0))
      print "  " $1 "  " $2 ": baseline " have[key] " -> now " $3
  }
' "$BASELINE" "$WORK/current")"

awk -F'|' '{ print $1 "|" $2 }' "$BASELINE" | sort > "$WORK/base_keys"
awk -F'|' '{ print $1 "|" $2 }' "$WORK/current" | sort > "$WORK/cur_keys"
removed="$(comm -23 "$WORK/base_keys" "$WORK/cur_keys")"

if [ -n "$regressions" ]; then
  {
    printf 'CI guards: new violations of banned patterns\n'
    printf '%s\n' "$regressions"
    printf '\n'
    printf 'Banned: raw system(), sh -c, raw popen(), direct "uci commit", raw background "&".\n'
    printf 'Use the wrappers from core/common.uc and core/exec.uc instead (command_status,\n'
    printf 'command_from_args, background_command, pkg_tx_*). If a violation is genuinely\n'
    printf 'unavoidable, record it deliberately with: bash tests/ci_guards.sh --update\n'
  } >&2
  exit 1
fi

if [ -n "$removed" ]; then
  printf 'CI guards: baseline shrank - these are gone, run --update to record it:\n'
  printf '%s\n' "$removed" | sed 's/^/  - /'
fi

printf 'CI guards: no new violations\n'
