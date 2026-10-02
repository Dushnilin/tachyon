#!/usr/bin/env bash
# BUG (TCH-1050 / TCH-1051): installing zapret2 through Tachyon failed, and the
# component ended up uninstalled - reported as "tachyon удаляется с роутера".
#
# zapret2's upstream preinst owns /etc/config/zapret2 and treats a config that
# lacks "run_on_boot" as an incompatible leftover:
#
#     if [ -f "${ZAPRET_CFG}" ] && ! grep -q "run_on_boot" "${ZAPRET_CFG}"; then
#         rm -f ${ZAPRET_CFG}
#         rm -f ${ZAPRET_INITD}
#         [ -d "${ZAPRET_DIR}" ] && rm -rf ${ZAPRET_DIR}
#     fi
#
# and on an already-installed zapret2 it aborts the transaction outright:
#
#     if [ -f "${ZAPRET_CFG}" ] && ! grep -q "run_on_boot" "${ZAPRET_CFG}"; then
#         echo "Please uninstall incompatible zapret2 package!"
#         exit 48
#     fi
#
# Tachyon wrote exactly that forbidden shape before installing
# ("config zapret2 'main' / option enabled '0'"), so every install after the
# first either wiped /opt/zapret2 or refused to proceed at all. apk rolls such
# a transaction back, which is the removal the user saw.
#
# The invariant, and it is upstream's contract rather than ours: Tachyon must
# never leave /etc/config/zapret2 in a state upstream's preinst classifies as
# incompatible. Upstream postinst builds the real config from config.default via
# uci-def-cfg.sh, so the fix is to not author a stub at all and only set the
# autostart flag after the install has produced the genuine config.
#
# The preinst/postinst excerpts are embedded here deliberately: the invariant is
# defined by those scripts, so a test that did not carry them would assert our
# guess instead of their rule.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ACTION_UC="$TACHYON_LIB/components/action.uc"
[ -f "$ACTION_UC" ] || fail "components/action.uc not found at $ACTION_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- upstream's rule, transcribed ------------------------------------------
# If this block and action.uc ever disagree, the transcription is what is wrong
# and the test should say so rather than quietly passing.
upstream_rejects_config() {
  # $1 = config file contents on stdin. Mirrors preinst:
  #   file exists  AND  does not contain run_on_boot  ->  rejected.
  local body
  body="$(cat)"
  [ -n "$body" ] || return 1
  printf '%s' "$body" | grep -q "run_on_boot" && return 1
  return 0
}

# --- 1. the stub Tachyon used to write must be rejected by that rule --------
# Guards the transcription: if this ever passes, the fixture no longer describes
# the offending shape and the rest of the test proves nothing.
printf "config zapret2 'main'\n\toption enabled '0'\n" \
  | upstream_rejects_config ||
  fail "precondition: the two-line stub must be the shape upstream rejects"
ok

# --- 2. Tachyon must not author such a config ------------------------------
# The actual defect. Writing it is what made preinst wipe or abort.
grep -q "write_file(\"/etc/config/zapret2\", \"config zapret2 'main'" "$ACTION_UC" &&
  fail "action.uc still authors /etc/config/zapret2 as a bare two-line stub without run_on_boot; upstream preinst deletes /opt/zapret2 over it and aborts with exit 48 on a re-install"
ok

# --- 3. the repair path must add run_on_boot -------------------------------
# A config left behind by an older Tachyon still has to be repaired in place,
# because preinst wipes before it would ever be re-generated.
grep -q 'run_on_boot' "$ACTION_UC" ||
  fail "action.uc no longer mentions run_on_boot: a stub written by an older build would still be wiped, and nothing repairs it"
ok

# --- 4. enabled=0 must be applied after the install, not before -------------
# Before the install there is no genuine config to modify (upstream postinst
# creates it), so writing early is what forced the stub in the first place.
install_line="$(grep -n 'run_logged_pkg_install_files\|pkg_install_files_command(\[ pkg.file \])' "$ACTION_UC" | head -n1 | cut -d: -f1)"
[ -n "$install_line" ] || fail "could not locate the zapret2 install call in action.uc"

enabled_line="$(grep -n 'uci_core.set("zapret2.main.enabled", "0")' "$ACTION_UC" | tail -n1 | cut -d: -f1)"
[ -n "$enabled_line" ] || fail "action.uc no longer disables the standalone zapret2 service"
ok

[ "$enabled_line" -gt "$install_line" ] ||
  fail "zapret2.main.enabled is set at line $enabled_line, before the install at line $install_line; upstream postinst has not produced the real config yet, so this writes the incompatible stub"
ok

# --- 5. every DPI engine install must scrub apk world first ----------------
# apk reads /etc/apk/world before selecting, so a stale entry makes the set
# unselectable and rolls the whole transaction back. Self-updates already go
# through pkg_tx_install_*; the engines came in through run_logged and did not.
unsanitized="$(grep -c 'run_logged("Installing [^"]*pkg_install_files_command' "$ACTION_UC" || true)"
[ "$unsanitized" = "0" ] ||
  fail "$unsanitized component install(s) still call run_logged() with pkg_install_files_command() directly, skipping sanitize_apk_world(); a stale world entry rolls those transactions back (TCH-1050/TCH-1051)"
ok

grep -q 'function run_logged_pkg_install_files' "$ACTION_UC" ||
  fail "action.uc has no run_logged_pkg_install_files(): there is no single place that scrubs world before a package file install"
ok

# --- 6. the repair must actually be able to report itself ------------------
# This module logs through log_message()/updates_log(); a bare log() compiles
# cleanly and only fails when the branch runs, which is precisely the branch a
# user hits with an old config.
bare="$(grep -cE '^[[:space:]]*log\(' "$ACTION_UC" || true)"
[ "$bare" = "0" ] ||
  fail "action.uc calls bare log() ($bare site(s)); this module has no such function, so the call fails at runtime - use log_message() or updates_log()"
ok

echo "zapret2_preinst_config_contract: $pass_count checks passed"