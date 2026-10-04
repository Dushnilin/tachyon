#!/usr/bin/env bash
# FAULT: the Versions picker offered releases the package variant cannot install.
#
# On the stable/tiny sing-box variant the picker listed SagerNet/sing-box releases
# (including pre-releases). Picking 1.15.0-alpha.10 over an installed
# 1.15.0-alpha.9 and pressing Install ended with 1.13.21 - the version from the
# OpenWrt repository - because install_component_version() passed the tag down and
# dispatch_sing_box() only forwards it to the lx/extended installers; the package
# path re-resolves the version from available_package_version() and apk add
# --allow-untrusted with a downgrade is permitted. The chosen tag was discarded
# silently (issue #108).
#
# The fix refuses before create_component_backup and the frontend stops offering
# a picker that would only lead to that error. This test reads the production
# files, the same way fault_auto_update_action.sh does: driving the real
# dispatcher needs the component lock, UCI and backups, and the contract that
# broke lives in the source ordering.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
ACTION_UC="$LIB_DIR/components/action.uc"
INIT_CONTROLLER="$ROOT_DIR/fe-app-tachyon/src/tachyon/tabs/updates/initController.ts"

[ -f "$ACTION_UC" ] || fail "components/action.uc not found"
[ -f "$INIT_CONTROLLER" ] || fail "initController.ts not found"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

body="$(sed -n '/^function install_component_version/,/^}/p' "$ACTION_UC")"
[ -n "$body" ] || fail "could not locate install_component_version in action.uc"

# 1. The backend must consult the installed variant before doing anything.
grep -q 'sing_box_runtime_output("variant"' <<<"$body" ||
  fail "install_component_version does not check the sing-box variant"
ok

grep -q 'extended-compressed' <<<"$body" ||
  fail "the variant guard must accept the binary variants (lx/extended/extended-compressed)"
ok

# 2. ...and it must refuse the package variants with a clear message, not
#    silently install the repository version.
grep -q 'Installing a specific version is only supported' <<<"$body" ||
  fail "the package variants must be refused with an explicit error"
ok

# 3. Ordering is the whole point: the refusal has to come before the backup is
#    created, otherwise the failed attempt still snapshots state (issue #108).
guard_line="$(grep -n 'sing_box_runtime_output("variant"' <<<"$body" | head -1 | cut -d: -f1)"
backup_line="$(grep -n 'create_component_backup(' <<<"$body" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$backup_line" ] || fail "could not locate guard/backup lines"
if [ "$guard_line" -ge "$backup_line" ]; then
  fail "the variant guard (line $guard_line) must run before create_component_backup (line $backup_line)"
fi
ok

# 4. The lx/extended tag path must survive: dispatch_sing_box("install", tag)
#    stays reachable, otherwise the fix would break what worked.
grep -q 'dispatch_sing_box("install", tag)' <<<"$body" ||
  fail "the tag must still reach dispatch_sing_box for the binary variants"
ok

# 5. Frontend: the sing-box card must not offer Versions on stable/tiny.
# The card is identified by its unique actions reference; the action literals
# earlier in the file read `component: 'sing_box' as const` and are not cards.
card="$(grep -A8 'actions: singBoxActions,' "$INIT_CONTROLLER" || true)"
[ -n "$card" ] || fail "could not locate the sing-box card in initController.ts"

grep -q 'supportsVersions: !singBoxStable && !singBoxTiny' <<<"$card" ||
  fail "the sing-box card must hide Versions on the stable/tiny package variants"
ok

if grep -q 'supportsVersions: true' <<<"$card"; then
  fail "the sing-box card still offers Versions unconditionally"
fi
ok

printf 'sing-box version install guard: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_version_install_guard\n'
