#!/usr/bin/env bash
# #420: with GitHub blocked, every list file walked all its sources again
# (GitHub, jsDelivr, six mirrors), direct and through the proxy section, each
# attempt up to 10 s. A host that failed at the network level is now skipped
# for the rest of the run; HTTP errors (one missing file) do not count.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES="$TACHYON_LIB/components/updates.uc"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/dl"
CURL_LOG="$WORK_DIR/curl.log"
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
# The URL is the argument before -o; the outcome is taken from CURL_RC.
url=""; prev=""
for a in "$@"; do [ "$a" = "-o" ] && url="$prev"; prev="$a"; done
[ -n "$url" ] || exit 0   # capability probes (curl --help ...), not downloads
printf '%s\n' "$url" >>"$CURL_LOG"
exit "${CURL_RC:-28}"
STUB
chmod +x "$WORK_DIR/bin/curl"
export CURL_LOG

FILES=()
for n in 1 2 3 4 5 6; do
  FILES+=( "https://raw.githubusercontent.com/example/lists/main/list$n.lst" )
done

run() { # $1 curl exit code, $2 proxy -> number of curl calls
  : >"$CURL_LOG"
  rm -f "$WORK_DIR"/dl/*
  CURL_RC="$1" PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$UPDATES" download-to-file-fixture \
    "$WORK_DIR/dl" "$2" "${FILES[@]}" >/dev/null 2>&1 || true
  wc -l <"$CURL_LOG" | tr -d ' '
}

# Blocked at the network level (timeout): the first file probes each source
# once per path, the other five files try nothing new.
first=$(run 28 "")
one_file=$( : >"$CURL_LOG"; CURL_RC=28 PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$UPDATES" download-to-file-fixture \
  "$WORK_DIR/dl" "" "${FILES[0]}" >/dev/null 2>&1 || true; wc -l <"$CURL_LOG" | tr -d ' ')
[ "$first" = "$one_file" ] ||
  fail "blocked GitHub: 6 files took $first curl calls, the first alone $one_file - unreachable hosts are retried for every file"

with_proxy=$(run 28 "127.0.0.1:2081")
one_proxy=$( : >"$CURL_LOG"; CURL_RC=28 PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$UPDATES" download-to-file-fixture \
  "$WORK_DIR/dl" "127.0.0.1:2081" "${FILES[0]}" >/dev/null 2>&1 || true; wc -l <"$CURL_LOG" | tr -d ' ')
[ "$with_proxy" = "$one_proxy" ] ||
  fail "blocked GitHub via proxy section: 6 files took $with_proxy curl calls, the first alone $one_proxy"

# HTTP errors (curl 22: the file is missing on one source) say nothing about
# the host: every file still tries every source.
http=$(run 22 "")
one_http=$( : >"$CURL_LOG"; CURL_RC=22 PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$UPDATES" download-to-file-fixture \
  "$WORK_DIR/dl" "" "${FILES[0]}" >/dev/null 2>&1 || true; wc -l <"$CURL_LOG" | tr -d ' ')
[ "$http" = $(( 6 * one_http )) ] ||
  fail "an HTTP error marked the host unreachable ($http calls for 6 files, expected $(( 6 * one_http )))"

# update_interval '0' means "never": no list job, and no invalid-interval
# error, which used to drop every other cron job (subscriptions) with it.
cat >"$WORK_DIR/cron-zero.json" <<'JSON'
{ "settings": { "update_interval": "0" },
  "section": [
    { ".name": "lists", "enabled": "1", "action": "proxy", "remote_domain_lists": [ "https://example.com/list.txt" ] },
    { ".name": "sub", "enabled": "1", "action": "proxy", "subscription_urls": [ "https://example.com/sub" ],
      "subscription_update_interval": "6h" } ] }
JSON
plan="$(ucode -L "$TACHYON_LIB" "$UPDATES" cron-refresh-plan-fixture "$WORK_DIR/cron-zero.json" /usr/bin/tachyon '# list' '# subscription' '# component')"
printf '%s\n' "$plan" | grep -qx 'list-disabled' || fail "update_interval=0 does not disable list updates: $plan"
if printf '%s\n' "$plan" | grep -q 'list-error'; then fail "update_interval=0 is reported as invalid: $plan"; fi

printf 'list download dead-host checks passed (blocked: %s calls for 6 files, was %s per file)\n' "$first" "$one_file"
