#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# The tail of issue #108, after the refusal and the generic-card gate were done:
# a plain install of the stable/tiny package still rolled the router back when
# the running binary was newer than the one the OpenWrt repository carries - the
# binary had been replaced by hand, or came from a newer snapshot. Two causes:
# current_version was read from the apk database rather than from the binary that
# actually runs, and nothing compared it against the repository version before
# installing. The same issue also left the routing-engine card offering a Versions
# picker for the package variants, which the backend refuses by design.

ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
INIT_CONTROLLER="$ROOT_DIR/fe-app-tachyon/src/tachyon/tabs/updates/initController.ts"

[ -f "$ACTION_UC" ] || fail "components/action.uc not found"
[ -f "$INIT_CONTROLLER" ] || fail "initController.ts not found"

# --- what runs is what is reported -------------------------------------------
pkg_fn="$(sed -n '/^function install_package_sing_box/,/^}/p' "$ACTION_UC")"
[ -n "$pkg_fn" ] || fail "action.uc no longer defines install_package_sing_box"

grep -Fq 'let current_version = binary_version != "" ? binary_version : package_version;' <<<"$pkg_fn" ||
  fail "install_package_sing_box must report the running binary version, not the apk database version"

# --- no silent downgrade ------------------------------------------------------
grep -Fq 'compare_versions(binary_version, latest_version)' <<<"$pkg_fn" ||
  fail "install_package_sing_box must compare the running binary against the repository version"
grep -Fq 'downgrade > 0' <<<"$pkg_fn" ||
  fail "install_package_sing_box must refuse when the running binary is newer"
grep -Fq 'would be downgraded' <<<"$pkg_fn" ||
  fail "the refusal must explain the downgrade in its message"
grep -Fq 'action != "check_update"' <<<"$pkg_fn" ||
  fail "the downgrade guard must not turn check_update into a failure"

# Refusing before the service is stopped is the whole point: nothing should be
# touched when the answer is no.
stop_line="$(grep -n 'stop_tachyon_before_sing_box_change();' <<<"$pkg_fn" | head -1 | cut -d: -f1)"
guard_line="$(grep -n 'would be downgraded' <<<"$pkg_fn" | head -1 | cut -d: -f1)"
[ -n "$stop_line" ] || fail "could not find the service stop in install_package_sing_box"
[ -n "$guard_line" ] || fail "could not find the downgrade guard in install_package_sing_box"
[ "$guard_line" -lt "$stop_line" ] ||
  fail "the downgrade guard must run before the service is stopped, otherwise the router is left half-changed"

# Switching family on purpose is legitimate even when the versions differ, so
# the guard is scoped to the same family instead of comparing blindly.
grep -Eq 'previous_variant == \(tiny \? "tiny" : "stable"\)' <<<"$pkg_fn" ||
  fail "the downgrade guard must be scoped to the same variant family"

# --- the engine card must not offer a picker the backend refuses -------------
picker_block="$(awk '/const pickerHonoursTag =/,/^  }$/' "$INIT_CONTROLLER")"
[ -n "$picker_block" ] || fail "the engine card has no variant gate for the version picker"
grep -Fq "'sing-box-stable'" <<<"$picker_block" ||
  fail "the engine card picker gate must exclude sing-box-stable"
grep -Fq "'sing-box-tiny'" <<<"$picker_block" ||
  fail "the engine card picker gate must exclude sing-box-tiny"
grep -Fq 'if (pickerHonoursTag) {' <<<"$picker_block" ||
  fail "the engine card must not render the Versions button for the package variants"

# The variants that do honour a tag keep their picker, and steer honours a tag
# too (install_steer takes target_tag), so it must not be gated either.
grep -Fq "selectedVariant.id !== 'steer'" <<<"$picker_block" &&
  fail "steer honours a picked tag and must keep its picker"

# The picker component still follows the selection, which is what fixed the
# "versions of the active engine" report; the gate must not undo that.
grep -Fq 'const pickerComponent = getVariantComponent(selectedVariant.id);' <<<"$picker_block" ||
  fail "the engine card picker must stay bound to the selected variant"

printf 'sing-box downgrade guard checks passed\n'