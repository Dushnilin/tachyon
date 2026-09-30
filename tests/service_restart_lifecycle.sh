#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
TACHYON_INIT="$ROOT_DIR/tachyon/files/etc/init.d/tachyon"
LIFECYCLE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/lifecycle.uc"
INITD_UC="$ROOT_DIR/tachyon/files/usr/lib/service/initd.uc"
APPLY_UC="$ROOT_DIR/tachyon/files/usr/lib/dns/apply.uc"
GENERATOR_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/generator.uc"

# --- 1. Static assertions on lifecycle.uc restart() -------------------------
awk '
  /function restart\(\)/ { in_restart = 1 }
  in_restart && /stop_impl\(\)/ { called_stop_impl = 1 }
  in_restart && /stop_main\(\)/ { called_stop_main = 1 }
  in_restart && /start_impl\(\)/ { called_start_impl = 1 }
  in_restart && /capture_selector_state\(\)/ { captured_selector = 1 }
  in_restart && /restore_selector_state\(selector_state\)/ { restored_selector = 1 }
  in_restart && /cleanup_failed_runtime\(\)/ { cleaned_on_failure = 1 }
  in_restart && /^}/ { done = 1; exit }
  END {
    if (!done) exit 1
    if (called_stop_impl) { print "restart() must not call stop_impl()"; exit 2 }
    if (!called_stop_main) { print "restart() must call stop_main()"; exit 3 }
    if (!called_start_impl) { print "restart() must call start_impl()"; exit 4 }
    if (!captured_selector) { print "restart() must capture selector state"; exit 5 }
    if (!restored_selector) { print "restart() must restore selector state"; exit 6 }
    if (!cleaned_on_failure) { print "restart() must call cleanup_failed_runtime on failure"; exit 7 }
    exit 0
  }
' "$LIFECYCLE_UC" || fail "restart() in lifecycle.uc failed structural verification"

# Verify stop() still calls stop_impl()
awk '
  /function stop\(\)/ { in_stop = 1 }
  in_stop && /return stop_impl\(\);/ { called_stop_impl = 1 }
  in_stop && /^}/ { done = 1; exit }
  END {
    if (!done || !called_stop_impl) exit 1
    exit 0
  }
' "$LIFECYCLE_UC" || fail "stop() in lifecycle.uc must still call stop_impl()"

# --- 2. Static assertions on init.d script -----------------------------------
grep -Fq 'restart_service()' "$TACHYON_INIT" ||
  fail "/etc/init.d/tachyon must define restart_service()"

grep -Fq 'initd_ucode restart-service "$$"' "$TACHYON_INIT" ||
  fail "/etc/init.d/tachyon restart_service() must invoke initd_ucode restart-service"

awk '
  /restart\(\)/ { in_restart = 1 }
  in_restart && /restart_service "\$@"/ { delegates = 1 }
  in_restart && /^}/ { done = 1; exit }
  END { exit (done && delegates) ? 0 : 1 }
' "$TACHYON_INIT" || fail "/etc/init.d/tachyon restart() must delegate to restart_service"

# --- 3. Static assertions on initd.uc ----------------------------------------
grep -Fq 'function restart_service(owner_pid)' "$INITD_UC" ||
  fail "initd.uc must define restart_service(owner_pid)"

grep -Fq 'else if (mode == "restart-service")' "$INITD_UC" ||
  fail "initd.uc must handle restart-service command"

awk '
  /function restart_service\(owner_pid\)/ { in_func = 1 }
  in_func && /BIN_PATH, "restart"/ { called_bin_restart = 1 }
  in_func && /^}/ { done = 1; exit }
  END { exit (done && called_bin_restart) ? 0 : 1 }
' "$INITD_UC" || fail "initd.uc restart_service must invoke [ BIN_PATH, 'restart' ]"

# --- 4. Static assertions on generator.uc turbo cache ------------------------
awk '
  /let turbo_cache = bool_option\(settings, "dns_turbo_cache", false\);/ { in_turbo = 1 }
  in_turbo && index($0, "cache_path = \"/etc/sing-box/cache.db\"") { uses_etc = 1 }
  in_turbo && index($0, "turbo_cache &&") { promotes = 1 }
  in_turbo && /cache_dir/ { done = 1; exit }
  END { exit (promotes && uses_etc) ? 0 : 1 }
