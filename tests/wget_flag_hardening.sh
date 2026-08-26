#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# BusyBox wget in OpenWrt 25.12+ no longer supports -t (retries). Tachyon
# handles retries explicitly in a while loop, so the flag is unnecessary and
# breaks downloads on recent OpenWrt releases.
if grep -rn --exclude='*.json' --fixed-strings 'wget' "$ROOT_DIR/tachyon/files" | grep -E -- '(^|[^-a-z])(-t[^a-z]|-t")' >/dev/null 2>&1; then
  grep -rn --exclude='*.json' --fixed-strings 'wget' "$ROOT_DIR/tachyon/files" | grep -E -- '(^|[^-a-z])(-t[^a-z]|-t")' >&2
  fail "wget -t is incompatible with OpenWrt 25.12+ BusyBox; use explicit retry loops instead"
fi

# NOTE(2026-08-07): download_to_file() in components/updates.uc was the only
# call site that carried -t. It was removed and curl-first fallback was added.
# This invariant protects against future regressions.

printf 'wget flag hardening checks passed\n'
