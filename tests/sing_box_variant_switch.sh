#!/usr/bin/env bash
# Switching away from an extended build must not roll itself back.
#
# install_package_sing_box() installs the stock or tiny package, reads the version
# of the binary it just put in place, and refuses the install if that binary still
# looks extended. The check asked sing_box_runtime_success("is-extended"), and that
# function answers "which variant is installed right now" - for which the marker
# file is the authority, because an extended binary does not always name itself.
#
# At that point in the flow the marker still says lx / extended: it is rewritten
# four lines later. So the predicate returned true for a clean 1.13.21, the install
# was rolled back, and the user got
#
#   [error] Stable sing-box package was installed, but the active binary is still
#           sing-box-extended; previous sing-box variant was restored
#
# for every switch from extended, extended-compressed or lx to stable or tiny,
# while the package had in fact been replaced.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/singbox" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

RUNTIME_UC="$TACHYON_LIB/singbox/runtime.uc"
ACTION_UC="$TACHYON_LIB/components/action.uc"
for f in "$RUNTIME_UC" "$ACTION_UC"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

looks_extended() { # <version> -> exit 0 when the version alone says extended
  ucode "$RUNTIME_UC" version-looks-extended "$1" 2>/dev/null
}

# Stock and tiny versions must pass: this is the check that was failing them.
for v in 1.13.21 1.14.0 1.15.0-alpha.10 1.16.0; do
  if looks_extended "$v"; then
    fail "stock version $v must not be reported as extended; the switch to stable/tiny rolls itself back"
  fi
  ok
done

# A genuinely extended or lx build must still be caught, or the check is useless.
for v in 1.13.18-extended-2.6.3 1.14.2-lx.11 1.15.0-lx.1 sing-box-lx; do
  if ! looks_extended "$v"; then
    fail "$v must be reported as extended, otherwise a real extended binary would be accepted as stock"
  fi
  ok
done

# An empty version has nothing to judge and must not claim extended.
if looks_extended ""; then
  fail "an empty version must not be reported as extended"
fi
ok

# The call site has to use the marker-free predicate, and only there: is-extended
# stays correct everywhere it is asked about the current variant.
strip_comments() { grep -v '^[[:space:]]*//' "$1"; }
strip_comments "$ACTION_UC" >"$WORK_DIR/action_nc.uc"

grep -q 'version-looks-extended' "$WORK_DIR/action_nc.uc" ||
  fail "install_package_sing_box must judge the freshly installed binary with the marker-free predicate"
ok

switch_block="$(sed -n '/let new_version = read_sing_box_binary_version/,/write_sing_box_variant_state/p' "$WORK_DIR/action_nc.uc")"
[ -n "$switch_block" ] ||
  fail "could not find the post-install check in install_package_sing_box"

if grep -q 'is-extended' <<<"$switch_block"; then
  fail "the post-install check still consults the marker-based is-extended, which is what caused the false rollback:
$switch_block"
fi
ok

# And the marker must still be rewritten after the check, or the switch never sticks.
grep -q 'write_sing_box_variant_state(tiny ? "tiny" : "stable"' <<<"$switch_block" ||
  fail "the variant marker must be written after the post-install check"
ok

printf 'sing-box variant switch: %d checks passed\n' "$pass_count"
printf 'PASS: sing_box_variant_switch\n'