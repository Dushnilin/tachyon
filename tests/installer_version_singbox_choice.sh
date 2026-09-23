#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$INSTALLER" ] || fail "install.sh is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

grep -Fq 'INSTALLER_VERSION="3.1.0"' "$INSTALLER" || fail "installer version must be 3.1.0"

grep -Fq 'select_release_version' "$INSTALLER" || fail "interactive release selection missing"
grep -Fq 'fetch_release_tag_list' "$INSTALLER" || fail "release tag list helper missing"
grep -Fq 'release_helper tags "$RELEASE_CHANNEL"' "$INSTALLER" || fail "release_helper tags mode must be used"
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /select_release_version/ && !sel { sel=NR }
  in_main && /resolve_release/ && !res { res=NR }
  END { exit !(sel > 0 && res > sel) }
' "$INSTALLER" || fail "select_release_version must run before resolve_release"

for variant in stable tiny extended extended-compressed lx; do
  grep -Fq "SING_BOX_INSTALL_VARIANT=\"$variant\"" "$INSTALLER" ||
    fail "sing-box menu missing variant: $variant"
done

for action in install_stable install_tiny install_extended install_extended_compressed install_lx; do
  grep -Fq "_action=\"$action\"" "$INSTALLER" ||
    fail "missing sing-box action mapping: $action"
done

grep -Fq '/usr/bin/tachyon component_action sing_box "$_action"' "$INSTALLER" ||
  fail "sing-box must be delegated to component_action"
grep -Fq 'installer_is_interactive' "$INSTALLER" || fail "interactive detection helper missing"
grep -Fq 'SING_BOX_INSTALL_VARIANT="stable"; return 0' "$INSTALLER" ||
  fail "non-interactive sing-box default must be stable"

export TACHYON_INSTALLER_TEST=1
# shellcheck source=/dev/null
. "$INSTALLER"

real_installer_is_interactive() {
  [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]
}
installer_is_interactive() { real_installer_is_interactive; }

ASSUME_YES=1
RELEASE_TAG_REQUESTED=""
select_release_version
[ -z "$RELEASE_TAG_REQUESTED" ] ||
  fail "-y must keep automatic latest release resolution (got: $RELEASE_TAG_REQUESTED)"

ASSUME_YES=0
RELEASE_TAG_REQUESTED="9.9.9"
select_release_version
[ "$RELEASE_TAG_REQUESTED" = "9.9.9" ] ||
  fail "explicit --tag must not be overridden by interactive selection"

installer_is_interactive() { return 0; }
sing_box_is_present() { return 1; }
ASSUME_YES=0
SKIP_SING_BOX=0
RELEASE_TAG_REQUESTED=""
QUIET=1

SING_BOX_INSTALL_VARIANT=""
select_sing_box_installation <<'IN' >/dev/null 2>&1 || true
4
IN
[ "$SING_BOX_INSTALL_VARIANT" = "extended-compressed" ] ||
  fail "menu choice 4 must select extended-compressed (got: ${SING_BOX_INSTALL_VARIANT:-empty})"

SING_BOX_INSTALL_VARIANT=""
select_sing_box_installation <<'IN' >/dev/null 2>&1 || true
5
IN
[ "$SING_BOX_INSTALL_VARIANT" = "lx" ] ||
  fail "menu choice 5 must select lx (got: ${SING_BOX_INSTALL_VARIANT:-empty})"

SING_BOX_INSTALL_VARIANT=""
select_sing_box_installation <<'IN' >/dev/null 2>&1 || true
2
IN
[ "$SING_BOX_INSTALL_VARIANT" = "tiny" ] ||
  fail "menu choice 2 must select tiny (got: ${SING_BOX_INSTALL_VARIANT:-empty})"

SING_BOX_INSTALL_VARIANT=""
select_sing_box_installation <<'IN' >/dev/null 2>&1 || true

IN
[ "$SING_BOX_INSTALL_VARIANT" = "stable" ] ||
  fail "empty sing-box choice must default to stable (got: ${SING_BOX_INSTALL_VARIANT:-empty})"

SING_BOX_INSTALL_VARIANT="keep"
SKIP_SING_BOX=1
select_sing_box_installation
[ -z "$SING_BOX_INSTALL_VARIANT" ] || fail "--skip-sing-box must leave no variant selected"
SKIP_SING_BOX=0

fetch_release_tag_list() { printf '1.4.0\n1.3.2\n1.3.1\n'; }

RELEASE_TAG_REQUESTED=""
select_release_version <<'IN' >/dev/null 2>&1 || true
2
IN
[ "$RELEASE_TAG_REQUESTED" = "1.3.2" ] ||
  fail "release menu choice 2 must select 1.3.2 (got: ${RELEASE_TAG_REQUESTED:-empty})"

RELEASE_TAG_REQUESTED=""
select_release_version <<'IN' >/dev/null 2>&1 || true

IN
[ "$RELEASE_TAG_REQUESTED" = "1.4.0" ] ||
  fail "empty release choice must default to latest (got: ${RELEASE_TAG_REQUESTED:-empty})"

RELEASE_TAG_REQUESTED=""
select_release_version <<'IN' >/dev/null 2>&1 || true
99
IN
[ -z "$RELEASE_TAG_REQUESTED" ] ||
  fail "out-of-range release choice must keep automatic resolution (got: $RELEASE_TAG_REQUESTED)"

printf 'PASS: installer version and sing-box choice contract\n'
