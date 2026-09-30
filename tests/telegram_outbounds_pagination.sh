#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Telegram server picker must paginate.
#
# Field report: with a group of 20-100+ nodes the message was cut off by
# Telegram ("(message truncated)") after 17 entries, the remaining nodes were
# unreachable, and the back-to-groups button was never reachable. Cause: the
# message text listed every server while the keyboard was hard-capped at 18
# buttons, so the tail had no way to be shown.
#
# curl is stubbed so the real view function runs end to end: the clash /proxies
# call returns a fixture, and every Telegram call is captured verbatim.

trap 'rm -rf "$WORK_DIR"' EXIT

SERVER_COUNT=100
PER_PAGE=16

# ── stub curl ────────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/bin/sh
# Clash API fixture when the URL mentions /proxies, otherwise capture the call.
for arg in "$@"; do
  case "$arg" in
    *"/proxies"*)
      cat "$TACHYON_TEST_PROXIES_JSON"
      exit 0
      ;;
  esac
done
printf '%s\n' "$*" >> "$TACHYON_TEST_CAPTURE"
printf '{"ok":true,"result":{"message_id":1}}'
STUB
chmod +x "$WORK_DIR/bin/curl"

# ── clash fixture: one Selector group with $SERVER_COUNT nodes ───────────────
{
  printf '{"proxies":{"main":{"type":"Selector","now":"NODE 000","all":['
  i=0
  while [ "$i" -lt "$SERVER_COUNT" ]; do
    [ "$i" -gt 0 ] && printf ','
    printf '"NODE %03d"' "$i"
    i=$((i + 1))
  done
  printf ']}}}'
} >"$WORK_DIR/proxies.json"

export TACHYON_TEST_PROXIES_JSON="$WORK_DIR/proxies.json"
export TACHYON_TEST_CAPTURE="$WORK_DIR/capture.txt"
export PATH="$WORK_DIR/bin:$PATH"

# Page through the group and collect, per page, how many node buttons and how
# many node text lines were emitted. Out-of-range clamping is asserted
# separately, so stop at the real last page.
: >"$WORK_DIR/pages.tsv"
PAGES=$(( (SERVER_COUNT + PER_PAGE - 1) / PER_PAGE ))
page=0
while [ "$page" -lt "$PAGES" ]; do
  : >"$TACHYON_TEST_CAPTURE"
  ucode -L "$TACHYON_LIB" -e '
    let c = require("service.telegram.commands");
    c.view_outbounds("tok", 1, 42, "main", ARGV[0] + "");
  ' "$page" >/dev/null

  # The payload is inside the captured "-d {json}" argument.
  payload="$(grep -o '\-d .*' "$TACHYON_TEST_CAPTURE" | head -1 | cut -c4-)"
  printf '%s' "$payload" >"$WORK_DIR/page_$page.json"

  buttons="$(printf '%s' "$payload" | grep -o '/sw main NODE [0-9]*' | wc -l | tr -d ' ')"
  textlines="$(printf '%s' "$payload" | grep -o 'NODE [0-9][0-9][0-9]</code>' | wc -l | tr -d ' ')"
  printf '%s\t%s\t%s\n' "$page" "$buttons" "$textlines" >>"$WORK_DIR/pages.tsv"

  page=$((page + 1))
done

# ── assertions ───────────────────────────────────────────────────────────────

# 1. No page may exceed the page size in buttons or in text lines, and text and
#    keyboard must show the SAME window (that mismatch was the truncation bug).
while IFS=$'\t' read -r pg buttons textlines; do
  [ "$buttons" -le "$PER_PAGE" ] ||
    fail "page $pg rendered $buttons node buttons, above the $PER_PAGE page size"
  [ "$textlines" -le "$PER_PAGE" ] ||
    fail "page $pg listed $textlines servers in the message text, above $PER_PAGE (Telegram truncates the message)"
  [ "$buttons" = "$textlines" ] ||
    fail "page $pg shows $buttons buttons but $textlines text lines; the unreachable tail is the bug"
done <"$WORK_DIR/pages.tsv"

# 2. Every node must be reachable on some page, and appear exactly once.
all_buttons="$(cat "$WORK_DIR"/page_*.json | grep -o '/sw main NODE [0-9]*' | sort -u | wc -l | tr -d ' ')"
[ "$all_buttons" = "$SERVER_COUNT" ] ||
  fail "only $all_buttons of $SERVER_COUNT nodes are reachable across the pages"

duplicates="$(cat "$WORK_DIR"/page_*.json | grep -o '/sw main NODE [0-9]*' | sort | uniq -d | wc -l | tr -d ' ')"
[ "$duplicates" = "0" ] ||
  fail "$duplicates nodes are offered on more than one page"

# 3. Pagination controls must exist whenever there is more than one page.
first="$(cat "$WORK_DIR/page_0.json")"
last="$(cat "$WORK_DIR/page_$((PAGES - 1)).json")"
printf '%s' "$first" | grep -q 'nav_next' || printf '%s' "$first" | grep -q '▶' ||
  fail "first page has no next-page control"
printf '%s' "$last" | grep -q 'nav_prev' || printf '%s' "$last" | grep -q '◀' ||
  fail "last page has no previous-page control"

# 4. The back-to-groups / back control must stay reachable on every page.
#    With a single group the code falls back to /menu.
for f in "$WORK_DIR"/page_*.json; do
  printf '%s' "$(cat "$f")" | grep -q '/menu' ||
    fail "$(basename "$f") lost its back button"
done

# 5. Out-of-range page numbers must clamp instead of rendering an empty list.
: >"$TACHYON_TEST_CAPTURE"
ucode -L "$TACHYON_LIB" -e '
  let c = require("service.telegram.commands");
  c.view_outbounds("tok", 1, 42, "main", "99");
' >/dev/null
tail_payload="$(grep -o '\-d .*' "$TACHYON_TEST_CAPTURE" | head -1 | cut -c4-)"
printf '%s' "$tail_payload" | grep -q '/sw main NODE' ||
  fail "an out-of-range page rendered no nodes instead of clamping to the last page"

printf 'telegram_outbounds_pagination passed (%s nodes over %s pages)\n' "$SERVER_COUNT" "$PAGES"
