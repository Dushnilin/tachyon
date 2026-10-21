#!/usr/bin/env bash
# Verifies that clean installation / configure-service properly creates:
# 1. /etc/config/tachyon-core and sing-box.main section
# 2. /usr/share/tachyon-core working directory in managed_service_text and configure_service
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

SB_RUNTIME="$TACHYON_LIB/tachyon_core/runtime.uc"
UCI_UC="$TACHYON_LIB/core/uci.uc"

[ -f "$SB_RUNTIME" ] || fail "tachyon_core/runtime.uc not found at $SB_RUNTIME"
[ -f "$UCI_UC" ] || fail "core/uci.uc not found at $UCI_UC"

# 1. ensure_sing_box_main_section creates /etc/config/tachyon-core
grep -Fq 'let cfg_file = "/etc/config/tachyon-core"' "$SB_RUNTIME" ||
  fail "ensure_sing_box_main_section must check and create /etc/config/tachyon-core if missing"

grep -Fq 'uci_set_option("tachyon-core", "main", "workdir", "/usr/share/tachyon-core")' "$SB_RUNTIME" ||
  fail "ensure_sing_box_main_section must set default workdir option"

# 2. the shared init generator creates the working directory before launching the core
PROC_UC="$TACHYON_LIB/core/process.uc"
grep -Fq '[ -d \"$working_directory\" ] || mkdir -p \"$working_directory\"' "$PROC_UC" ||
  fail "managed service init script must ensure working directory exists before running the core"

# 3. configure_service creates working directory
grep -Fq 'fs.mkdir(workdir, 0755)' "$SB_RUNTIME" ||
  fail "configure_service must ensure workdir directory exists"

# 4. core/uci.uc set_section creates missing config files
grep -Fq 'let cfg_file = "/etc/config/" + parts.package;' "$UCI_UC" ||
  fail "core/uci.uc set_section must create missing package file in /etc/config"

# 5. The three installers share one generator. BusyBox killall matches
# /proc/self/stat comm == "tachyon-core" and SIGKILLs /etc/init.d/tachyon-core.
for f in \
  "$TACHYON_LIB/tachyon_core/runtime.uc" \
  "$TACHYON_LIB/components/action.uc" \
  "$TACHYON_LIB/config/validator.uc"; do
  grep -Fq 'managed_core_init_script(' "$f" ||
    fail "$f must generate the init script through core.process.managed_core_init_script"
done

UCODE_BIN="${TACHYON_UCODE:-ucode}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || fail "ucode is required to render the managed init script"

render_init() {
  "$UCODE_BIN" -L "$TACHYON_LIB" "$PROC_UC" init-script marker "$@"
}

for variant in "" reset-log; do
  script="$(render_init $variant)"
  [ -n "$script" ] || fail "init-script renderer returned an empty script ($variant)"
  if printf '%s\n' "$script" | grep -Fq 'killall'; then
    fail "generated init script contains killall ($variant), which kills /etc/init.d/tachyon-core itself"
  fi
  printf '%s\n' "$script" | grep -Fq '_kill_daemon_instances()' ||
    fail "generated init script must define _kill_daemon_instances() ($variant)"
  printf '%s\n' "$script" | grep -Fq '_has_running_daemon()' ||
    fail "generated init script must define _has_running_daemon() ($variant)"
  printf '%s\n' "$script" | grep -Fq '[ "$p" != "$$" ]' ||
    fail "generated init script must skip its own pid ($variant)"
  printf '%s\n' "$script" | grep -Fq '*/tachyon-core|*/sing-box' ||
    fail "generated init script must kill only the core executable ($variant)"
  bad="$WORK_DIR/selfkill.sh"
  printf '%s\nkillall -q -9 tachyon-core\n' "$script" >"$bad"
  "$UCODE_BIN" -L "$TACHYON_LIB" "$PROC_UC" kills-itself "$bad" ||
    fail "kills-itself must detect killall of the init script comm"
  printf '%s\n' "$script" >"$bad"
  if "$UCODE_BIN" -L "$TACHYON_LIB" "$PROC_UC" kills-itself "$bad"; then
    fail "generated init script was reported as self-killing ($variant)"
  fi
done

plain="$(render_init)"
logged="$(render_init reset-log)"
printf '%s\n' "$logged" | grep -Fq '/tmp/tachyon-core/sing-box.log' ||
  fail "reset-log variant must truncate the core log"
if printf '%s\n' "$plain" | grep -Fq '/tmp/tachyon-core/sing-box.log'; then
  fail "plain variant must leave the core log alone"
fi

# doctor and lifecycle must not killall the procd name: that signal also
# hits the init script while it is stopping the daemon.
for f in \
  "$TACHYON_LIB/diagnostics/doctor.uc" \
  "$TACHYON_LIB/service/lifecycle.uc"; do
  if grep -E 'killall[^#]*tachyon-core|killall[^#]*sing-box' "$f" | grep -v '^[[:space:]]*//' | grep -q .; then
    fail "$f still killalls the core comm; use core.process.kill_core_daemons"
  fi
done

printf 'clean_install_sing_box_init: all checks passed\n'
