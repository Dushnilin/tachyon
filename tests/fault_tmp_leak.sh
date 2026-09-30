#!/usr/bin/env bash
# FAULT: mktemp files were created in /tmp and never reclaimed.
#
# Measured on 192.168.1.1: ten orphaned /tmp/tachyon-XXXXXX files, 968 KB, seven
# days old, out of a 363 MB tmpfs. Contents were sing-box config candidates and
# rule lists - leftovers from a validation run that did not reach its rename.
#
# TMP_FILE_STALE_TTL_MINUTES is 10 minutes and a sweeper exists, so this looked
# covered. It was not: the find only matched tachyon-updates-command.* and
# tachyon-updates-http.*, while four call sites create files through
# `mktemp /tmp/tachyon-XXXXXX`:
#
#   components/updates.uc:318
#   nft/apply.uc:2504
#   service/lifecycle.uc:1658
#   singbox/runtime.uc:128
#
# Not one of those matched the sweeper, so nothing it made was ever deleted.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
HELPERS_UC="$LIB_DIR/components/helpers.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$HELPERS_UC" ] || fail "components/helpers.uc not found"

# The sweeper must cover the shape mktemp actually produces.
grep -q '"tachyon-??????"' "$HELPERS_UC" ||
  fail "cleanup_stale_tmp_files does not match tachyon-??????"

# And it must not use a find option that only exists in GNU findutils. The routers
# run BusyBox, where `find -delete` is rejected outright:
#
#   find: unrecognized: -delete
#   BusyBox v1.37.0
#
# That is not a portability nitpick: the whole command fails, so the sweeper
# reclaims nothing. It has been silently dead on every router since it was written,
# for every pattern, and a container test with GNU find would never have caught it.
# Verified against 192.168.1.205.
# Comments are stripped first: the explanation of why -delete is wrong necessarily
# names -delete, and grepping the raw file would match its own documentation.
# The stripped text is materialised first rather than piped into grep -q: under
# `set -o pipefail` a `grep -q` that exits on the first match closes the pipe, the
# upstream grep dies of SIGPIPE with 141, and the whole pipeline looks like a
# failure. That made a correct implementation report as broken.
code_lines="$(grep -v '^[[:space:]]*//' "$HELPERS_UC" || true)"

case "$code_lines" in
  *-delete*)
    fail "the sweeper still uses find -delete, which BusyBox find does not support; the command fails and nothing is ever reclaimed"
    ;;
esac

case "$code_lines" in
  *'"-exec", "rm", "-f", "{}", "+"'*) ;;
  *)
    fail "the file sweep does not use -exec rm -f, which is the form that works on BusyBox"
    ;;
esac

# Every call site that creates one must be covered by that pattern, and the count
# has to be right: a new one appearing later without being swept is the same bug.
sites="$(grep -rhoE 'mktemp", "/tmp/tachyon-XXXXXX"' "$LIB_DIR" --include=*.uc | wc -l)"
[ "$sites" -eq 4 ] ||
  fail "expected four mktemp /tmp/tachyon-XXXXXX call sites, found $sites; a new one may not be covered by the sweeper"

# The pattern must stay exactly six characters, or it starts eating real files
# that share the prefix. These all live in /tmp and must survive a sweep.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

for name in tachyon_metrics.json tachyon_recent_releases_cache.json \
    tachyon-install.log tachyon-feedback-bot.new tachyon_honeypot.fifo \
    tachyon-updates-command.abc tachyon-updates-http.def; do
  printf 'x\n' > "$sandbox/$name"
done
# And two files the sweeper *is* meant to take.
printf 'x\n' > "$sandbox/tachyon-AbCdEf"

find "$sandbox" -maxdepth 1 -type f \
  \( -name "tachyon-updates-command.*" -o -name "tachyon-updates-http.*" \
     -o -name "tachyon-??????" \) -exec rm -f {} +

[ -f "$sandbox/tachyon_metrics.json" ] ||
  fail "the sweep deleted tachyon_metrics.json, a real runtime file that merely shares the prefix"
[ -f "$sandbox/tachyon_recent_releases_cache.json" ] ||
  fail "the sweep deleted tachyon_recent_releases_cache.json"
[ -f "$sandbox/tachyon-install.log" ] ||
  fail "the sweep deleted tachyon-install.log"
[ -f "$sandbox/tachyon-feedback-bot.new" ] ||
  fail "the sweep deleted tachyon-feedback-bot.new"

[ ! -f "$sandbox/tachyon-AbCdEf" ] ||
  fail 'the sweep did not take a tachyon-??????" mktemp file, so the leak stays'

[ -f "$sandbox/tachyon-updates-command.abc" ] &&
  fail "the sweep stopped taking tachyon-updates-command.* files"
[ -f "$sandbox/tachyon-updates-http.def" ] &&
  fail "the sweep stopped taking tachyon-updates-http.* files"

printf 'fault: mktemp leak is swept passed\n'
