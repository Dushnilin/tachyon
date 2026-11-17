#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

INSTALLER="$ROOT_DIR/install.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$INSTALLER" ] || fail "install.sh is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

# 1. main() ordering invariants: release must be resolved before core selection
# and legacy engine cleanup must only execute on >= 1.8.0 releases.
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /select_release_version/ && !rel_sel { rel_sel=NR }
  in_main && /resolve_release/ && !rel_res { rel_res=NR }
  in_main && /select_core_installation/ && !core_sel { core_sel=NR }
  in_main && /if release_is_tachyon_core_only; then/ { mig_guard=NR }
  in_main && /migrate_legacy_engine_files/ { mig_call=NR }
  END {
    exit !(rel_sel > 0 && rel_res > rel_sel && core_sel > rel_res && mig_guard > 0 && mig_call == mig_guard + 1)
  }
' "$INSTALLER" || fail "main() ordering or migrate_legacy_engine_files guard broken"

export TACHYON_INSTALLER_TEST=1
# shellcheck source=/dev/null
. "$INSTALLER"

QUIET=1
DRY_RUN=1

# 2. Version threshold check (< 1.8.0 vs >= 1.8.0)
for v in 1.8.0 1.8.1 2.0.0 1.8.0-rc1; do
  TACHYON_RELEASE_TAG="$v"
  RELEASE_TAG_REQUESTED=""
  release_is_tachyon_core_only || fail "$v must be treated as tachyon-core-only"
done

for v in 1.7.33 1.7.0 1.6.9 0.9.0; do
  TACHYON_RELEASE_TAG="$v"
  RELEASE_TAG_REQUESTED=""
  if release_is_tachyon_core_only; then
    fail "$v must preserve < 1.8.0 multi-engine compatibility"
  fi
done

# 3. >= 1.8.0 rejects sing-box options and upgrades existing sing-box routers to tachyon-core
reset_installer_state() {
  CORE_INSTALL_CHOICE=""
  CORE_INSTALL_REQUESTED=""
  ENGINE_INSTALL_CHOICE=""
  ENGINE_INSTALL_REQUESTED=""
  SING_BOX_INSTALL_VARIANT=""
  SING_BOX_VARIANT_REQUESTED=""
  RELEASE_TAG_REQUESTED=""
  TACHYON_RELEASE_TAG=""
  SKIP_ENGINE=0
  ASSUME_YES=0
}

core_is_present() { return 1; }
sing_box_is_present() { return 0; }
installer_is_interactive() { return 1; }

reset_installer_state
parse_args --tag 1.8.0 --engine sing-box
TACHYON_RELEASE_TAG="1.8.0"
if select_core_installation 2>/dev/null; then
  fail ">= 1.8.0 must reject --engine sing-box"
fi

reset_installer_state
parse_args --tag 1.8.0 --sing-box-variant extended
TACHYON_RELEASE_TAG="1.8.0"
if select_core_installation 2>/dev/null; then
  fail ">= 1.8.0 must reject --sing-box-variant extended"
fi

reset_installer_state
parse_args --tag 1.8.0 -y
TACHYON_RELEASE_TAG="1.8.0"
select_core_installation
[ "$CORE_INSTALL_CHOICE" = "tachyon-core" ] ||
  fail "upgrading a sing-box-only router to 1.8.0 must select tachyon-core (got: $CORE_INSTALL_CHOICE)"

# 4. < 1.8.0 preserves sing-box variants, interactive menu, and non-interactive default
sing_box_is_present() { return 1; }

reset_installer_state
parse_args --tag 1.7.33 --sing-box-variant extended
TACHYON_RELEASE_TAG="1.7.33"
select_core_installation
[ "$ENGINE_INSTALL_CHOICE" = "sing-box" ] && [ "$SING_BOX_INSTALL_VARIANT" = "extended" ] ||
  fail "1.7.33 --sing-box-variant extended failed ($ENGINE_INSTALL_CHOICE / $SING_BOX_INSTALL_VARIANT)"
PKG_MANAGER="apk"
QUIET=0
plan_out="$(print_plan)"
QUIET=1
printf '%s\n' "$plan_out" | grep -Fq "Routing core: sing-box (extended)" ||
  fail "print_plan for 1.7.33 must report sing-box (extended)"

reset_installer_state
parse_args --tag 1.7.33 -y
TACHYON_RELEASE_TAG="1.7.33"
select_core_installation
[ "$ENGINE_INSTALL_CHOICE" = "sing-box" ] && [ "$SING_BOX_INSTALL_VARIANT" = "stable" ] ||
  fail "1.7.33 non-interactive default must be sing-box stable ($ENGINE_INSTALL_CHOICE / $SING_BOX_INSTALL_VARIANT)"

installer_is_interactive() { return 0; }
reset_installer_state
TACHYON_RELEASE_TAG="1.7.33"
select_core_installation <<'IN' >/dev/null
3
IN
[ "$ENGINE_INSTALL_CHOICE" = "sing-box" ] && [ "$SING_BOX_INSTALL_VARIANT" = "extended" ] ||
  fail "1.7.33 interactive option 3 must pick extended ($SING_BOX_INSTALL_VARIANT)"

reset_installer_state
TACHYON_RELEASE_TAG="1.7.33"
select_core_installation <<'IN' >/dev/null
6
IN
[ "$CORE_INSTALL_CHOICE" = "tachyon-core" ] && [ "$SING_BOX_INSTALL_VARIANT" = "tachyon-core" ] ||
  fail "1.7.33 interactive option 6 must pick tachyon-core ($CORE_INSTALL_CHOICE / $SING_BOX_INSTALL_VARIANT)"

printf 'PASS: installer <1.8.0 and >=1.8.0 release compatibility contract\n'
