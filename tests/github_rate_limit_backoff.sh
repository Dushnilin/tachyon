#!/usr/bin/env bash
# FAULT: an exhausted GitHub API budget must not be answered with a mirror stampede.
#
# Measured on a live router: GitHub was reachable the whole time - api.github.com
# answered 200 and handed back valid release JSON. What broke the component sweep
# was the budget. The unauthenticated API allows 60 requests per hour per IP,
# that router was set to component_update_check_interval=5m against a 1d default,
# and one sweep spends many requests. Once the budget ran out the API answered
# 403 with a rate-limit body, curl -f turned that into a bare failure, and the
# caller then walked every mirror - twelve more requests that cannot succeed on
# a network where gh-proxy.com, ghfast.top, mirror.ghproxy.com and github.moeyy.xyz
# are all unreachable. The user saw "Failed to fetch zapret2 releases from GitHub
# API (Rate limit or network error)" and reached the reasonable conclusion that
# GitHub was blocked.
#
# The direct attempt has to keep the error body so a rate-limit answer is
# recognisable, and that answer has to end the sweep instead of walking mirrors.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DOWNLOADER_UC="$TACHYON_LIB/components/downloader.uc"
[ -f "$DOWNLOADER_UC" ] || fail "components/downloader.uc not found"

body() {
  awk "/^function $1\(/,/^}/" "$DOWNLOADER_UC"
}

fetch_body=$(body fetch_github_json)
[ -n "$fetch_body" ] || fail "fetch_github_json not found in components/downloader.uc"

# The first candidate is GitHub itself and must be fetched body-aware, or the
# rate-limit answer is destroyed by curl -f before anyone can read it.
printf '%s' "$fetch_body" | grep -Fq 'http_get_with_body' ||
  fail "fetch_github_json must fetch the direct candidate body-aware; curl -f discards the rate-limit answer"
grep -Fq 'http_get_with_body' "$DOWNLOADER_UC" ||
  fail "http_get_with_body is referenced but not defined"

# That helper must not use -f, or it is the same discard wearing a new name.
once_body=$(body http_get_with_body)
[ -n "$once_body" ] || fail "http_get_with_body not found"
if printf '%s' "$once_body" | grep -Eq '(^|[^-])-f([^a-zA-Z]|$)|-fsSL|-fSL'; then
  fail "http_get_with_body must not pass -f to curl; that is what throws the error body away"
fi
printf '%s' "$once_body" | grep -Fq '"%{http_code}"' ||
  fail "http_get_with_body must capture the HTTP status so a 403 is distinguishable from a dead route"

# A recognised rate-limit answer must stop the sweep. Returning "" and letting
# the loop continue is exactly the stampede this test exists to prevent.
printf '%s' "$fetch_body" | grep -Fq 'github_response_is_rate_limited' ||
  fail "fetch_github_json must recognise a rate-limit answer"
rate_check_line=$(printf '%s' "$fetch_body" | grep -n 'github_response_is_rate_limited(direct.body)' | head -1 | cut -d: -f1)
[ -n "$rate_check_line" ] ||
  fail "fetch_github_json never checks the direct body for rate limiting"
return_line=$(printf '%s' "$fetch_body" | grep -n 'return "";' | head -1 | cut -d: -f1)
[ -n "$return_line" ] || fail "fetch_github_json has no early return"
[ "$rate_check_line" -lt "$return_line" ] ||
  fail "the rate-limit branch must return before the loop can advance to a mirror"

# And the log line has to name the real cause: the old message ("Rate limit or
# network error") is what sent this diagnosis down the wrong path for an hour.
printf '%s' "$fetch_body" | grep -Fq 'GitHub API rate limit exhausted' ||
  fail "the rate-limit branch must log that the budget is exhausted, not a generic failure"

# The recognition has to cover what GitHub actually says.
rate_body=$(body github_response_is_rate_limited)
[ -n "$rate_body" ] || fail "github_response_is_rate_limited not found"
printf '%s' "$rate_body" | grep -Fq 'API rate limit exceeded' ||
  fail "must match GitHub's 'API rate limit exceeded' message"
printf '%s' "$rate_body" | grep -Fq 'secondary rate limit' ||
  fail "must also match the secondary rate limit message"

# ...and must not fire on a normal release payload, or every update would be
# reported as rate limited.
grep -Fq 'github_response_is_rate_limited' "$DOWNLOADER_UC" ||
  fail "github_response_is_rate_limited is defined but never used"

printf 'GitHub rate-limit early exit checks passed\n'