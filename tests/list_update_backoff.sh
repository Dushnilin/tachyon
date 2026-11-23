#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$TACHYON_LIB/components/updates.uc"

# 1. update_interval='0' and list_update_interval='0' must disable scheduled list updates cleanly
cat >"$WORK_DIR/cron-zero-interval.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "update_interval": "0"
  },
  "section": [
    {
      ".name": "list_rule",
      "enabled": "1",
      "action": "proxy",
      "remote_domain_lists": [ "https://example.com/list.txt" ]
    }
  ]
}
JSON

plan0="$(ucode -L "$TACHYON_LIB" "$UPDATES_UC" cron-refresh-plan-fixture "$WORK_DIR/cron-zero-interval.json" /usr/bin/tachyon '# list' '# subscription' '# component')"
[ "$plan0" = "list-disabled" ] || fail "update_interval=0 expected list-disabled, got '$plan0'"

cat >"$WORK_DIR/cron-legacy-zero.json" <<'JSON'
{
  "settings": {
    "list_update_enabled": "1",
    "list_update_interval": "0",
    "update_interval": "1d"
  },
  "section": [
    {
      ".name": "list_rule",
      "enabled": "1",
      "action": "proxy",
      "remote_domain_lists": [ "https://example.com/list.txt" ]
    }
  ]
}
JSON

plan1="$(ucode -L "$TACHYON_LIB" "$UPDATES_UC" cron-refresh-plan-fixture "$WORK_DIR/cron-legacy-zero.json" /usr/bin/tachyon '# list' '# subscription' '# component')"
[ "$plan1" = "list-disabled" ] || fail "list_update_interval=0 expected list-disabled, got '$plan1'"

# 2. Circuit breaker stops mirror storm across unreachable files and sets cron backoff
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tachyon-core/rulesets"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_state"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
export TACHYON_LIST_UPDATE_STATE_FILE="$WORK_DIR/run/list-update.timestamp"
export TACHYON_LIST_UPDATE_BACKOFF_FILE="$WORK_DIR/run/list-update.backoff"
export TACHYON_LIST_UPDATE_PID_FILE="$WORK_DIR/run/list_update.pid"
export TACHYON_LIST_UPDATE_STATUS_FILE="$WORK_DIR/run/list-update.status"
export TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export TMP_TACHYON_CORE_FOLDER="$WORK_DIR/tachyon-core"
export TMP_RULESET_FOLDER="$WORK_DIR/tachyon-core/rulesets"
export TACHYON_PERSISTENT_RULESET_DIR="$WORK_DIR/persistent_rulesets"
export TACHYON_BIN="$WORK_DIR/bin/tachyon"
export TACHYON_SERVICE_INIT="$WORK_DIR/bin/init_tachyon"
export TACHYON_CURL_COUNT_FILE="$WORK_DIR/curl_calls.log"
export PATH="$WORK_DIR/bin:$PATH"

mkdir -p "$TACHYON_PERSISTENT_RULESET_DIR"
for name in l1 l2 l3 l4 l5; do
  printf '1.1.1.0/24\n' > "$WORK_DIR/tachyon-core/rulesets/remote-domain-$name.txt"
done

cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *"doh"*|*"dns-query"*) exit 0 ;;
  esac
done
printf '%s\n' "$*" >> "$TACHYON_CURL_COUNT_FILE"
# dns_probe_passed checks https://1.1.1.1 or https://dns.google or github; keep dns_probe passing, fail raw.githubusercontent & mirrors
for a in "$@"; do
  case "$a" in
    *"raw.githubusercontent.com"*|*"jsdelivr.net"*|*"ghfast"*|*"gh-proxy"*|*"nxnow.top"*|*"llkk.cc"*|*"ghproxy"*|*"moeyy"*)
      exit 28
      ;;
  esac
done
exit 0
STUB
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/bin/tachyon" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$WORK_DIR/bin/tachyon"

cat >"$WORK_DIR/bin/init_tachyon" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$WORK_DIR/bin/init_tachyon"

# Extract batch download + backoff test using real updates.uc runtime globals via TACHYON_UCI_STATE_FILE
cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.settings=settings
tachyon.settings.list_update_enabled=1
tachyon.settings.update_interval=1d
tachyon.sec1=section
tachyon.sec1.enabled=1
tachyon.sec1.action=proxy
tachyon.sec1.remote_domain_lists=https://raw.githubusercontent.com/o/r/main/a.txt https://raw.githubusercontent.com/o/r/main/b.txt https://raw.githubusercontent.com/o/r/main/c.txt https://raw.githubusercontent.com/o/r/main/d.txt https://raw.githubusercontent.com/o/r/main/e.txt
STATE