' "$GENERATOR_UC" || fail "generator.uc must promote default cache_path to /etc/sing-box/cache.db when dns_turbo_cache is enabled"

# --- 5. Behavioral test: dnsmasq server remains 127.0.0.42 during restart ---
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/dnsmasq_mutations.log"

# Initial UCI state: Tachyon running, dnsmasq points to 127.0.0.42
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].tachyon_server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].tachyon_noresolv=0
dhcp.@dnsmasq[0].tachyon_cachesize=150
tachyon.settings.shutdown_correctly=0
tachyon.settings.dont_touch_dhcp=0
EOF_STATE

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/uci" <<'UCI'
#!/usr/bin/env bash
set -eo pipefail
while [ "${1:-}" = "-q" ]; do shift; done
cmd="${1:-}"
shift || true
state="${UCI_STATE:?}"
log="${MUTATION_LOG:?}"

do_set() {
  local key="$1"
  local val="${key#*=}"
  local var="${key%%=*}"
  printf 'SET %s=%s\n' "$var" "$val" >> "$log"
  local tmp
  tmp="$(mktemp)"
  awk -F= -v k="$var" '$1 != k' "$state" > "$tmp"
  printf '%s=%s\n' "$var" "$val" >> "$tmp"
  mv "$tmp" "$state"
}

do_del() {
  printf 'DELETE %s\n' "$1" >> "$log"
  local tmp
  tmp="$(mktemp)"
  awk -F= -v k="$1" '$1 != k' "$state" > "$tmp"
  mv "$tmp" "$state"
}

case "$cmd" in
  get)
    awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2); found = 1 } END { exit found ? 0 : 1 }' "$state"
    ;;
  set)
    do_set "$1"
    ;;
  delete)
    do_del "$1"
    ;;
  add_list)
    printf 'ADD_LIST %s %s\n' "$1" "$2" >> "$log"
    ;;
  commit)
    printf 'COMMIT %s\n' "$1" >> "$log"
    ;;
esac
UCI
chmod +x "$WORK_DIR/bin/uci"

cat >"$WORK_DIR/bin/dnsmasq_init" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WORK_DIR/bin/dnsmasq_init"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq_init"

# Run dnsmasq_configure while service is active (as called by restart -> start_impl)
export UCI_STATE="$STATE"
export MUTATION_LOG="$LOG"
export PATH="$WORK_DIR/bin:$PATH"
: > "$LOG"

ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$APPLY_UC" configure ||
  fail "dnsmasq_configure should succeed when dnsmasq already points to sing-box"

# Verify that no deletion of 127.0.0.42 or restoration of 1.1.1.1 occurred
if grep -Eq 'SET dhcp\.@dnsmasq\[0\]\.server=1\.1\.1\.1|ADD_LIST dhcp\.@dnsmasq\[0\]\.server 1\.1\.1\.1' "$LOG"; then
  fail "dnsmasq_configure reverted server to ISP DNS during restart!"
fi

current_server="$(awk -F= '$1 == "dhcp.@dnsmasq[0].server" { print $2 }' "$STATE")"
[ "$current_server" = "127.0.0.42" ] ||
  fail "dhcp.@dnsmasq[0].server must remain 127.0.0.42 throughout restart (was: $current_server)"

# --- 6. Behavioral test: Local DNS Cache enables 10000 entries in dnsmasq ---
printf 'tachyon.settings.dns_local_cache=1\n' >> "$STATE"
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$APPLY_UC" configure force ||
  fail "dnsmasq_configure force should apply local cache"

cachesize="$(awk -F= '$1 == "dhcp.@dnsmasq[0].cachesize" { print $2 }' "$STATE")"
[ "$cachesize" = "10000" ] ||
  fail "dhcp.@dnsmasq[0].cachesize should be 10000 when dns_local_cache is enabled (was: $cachesize)"

# --- 7. Behavioral test: Stop restores ISP DNS --------------------------------
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$APPLY_UC" restore force ||
  fail "dnsmasq_restore force should succeed on service stop"

restored_server="$(awk -F= '$1 == "dhcp.@dnsmasq[0].server" { print $2 }' "$STATE")"
[ "$restored_server" = "1.1.1.1 8.8.8.8" ] ||
  fail "dhcp.@dnsmasq[0].server must be restored to ISP DNS on stop (was: $restored_server)"

printf 'service restart lifecycle checks passed\n'

