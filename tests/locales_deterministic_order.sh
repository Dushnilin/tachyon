#!/usr/bin/env bash
# BUG: locales/*.pot and *.po were generated in the machine's locale order.
#
# extract-calls.js sorted translation keys with String.prototype.localeCompare,
# which uses the collation of the current locale. The pre-push hook regenerates
# the locales and fails when that leaves the tree dirty, so on any machine whose
# locale collated differently from the one that produced the committed files,
# regeneration reshuffled already-committed entries and the hook read that as
# drift: the push was blocked with a diff nobody could explain.
#
# Observed concretely: a regeneration on a Windows host moved 30 msgid with zero
# content change, and the diff was ~3100 lines of pure reordering.
#
# The invariant: extraction must be byte-identical regardless of locale, so the
# generated files are a function of the source and nothing else.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

EXTRACT_JS="$ROOT_DIR/fe-app-tachyon/extract-calls.js"
[ -f "$EXTRACT_JS" ] || fail "fe-app-tachyon/extract-calls.js not found"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. no locale-dependent collation anywhere ------------------------------
# Matched on the call, not the word: the fix's own comment explains why
# localeCompare is wrong and must not be mistaken for a regression.
n="$(grep -c 'localeCompare(' "$EXTRACT_JS" || true)"
[ "$n" = "0" ] ||
  fail "extract-calls.js still calls localeCompare ($n site(s)); the order of locales/*.pot depends on the machine's locale again"
ok

# --- 2. the sort is present and locale-independent --------------------------
# Code-unit comparison: locale-independent by construction, unlike a pinned
# locale argument, which is still at the mercy of the ICU version in use.
grep -qE '\.sort\(\(a, b\) => \(a\.key < b\.key \?' "$EXTRACT_JS" ||
  fail "extract-calls.js must sort translation keys by code unit (a.key < b.key)"
ok

# --- 3. behaviour: identical output under different locales ----------------
# Run only where a second locale is actually available; otherwise the source
# check above already carries the invariant and this is skipped, not faked.
if command -v node >/dev/null 2>&1 && [ -d "$ROOT_DIR/fe-app-tachyon" ]; then
  if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^tr_TR'; then
    hashes="$(cd "$ROOT_DIR/fe-app-tachyon" && {
      node extract-calls.js >/dev/null 2>&1; sha256sum locales/calls.json | cut -d' ' -f1
      LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 node extract-calls.js >/dev/null 2>&1; sha256sum locales/calls.json | cut -d' ' -f1
    } | sort -u | wc -l)"
    [ "$hashes" = "1" ] ||
      fail "calls.json differs between locales ($hashes distinct hashes); extraction is not deterministic"
    ok
  else
    printf 'skip: tr_TR locale unavailable, relying on the source-level checks\n'
  fi
fi

echo "locales_deterministic_order: $pass_count checks passed"