# Evaluate batch circuit-breaker behavior with real download_to_file function from updates.uc
ucode -e '
let fs = require("fs");
let src = fs.readfile("'"$UPDATES_UC"'");
// Strip CLI dispatch footer at the bottom so updates.uc functions can be tested in-process
let footer_idx = index(src, "let mode = ARGV[0]");
if (footer_idx < 0) exit(99);
let lib_src = substr(src, 0, footer_idx) + "\nreturn { download_to_file, reset_download_batch_state, write_list_update_backoff, list_update_in_backoff, clear_list_update_backoff, read_list_update_backoff };\n";
let fn_path = "'"$WORK_DIR/updates_mod.uc"'";
fs.writefile(fn_path, lib_src);
'
ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let mod = loadfile("'"$WORK_DIR/updates_mod.uc"'")();
mod.reset_download_batch_state();

let urls = [
    "https://raw.githubusercontent.com/o/r/main/a.txt",
    "https://raw.githubusercontent.com/o/r/main/b.txt",
    "https://raw.githubusercontent.com/o/r/main/c.txt",
    "https://raw.githubusercontent.com/o/r/main/d.txt",
    "https://raw.githubusercontent.com/o/r/main/e.txt"
];
for (let i = 0; i < length(urls); i++) {
    let p = "'"$WORK_DIR/tachyon-core/rulesets/f"'" + i + ".txt";
    fs.writefile(p, "cached.example\n");
    let ok = mod.download_to_file(urls[i], p, "", false);
    if (!ok) { warn("cached fallback failed on file " + i + "\n"); exit(1); }
    if (fs.readfile(p) != "cached.example\n") { warn("cache corrupted on file " + i + "\n"); exit(2); }
}

// Verify backoff scheduling
let now = 1700000000;
let streak = mod.write_list_update_backoff(now, "remote_unreachable");
if (streak != 1) { warn("expected streak 1\n"); exit(3); }
if (!mod.list_update_in_backoff(now + 600)) { warn("expected active backoff after 10m\n"); exit(4); }
if (mod.list_update_in_backoff(now + 3700)) { warn("expected streak-1 backoff expired after 1h+\n"); exit(5); }
mod.clear_list_update_backoff();
if (mod.list_update_in_backoff(now + 10)) { warn("expected backoff cleared\n"); exit(6); }
' || fail "download circuit breaker / backoff check failed"

curl_calls="$(wc -l < "$TACHYON_CURL_COUNT_FILE" | tr -d ' ')"
# Without circuit breaker & dead-mirror tracking: 5 files * 8 candidates = 40+ calls.
# With dead mirror skip (>=2 failures) + 3-file batch abort: file 0 tries 8, file 1 tries 8, file 2 tries 1 (mirrors skipped), files 3..4 try 0 => ~17 calls!
[ "$curl_calls" -le 10 ] || fail "expected dead-host skipping to cap curl calls at <=10, got $curl_calls"

# HTTP 22 errors (single missing file) must NOT blacklist the host for subsequent files
: > "$TACHYON_CURL_COUNT_FILE"
rm -f "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/bin/curl" <<'STUB22'
#!/bin/sh
url=""; prev=""
for a in "$@"; do
  [ "$a" = "-o" ] && url="$prev"
  prev="$a"
  case "$a" in
    *"doh"*|*"dns-query"*) exit 0 ;;
  esac
done
[ -n "$url" ] || exit 0
printf '%s\n' "$url" >> "$TACHYON_CURL_COUNT_FILE"
exit 22
STUB22
chmod +x "$WORK_DIR/bin/curl"
got_http22="$(ucode -L "$TACHYON_LIB" "$UPDATES_UC" download-to-file-fixture "$WORK_DIR/tachyon-core/rulesets" "" \
  "https://example.com/missing-1.txt" "https://example.com/missing-2.txt" 2>/dev/null || true)"
http22_calls="$(wc -l < "$TACHYON_CURL_COUNT_FILE" | tr -d ' ')"
[ "$http22_calls" -eq 2 ] || fail "HTTP 22 must not blacklist host (expected 2 curl calls, got $http22_calls)"
[ "$got_http22" = "0" ] || fail "expected 0 obtained files on HTTP 22, got '$got_http22'"

# Verify list_update_if_due skips running list_update when backoff file is fresh
: > "$TACHYON_CURL_COUNT_FILE"
printf '%s\t1\tremote_unreachable\n' "$(date +%s)" > "$TACHYON_LIST_UPDATE_BACKOFF_FILE"
ucode -L "$TACHYON_LIB" "$UPDATES_UC" list-update-if-due
[ ! -s "$TACHYON_CURL_COUNT_FILE" ] || fail "list-update-if-due must not make curl calls during active backoff"

printf 'list_update_backoff checks passed (bounded curl_calls=%s)\n' "$curl_calls"
